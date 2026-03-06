#!/usr/bin/env python3
"""
train_tile_classifier.py — Train a CNN to classify sky/earth tiles, then export to CoreML.

Usage:
    python train_tile_classifier.py [options]

Requires (see requirements_ml.txt):
    pip install torch torchvision coremltools scikit-learn Pillow tqdm numpy

Dataset cache (strongly recommended for large datasets):
    The first training run automatically builds a memory-mapped cache file
    (.npy) next to the data directory.  Subsequent runs open the file
    instantly — no per-epoch disk I/O.  Force rebuild with --prepare.

Speed flags (all enabled by default on MPS / CUDA):
  --no-amp      Disable automatic mixed precision (bfloat16 on MPS, float16 on CUDA)
  --no-compile  Disable torch.compile() (PyTorch 2.x)
  --no-cache    Skip the mmap cache entirely (read from disk every epoch)
  --prepare     Force-rebuild the mmap cache even if it already exists

Notes:
  • Tile images are expected to be 16-bit RGB TIFFs (as produced by tile_extractor).
    The loader converts them to 8-bit RGB before feeding to the model.
  • The CoreML model expects 8-bit BGRA pixel buffers in Swift; PixelatedImage.toPixelBuffer()
    produces kCVPixelFormatType_32BGRA and CoreML converts BGRA → RGB internally.
  • Supports Apple Silicon MPS, CUDA, and CPU.
"""

import argparse
import copy
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np
from PIL import Image
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, Dataset, Subset
from torchvision import datasets, transforms
from sklearn.model_selection import StratifiedShuffleSplit
from sklearn.metrics import confusion_matrix, classification_report


# ─────────────────────────────────────────────────────────────────────────────
# Image loading — handles 16-bit RGB TIFFs produced by tile_extractor
# ─────────────────────────────────────────────────────────────────────────────

def robust_loader(path: str) -> Image.Image:
    """
    Load an image and normalise to 8-bit RGB.

    Handles:
      • 16-bit RGB TIFF  (tiles from tile_extractor)
      • 8-bit RGB / RGBA / grayscale
    """
    img = Image.open(path)
    arr = np.array(img)

    if arr.dtype == np.uint16:
        # 16-bit → 8-bit:  keep the upper 8 bits
        arr = (arr >> 8).astype(np.uint8)
        if arr.ndim == 2:                              # grayscale 16-bit
            return Image.fromarray(arr).convert("RGB")
        else:                                          # RGB / RGBA 16-bit
            return Image.fromarray(arr[..., :3])

    if arr.dtype != np.uint8:
        # Anything else (float32, int32, …): linear rescale to [0, 255]
        mn, mx = float(arr.min()), float(arr.max())
        if mx > mn:
            arr = ((arr.astype(np.float32) - mn) / (mx - mn) * 255.0)
        arr = arr.clip(0, 255).astype(np.uint8)

    if arr.ndim == 2:
        return Image.fromarray(arr).convert("RGB")
    if arr.shape[2] == 4:
        return Image.fromarray(arr).convert("RGB")
    return Image.fromarray(arr)


# ─────────────────────────────────────────────────────────────────────────────
# Model
# ─────────────────────────────────────────────────────────────────────────────

class TileClassifier(nn.Module):
    """
    Small CNN for classifying tiles (default 32×32 RGB).

    Architecture:
      3 × (Conv-BN-ReLU-Conv-BN-ReLU-Pool) blocks followed by a small MLP.
      AdaptiveAvgPool2d makes the network size-agnostic (works for any tile size).
    """

    def __init__(self, num_classes: int = 4, in_channels: int = 3) -> None:
        super().__init__()

        def conv_block(in_ch: int, out_ch: int, pool: bool = True) -> list:
            block: list = [
                nn.Conv2d(in_ch, out_ch, kernel_size=3, padding=1, bias=False),
                nn.BatchNorm2d(out_ch),
                nn.ReLU(inplace=True),
                nn.Conv2d(out_ch, out_ch, kernel_size=3, padding=1, bias=False),
                nn.BatchNorm2d(out_ch),
                nn.ReLU(inplace=True),
            ]
            if pool:
                block.append(nn.MaxPool2d(2))          # halve spatial dims
                block.append(nn.Dropout2d(0.10))
            return block

        self.features = nn.Sequential(
            *conv_block(in_channels, 32),              # → H/2 × W/2
            *conv_block(32, 64),                       # → H/4 × W/4
            *conv_block(64, 128, pool=False),          # keep spatial
            nn.AdaptiveAvgPool2d((4, 4)),              # → 4×4 always
        )

        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Dropout(0.50),
            nn.Linear(128 * 4 * 4, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(0.30),
            nn.Linear(256, num_classes),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.classifier(self.features(x))


# ─────────────────────────────────────────────────────────────────────────────
# Transforms
# ─────────────────────────────────────────────────────────────────────────────

def build_transforms(tile_size: int, augment: bool = False) -> transforms.Compose:
    """
    Return a torchvision transform pipeline.

    Normalisation matches the CoreML ImageType preprocessing:
        ToTensor()         → pixel / 255  → [0, 1]
        Normalize(0.5,0.5) → (x - 0.5)/0.5 → [-1, 1]

    Combined: value = pixel/127.5 - 1
    """
    ops: list = []
    if augment:
        ops += [
            transforms.RandomHorizontalFlip(),
            transforms.RandomVerticalFlip(),
            transforms.RandomRotation(180),
            transforms.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.2),
        ]
    ops += [
        transforms.Resize((tile_size, tile_size)),
        transforms.ToTensor(),                         # uint8 [0,255] → float [0,1]
        transforms.Normalize(mean=[0.5, 0.5, 0.5],
                             std=[0.5, 0.5, 0.5]),    # → [-1, 1]
    ]
    return transforms.Compose(ops)


# ─────────────────────────────────────────────────────────────────────────────
# Dataset helpers
# ─────────────────────────────────────────────────────────────────────────────

def stratified_split(
    targets: list[int],
    val_ratio: float,
    test_ratio: float,
    seed: int,
) -> tuple[list[int], list[int], list[int]]:
    """
    Two-stage stratified split preserving class balance in every subset.
    Returns (train_indices, val_indices, test_indices).
    """
    indices = np.arange(len(targets))
    labels  = np.array(targets)

    # Stage 1: carve out test set
    sss_test = StratifiedShuffleSplit(n_splits=1, test_size=test_ratio,
                                      random_state=seed)
    rest_idx, test_idx = next(sss_test.split(indices, labels))

    # Stage 2: split remainder into train / val
    adjusted_val = val_ratio / (1.0 - test_ratio)
    sss_val = StratifiedShuffleSplit(n_splits=1, test_size=adjusted_val,
                                     random_state=seed)
    train_local, val_local = next(sss_val.split(rest_idx, labels[rest_idx]))

    return (
        rest_idx[train_local].tolist(),
        rest_idx[val_local].tolist(),
        test_idx.tolist(),
    )


def compute_class_weights(
    targets: list[int],
    train_idx: list[int],
    num_classes: int,
) -> torch.Tensor:
    """Inverse-frequency class weights (normalised to sum to 1)."""
    counts = np.zeros(num_classes, dtype=np.float64)
    for i in train_idx:
        counts[targets[i]] += 1
    w = 1.0 / np.where(counts == 0, 1.0, counts)
    w /= w.sum()
    return torch.tensor(w, dtype=torch.float32)


# ─────────────────────────────────────────────────────────────────────────────
# Memory-mapped dataset cache
#
# Strategy: convert all tiles to a single .npy file once (prepare phase), then
# open it as a numpy memmap on every subsequent run.  Startup is instant and
# the OS page cache automatically keeps hot tiles in RAM across epochs without
# needing to load the full dataset up front.
#
# Files created next to the data directory (or at --cache-file path):
#   <data-dir>_cache.npy          — (N, H, W, 3) uint8 image data
#   <data-dir>_cache.targets.npy  — (N,) int32 class indices
# ─────────────────────────────────────────────────────────────────────────────

def _default_cache_path(data_dir: str) -> Path:
    """Derive the default cache .npy path from the data directory path."""
    p = Path(data_dir).resolve()
    return p.parent / (p.name + "_cache.npy")


def prepare_memmap_cache(
    image_folder: datasets.ImageFolder,
    cache_path: Path,
    targets_path: Path,
    num_workers: int = 4,
) -> None:
    """
    Convert all images in image_folder to a memory-mapped .npy tile cache.

    This is a one-time operation.  It reads every image, converts to 8-bit
    RGB, and writes sequentially into a numpy .npy file using
    np.lib.format.open_memmap so the shape/dtype header is embedded and
    np.load(mmap_mode='r') can open it on the next run without needing to
    know the shape in advance.

    Parallel loading is done with ThreadPoolExecutor — file I/O releases the
    GIL so reads overlap even in CPython.  The main thread serialises writes
    into the mmap file (numpy mmap writes are not thread-safe).
    """
    paths   = [p for p, _ in image_folder.imgs]
    targets = image_folder.targets
    n       = len(paths)

    if n == 0:
        sys.exit("ERROR: ImageFolder contains no images.")

    # Determine tile shape from first image
    first_arr = np.array(robust_loader(paths[0]), dtype=np.uint8)
    h, w, c   = first_arr.shape
    size_gb   = (n * h * w * c) / 1e9

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"\nBuilding tile cache  ({n:,} tiles, {h}×{w}×{c}, {size_gb:.2f} GB)")
    print(f"  → {cache_path}")

    # Create the .npy file with its header so np.load(mmap_mode='r') works later
    data = np.lib.format.open_memmap(
        str(cache_path), mode="w+", dtype=np.uint8, shape=(n, h, w, c))
    data[0] = first_arr

    def _load_one(args: tuple[int, str]) -> tuple[int, np.ndarray]:
        idx, path = args
        return idx, np.array(robust_loader(path), dtype=np.uint8)

    t0   = time.time()
    done = 0
    workers = max(1, num_workers)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(_load_one, (i, p)): i
            for i, p in enumerate(paths[1:], start=1)
        }
        for fut in as_completed(futures):
            i, arr = fut.result()
            data[i] = arr          # serialised write from the main thread
            done += 1
            if done % 10_000 == 0 or done == n - 1:
                elapsed = time.time() - t0
                rate    = done / elapsed if elapsed > 0 else 1
                eta     = (n - 1 - done) / rate
                pct     = 100.0 * done / (n - 1)
                print(f"\r  {done:>{len(str(n-1))},}/{n-1:,}  "
                      f"({pct:5.1f}%)  ETA {eta:5.0f}s …",
                      end="", flush=True)

    data.flush()
    del data                        # close the mmap write handle

    # Targets: tiny int32 array, stored as a plain .npy alongside the cache
    np.save(str(targets_path), np.array(targets, dtype=np.int32))

    elapsed = time.time() - t0
    print(f"\r✅  Cache ready in {elapsed:.0f}s"
          + " " * 20                # overwrite the ETA line
          + f"\n  → {cache_path}")


class MemmapDataset(Dataset):
    """
    Dataset backed by a numpy memory-mapped .npy file.

    After prepare_memmap_cache() has run once, instantiation is instant — it
    just opens the file descriptor.  Each __getitem__ reads a (H, W, C) tile
    from the mmap; the OS page cache keeps frequently-accessed tiles in RAM
    automatically, so repeated epoch accesses are effectively free.

    Multiple DataLoader worker processes map the same file read-only.  Because
    mmap regions are backed by the OS page cache, worker processes share the
    same physical pages (no per-process duplication of data in RAM).

    __getitem__ returns a (C, H, W) float32 tensor pre-normalised to [-1, 1]
    with NO PIL conversion or random transforms — PIL overhead (especially
    RandomRotation with bilinear interpolation, ~2 ms per 32×32 tile) was the
    dominant training bottleneck.  Random augmentation is applied batch-wise
    on the compute device inside train_epoch() via _batch_augment().
    """

    def __init__(
        self,
        cache_path: Path,
        targets_path: Path,
        classes: list[str],
    ) -> None:
        self.classes      = classes
        self.class_to_idx = {c: i for i, c in enumerate(classes)}

        # np.load with mmap_mode='r' reads shape/dtype from the .npy header
        # and returns a read-only memmap — no data is loaded into RAM yet.
        self._data: np.ndarray = np.load(str(cache_path), mmap_mode="r")

        targets_arr  = np.load(str(targets_path))
        self.targets: list[int] = targets_arr.tolist()

        n, h, w, c  = self._data.shape
        size_gb      = self._data.nbytes / 1e9
        print(f"Cache   : {cache_path.name}  "
              f"({n:,} tiles, {h}×{w}×{c}, {size_gb:.2f} GB)")

    def __len__(self) -> int:
        return len(self._data)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, int]:
        # np.array() copies the read-only mmap page into a writable buffer.
        # The copy is from the OS page cache (RAM), not from disk once warm.
        arr = np.array(self._data[idx])               # (H, W, C) uint8, writable
        # Permute HWC → CHW, cast to float32, normalise to [-1, 1].
        # All arithmetic here is in numpy on the CPU worker — fast and avoids
        # any PIL overhead.
        t = (torch.from_numpy(arr)                    # (H, W, C) uint8 tensor
                  .permute(2, 0, 1)                   # → (C, H, W)
                  .to(torch.float32)
                  .div_(127.5)
                  .sub_(1.0))                         # → [-1, 1]
        return t, self.targets[idx]


# ─────────────────────────────────────────────────────────────────────────────
# Batch-level GPU augmentation
#
# Applied inside train_epoch() after images arrive on the compute device.
# All operations are vectorised tensor ops — no Python per-image loops, no PIL.
#
# Why not PIL per-tile augmentation in workers?
#   RandomRotation(180) uses bilinear interpolation: ~2 ms per 32×32 tile.
#   A batch of 256 tiles × 2 ms = 512 ms of PIL work even with many workers.
#   torch.rot90 on a (B, C, H, W) tensor takes <1 ms total on GPU.
# ─────────────────────────────────────────────────────────────────────────────

def _batch_augment(images: torch.Tensor) -> torch.Tensor:
    """
    Apply random augmentation to a (B, C, H, W) float32 batch on its device.

    Operations applied:
      • Random horizontal flip  — each image independently
      • Random vertical flip    — each image independently
      • Random 90° rotation     — discrete {0, 90, 180, 270}°, each image
      • Brightness jitter       — one factor per batch ∈ [0.7, 1.3]
      • Contrast jitter         — one factor per batch ∈ [0.7, 1.3]

    Per-batch (rather than per-image) jitter factors are less diverse but far
    faster and still provide meaningful augmentation when shuffling is on.
    Inputs and outputs are in the normalised [-1, 1] range.
    """
    B      = images.shape[0]
    device = images.device

    # ── Horizontal flip ───────────────────────────────────────────────────────
    mask = (torch.rand(B, device=device) < 0.5).view(B, 1, 1, 1)
    images = torch.where(mask, images.flip(-1), images)

    # ── Vertical flip ─────────────────────────────────────────────────────────
    mask = (torch.rand(B, device=device) < 0.5).view(B, 1, 1, 1)
    images = torch.where(mask, images.flip(-2), images)

    # ── Discrete 90° rotation (no interpolation) ──────────────────────────────
    # Group images by their rotation count so we issue at most 3 GPU ops.
    k_vals = torch.randint(0, 4, (B,))          # 0 = no-op, 1/2/3 = 90/180/270°
    for k in range(1, 4):
        idx = (k_vals == k).nonzero(as_tuple=True)[0]
        if idx.numel() > 0:
            images[idx] = torch.rot90(images[idx], k, dims=[-2, -1])

    # ── Brightness jitter ─────────────────────────────────────────────────────
    bf = 1.0 + (torch.rand(1).item() * 0.6 - 0.3)   # uniform ∈ [0.7, 1.3]
    images = (images * bf).clamp_(-1.0, 1.0)

    # ── Contrast jitter ───────────────────────────────────────────────────────
    cf      = 1.0 + (torch.rand(1).item() * 0.6 - 0.3)
    channel_mean = images.mean(dim=(-2, -1), keepdim=True)
    images  = (channel_mean + (images - channel_mean) * cf).clamp_(-1.0, 1.0)

    return images


# ─────────────────────────────────────────────────────────────────────────────
# Training / evaluation
# ─────────────────────────────────────────────────────────────────────────────

def train_epoch(
    model: nn.Module,
    loader: DataLoader,
    optimizer: optim.Optimizer,
    criterion: nn.Module,
    device: torch.device,
    *,
    augment: bool = False,
    use_amp: bool = False,
    amp_device: str = "cpu",
    amp_dtype: torch.dtype = torch.float32,
    scaler=None,                                       # GradScaler | None
) -> tuple[float, float]:
    model.train()
    # Accumulate loss and correct-count as on-device tensors to avoid calling
    # .item() (which forces a GPU→CPU sync) inside the hot loop.  A single
    # sync pair happens at the very end of the epoch instead of every batch.
    acc_loss    = torch.zeros(1, device=device)
    acc_correct = torch.zeros(1, device=device)
    total       = 0

    for images, labels in loader:
        images, labels = images.to(device), labels.to(device)

        # Batch-level GPU augmentation (only when using the mmap cache path;
        # the PIL/--no-cache path already augments per-tile in workers).
        if augment:
            images = _batch_augment(images)

        optimizer.zero_grad()

        with torch.autocast(device_type=amp_device, dtype=amp_dtype, enabled=use_amp):
            out  = model(images)
            loss = criterion(out, labels)

        if scaler is not None:
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
        else:
            loss.backward()
            optimizer.step()

        acc_loss    += loss.detach() * labels.size(0)
        acc_correct += (out.detach().float().argmax(1) == labels).sum()
        total       += labels.size(0)

    # Single GPU→CPU sync per epoch instead of one per batch
    return acc_loss.item() / total, acc_correct.item() / total


@torch.no_grad()
def eval_epoch(
    model: nn.Module,
    loader: DataLoader,
    criterion: nn.Module,
    device: torch.device,
    *,
    use_amp: bool = False,
    amp_device: str = "cpu",
    amp_dtype: torch.dtype = torch.float32,
) -> tuple[float, float, list[int], list[int]]:
    model.eval()
    acc_loss    = torch.zeros(1, device=device)
    acc_correct = torch.zeros(1, device=device)
    total       = 0
    all_preds:  list[int] = []
    all_labels: list[int] = []

    for images, labels in loader:
        images, labels = images.to(device), labels.to(device)

        with torch.autocast(device_type=amp_device, dtype=amp_dtype, enabled=use_amp):
            out  = model(images)
            loss = criterion(out, labels)

        acc_loss    += loss * labels.size(0)
        preds        = out.float().argmax(1)
        acc_correct += (preds == labels).sum()
        total       += labels.size(0)
        # .cpu().tolist() here is fine — we need the predictions on CPU anyway
        # for the confusion matrix; this sync only happens once per batch
        # but only materialises preds, not the loss accumulator.
        all_preds.extend(preds.cpu().tolist())
        all_labels.extend(labels.cpu().tolist())

    return acc_loss.item() / total, acc_correct.item() / total, all_preds, all_labels


# ─────────────────────────────────────────────────────────────────────────────
# CoreML export
# ─────────────────────────────────────────────────────────────────────────────

def export_coreml(
    model: nn.Module,
    tile_size: int,
    class_names: list[str],
    output_path: str,
) -> None:
    """
    Trace the trained model and save as a CoreML mlpackage.

    Input contract (Swift side):
      Pass an 8-bit BGRA CVPixelBuffer (kCVPixelFormatType_32BGRA) of size
      tile_size×tile_size.  CoreML converts BGRA → RGB internally given
      color_layout=ct.colorlayout.RGB.  PixelatedImage.toPixelBuffer() produces
      the correct format automatically.

    The ImageType preprocessing replicates training normalisation:
        value = pixel * (1/127.5) + (-1)   →  range [-1, 1]
    which equals ToTensor (÷255) + Normalize(mean=0.5, std=0.5).
    """
    try:
        import coremltools as ct
    except ImportError:
        print("⚠️  coremltools not installed — skipping CoreML export.")
        print("   Run:  pip install coremltools")
        return

    model.eval().cpu()
    example = torch.zeros(1, 3, tile_size, tile_size)
    traced  = torch.jit.trace(model, example)

    image_input = ct.ImageType(
        name="image",
        shape=(1, 3, tile_size, tile_size),
        # pixel → scale * pixel + bias  ==>  pixel/127.5 - 1  ∈ [-1, 1]
        scale=1.0 / 127.5,
        bias=[-1.0, -1.0, -1.0],
        color_layout=ct.colorlayout.RGB,
    )

    print("Converting to CoreML (this may take a moment)…")
    mlmodel = ct.convert(
        traced,
        inputs=[image_input],
        classifier_config=ct.ClassifierConfig(class_names),
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = (
        f"Tile classifier ({tile_size}×{tile_size} RGB): "
        "earth / star_sky / clear_sky / cloudy_sky"
    )
    mlmodel.author = "nighttime_timelapse_airplane_remover"
    mlmodel.input_description["image"] = (
        f"8-bit RGB tile image, {tile_size}×{tile_size} px"
    )
    mlmodel.output_description["classLabel"] = (
        "Predicted class: earth | star_sky | clear_sky | cloudy_sky"
    )

    mlmodel.save(output_path)

    # Report package size
    pkg = Path(output_path)
    if pkg.is_dir():
        size_mb = sum(f.stat().st_size for f in pkg.rglob("*") if f.is_file()) / 1e6
    else:
        size_mb = pkg.stat().st_size / 1e6
    print(f"✅  CoreML model saved → {output_path}  ({size_mb:.1f} MB)")


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Train CNN tile classifier → CoreML mlpackage",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Data
    g = p.add_argument_group("Data")
    g.add_argument("--data-dir",    default="ML_DATA/tiles_32",
                   help="Root directory containing class subdirectories")
    g.add_argument("--tile-size",   type=int, default=32,
                   help="Tile size in pixels (inputs are resized to this)")
    g.add_argument("--train-ratio", type=float, default=0.70)
    g.add_argument("--val-ratio",   type=float, default=0.15)
    g.add_argument("--test-ratio",  type=float, default=0.15)
    g.add_argument("--no-augment",  action="store_true",
                   help="Disable training-time data augmentation")

    # Training
    g = p.add_argument_group("Training")
    g.add_argument("--epochs",       type=int,   default=50)
    g.add_argument("--batch-size",   type=int,   default=256)
    g.add_argument("--lr",           type=float, default=1e-3,
                   help="Initial learning rate (AdamW)")
    g.add_argument("--weight-decay", type=float, default=1e-4,
                   help="AdamW weight-decay")
    g.add_argument("--early-stop",   type=int,   default=10,
                   help="Stop after N epochs with no val-loss improvement")
    g.add_argument("--workers",      type=int,   default=4,
                   help="DataLoader worker processes (also parallelises cache build)")
    g.add_argument("--seed",         type=int,   default=42)

    # Speed / cache
    g = p.add_argument_group("Speed")
    g.add_argument("--cache-file", default=None, metavar="PATH",
                   help="Path for the mmap cache .npy file "
                        "(default: <data-dir>_cache.npy next to the data directory)")
    g.add_argument("--prepare",    action="store_true",
                   help="Force rebuild of the mmap cache even if it already exists")
    g.add_argument("--no-cache",   action="store_true",
                   help="Disable the mmap cache entirely — reads from disk every epoch "
                        "(slow for large datasets, useful for debugging)")
    g.add_argument("--no-amp",     action="store_true",
                   help="Disable automatic mixed precision "
                        "(bfloat16 on MPS, float16 on CUDA)")
    g.add_argument("--no-compile", action="store_true",
                   help="Disable torch.compile() (PyTorch 2.x)")

    # Output
    g = p.add_argument_group("Output")
    g.add_argument("--output",      default="tile_classifier.mlpackage",
                   help="CoreML mlpackage output path")
    g.add_argument("--checkpoint",  default="tile_classifier_best.pt",
                   help="PyTorch checkpoint path for best weights")
    g.add_argument("--resume",      action="store_true",
                   help="Resume training from <checkpoint>.state.pt (saved every epoch)")
    g.add_argument("--no-coreml",   action="store_true",
                   help="Skip CoreML export step")

    return p.parse_args()


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

def main() -> None:
    args = parse_args()

    # Validate ratios
    total_r = args.train_ratio + args.val_ratio + args.test_ratio
    if abs(total_r - 1.0) > 1e-5:
        sys.exit(f"ERROR: ratios must sum to 1.0 (got {total_r:.4f})")

    # Reproducibility
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    # ── Device ────────────────────────────────────────────────────────────────
    if torch.backends.mps.is_available():
        device    = torch.device("mps")
        dev_label = "Apple Silicon MPS"
    elif torch.cuda.is_available():
        device    = torch.device("cuda")
        dev_label = torch.cuda.get_device_name()
    else:
        device    = torch.device("cpu")
        dev_label = "CPU"
    print(f"Device  : {dev_label}")

    # CUDA-specific: TF32 matmul (~2× on Ampere+) + cuDNN auto-tuner
    if device.type == "cuda":
        torch.set_float32_matmul_precision("high")
        torch.backends.cudnn.benchmark = True

    # ── Mixed-precision setup ─────────────────────────────────────────────────
    use_amp    = False
    # Default to "cpu" — torch.autocast validates device_type in __init__ even
    # when enabled=False, so passing "mps" on an older PyTorch that doesn't
    # support MPS autocast raises RuntimeError regardless of enabled=False.
    amp_device = "cpu"
    amp_dtype  = torch.float32
    scaler     = None

    if not args.no_amp:
        if device.type == "mps":
            # MPS autocast was added in PyTorch 2.0; probe before committing
            try:
                with torch.autocast(device_type="mps", dtype=torch.bfloat16):
                    _ = torch.zeros(1, device=device) + 1
                use_amp    = True
                amp_device = "mps"
                amp_dtype  = torch.bfloat16   # same dynamic range as float32 → no GradScaler
            except RuntimeError:
                print("AMP     : MPS autocast not supported in this PyTorch version — disabled")
        elif device.type == "cuda":
            use_amp    = True
            amp_device = "cuda"
            amp_dtype  = torch.float16
            scaler     = torch.cuda.amp.GradScaler()

    amp_label = f"{amp_dtype} autocast on {device.type}" if use_amp else "disabled"
    print(f"AMP     : {amp_label}")

    # ── Dataset directory ─────────────────────────────────────────────────────
    data_root = Path(args.data_dir)
    if not data_root.is_dir():
        sys.exit(f"ERROR: data directory not found: {data_root.resolve()}")

    base_tf = build_transforms(args.tile_size, augment=False)
    aug_tf  = build_transforms(args.tile_size, augment=not args.no_augment)

    # Fast directory scan — just reads filenames, no image I/O
    def _dummy_loader(path: str) -> Image.Image:
        return Image.new("RGB", (2, 2))

    scan_ds     = datasets.ImageFolder(str(data_root), loader=_dummy_loader)
    class_names = scan_ds.classes
    num_classes = len(class_names)
    targets     = scan_ds.targets

    counts = np.bincount(targets, minlength=num_classes)
    print(f"\nClasses ({num_classes}):")
    for name, n in zip(class_names, counts):
        print(f"  {name:<14}  {n:>9,}")
    print(f"  {'TOTAL':<14}  {sum(counts):>9,}")

    # ── Splits ────────────────────────────────────────────────────────────────
    train_idx, val_idx, test_idx = stratified_split(
        targets, args.val_ratio, args.test_ratio, args.seed)
    print(f"\nSplit   →  train {len(train_idx):,}  "
          f"val {len(val_idx):,}  test {len(test_idx):,}")

    # ── Build train / val / test datasets ─────────────────────────────────────
    if args.no_cache:
        # Original behaviour: ImageFolder reads from disk on every __getitem__
        full_ds = datasets.ImageFolder(str(data_root), transform=base_tf,
                                       loader=robust_loader)
        aug_ds  = datasets.ImageFolder(str(data_root), transform=aug_tf,
                                       loader=robust_loader)
        train_ds = Subset(aug_ds,  train_idx)
        val_ds   = Subset(full_ds, val_idx)
        test_ds  = Subset(full_ds, test_idx)
        print("Cache   : disabled (--no-cache)")

    else:
        # Derive cache file paths
        cache_path   = (Path(args.cache_file) if args.cache_file
                        else _default_cache_path(args.data_dir))
        targets_path = cache_path.with_suffix(".targets.npy")

        # Detect stale cache (different tile count than current data dir)
        stale = False
        if cache_path.exists() and targets_path.exists() and not args.prepare:
            cached_n = int(np.load(str(targets_path)).shape[0])
            if cached_n != len(scan_ds):
                print(f"\n⚠️  Cache has {cached_n:,} tiles but data dir has "
                      f"{len(scan_ds):,} — rebuilding.")
                stale = True

        needs_prepare = args.prepare or stale or not cache_path.exists()

        if needs_prepare:
            # Rebuild with real loader to get actual pixel data
            real_scan = datasets.ImageFolder(str(data_root), loader=robust_loader)
            prepare_memmap_cache(real_scan, cache_path, targets_path, args.workers)

        mmap_ds  = MemmapDataset(cache_path, targets_path, class_names)
        # No per-tile PIL transforms — __getitem__ returns a normalised tensor.
        # _batch_augment() is called inside train_epoch() on the compute device.
        train_ds = Subset(mmap_ds, train_idx)
        val_ds   = Subset(mmap_ds, val_idx)
        test_ds  = Subset(mmap_ds, test_idx)

    # pin_memory speeds up CPU→GPU transfers on CUDA; unsupported on MPS
    pin = (device.type == "cuda")
    loader_kw = dict(
        batch_size=args.batch_size,
        num_workers=args.workers,
        pin_memory=pin,
        persistent_workers=(args.workers > 0),
        prefetch_factor=(4 if args.workers > 0 else None),
    )
    train_loader = DataLoader(train_ds, shuffle=True,  **loader_kw)
    val_loader   = DataLoader(val_ds,   shuffle=False, **loader_kw)
    test_loader  = DataLoader(test_ds,  shuffle=False, **loader_kw)

    # ── Model ─────────────────────────────────────────────────────────────────
    model = TileClassifier(num_classes=num_classes, in_channels=3).to(device)
    n_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"\nModel   →  {model.__class__.__name__}  ({n_params:,} parameters)")

    # torch.compile: fuses ops and generates optimised kernels (PyTorch 2.x)
    # torch.compile(model) always succeeds — the actual compilation happens on
    # the first forward pass, which is where backend failures (e.g. inductor
    # not supporting MPS) surface.  Probe with a dummy forward pass so we get
    # a clear message at startup rather than a cryptic crash mid-epoch.
    if not args.no_compile and hasattr(torch, "compile"):
        try:
            compiled = torch.compile(model)
            with torch.no_grad():
                _dummy = torch.zeros(2, 3, args.tile_size, args.tile_size,
                                     device=device)
                compiled(_dummy)
            model = compiled
            print("Compile : enabled")
        except Exception as exc:
            print(f"Compile : not supported on this device/version — skipped "
                  f"({type(exc).__name__})")
    else:
        print("Compile : skipped")

    class_weights = compute_class_weights(targets, train_idx, num_classes).to(device)
    criterion     = nn.CrossEntropyLoss(weight=class_weights)
    optimizer     = optim.AdamW(model.parameters(),
                                lr=args.lr, weight_decay=args.weight_decay)
    scheduler     = optim.lr_scheduler.CosineAnnealingLR(
                        optimizer, T_max=args.epochs, eta_min=1e-6)

    amp_kw = dict(use_amp=use_amp, amp_device=amp_device, amp_dtype=amp_dtype)
    # GPU-side batch augmentation only applies when using the mmap cache.
    # The --no-cache PIL path already augments per-tile inside DataLoader workers.
    use_batch_augment = (not args.no_cache) and (not args.no_augment)

    # ── Training state (supports --resume) ────────────────────────────────────
    # The "state" checkpoint is written every epoch and stores everything needed
    # to restart exactly where we left off if the run crashes (Metal errors,
    # power loss, etc.).  It is separate from --checkpoint which only saves the
    # best model weights for CoreML export.
    state_path = Path(args.checkpoint).with_suffix(".state.pt")

    best_val_loss  = float("inf")
    patience_count = 0
    start_epoch    = 1

    if args.resume:
        if not state_path.exists():
            sys.exit(f"ERROR: --resume requested but no state file found at {state_path}\n"
                     f"       Run without --resume to start fresh.")
        print(f"Resuming from {state_path} …")
        state = torch.load(str(state_path), map_location=device, weights_only=False)
        raw_m = getattr(model, "_orig_mod", model)
        raw_m.load_state_dict(state["model"])
        optimizer.load_state_dict(state["optimizer"])
        scheduler.load_state_dict(state["scheduler"])
        start_epoch    = state["epoch"] + 1
        best_val_loss  = state["best_val_loss"]
        patience_count = state["patience_count"]
        print(f"  Continuing at epoch {start_epoch}  "
              f"(best val loss so far: {best_val_loss:.4f}, "
              f"patience: {patience_count}/{args.early_stop})")

    # ── Training loop ─────────────────────────────────────────────────────────
    hdr = (f"{'Ep':>4}  {'TrLoss':>8}  {'TrAcc':>7}  "
           f"{'VaLoss':>8}  {'VaAcc':>7}  {'LR':>9}")
    print(f"\n{hdr}")
    print("─" * len(hdr))

    for epoch in range(start_epoch, args.epochs + 1):
        t0 = time.time()
        tr_loss, tr_acc = train_epoch(
            model, train_loader, optimizer, criterion, device,
            augment=use_batch_augment, **amp_kw, scaler=scaler)
        va_loss, va_acc, _, _ = eval_epoch(
            model, val_loader, criterion, device, **amp_kw)
        scheduler.step()
        lr_now = scheduler.get_last_lr()[0]

        marker = ""
        if va_loss < best_val_loss:
            best_val_loss  = va_loss
            patience_count = 0
            # Save best weights (for CoreML export)
            raw = getattr(model, "_orig_mod", model)
            torch.save(raw.state_dict(), args.checkpoint)
            marker = " ✓"
        else:
            patience_count += 1

        elapsed = time.time() - t0
        print(f"{epoch:4d}  {tr_loss:8.4f}  {tr_acc:6.2%}  "
              f"{va_loss:8.4f}  {va_acc:6.2%}  {lr_now:9.2e}"
              f"  [{elapsed:.1f}s]{marker}")

        # Save full training state every epoch so we can resume after a crash.
        # This includes optimizer + scheduler state so the LR schedule is exact.
        raw = getattr(model, "_orig_mod", model)
        torch.save({
            "epoch":          epoch,
            "model":          raw.state_dict(),
            "optimizer":      optimizer.state_dict(),
            "scheduler":      scheduler.state_dict(),
            "best_val_loss":  best_val_loss,
            "patience_count": patience_count,
        }, str(state_path))

        # Release Metal heap allocations that accumulate over long runs.
        # Without this, the Metal command buffer pool can overflow after many
        # hours and crash the process (kIOAccelCommandBufferCallbackError…).
        if device.type == "mps":
            torch.mps.synchronize()    # wait for all pending Metal work
            torch.mps.empty_cache()    # release cached Metal allocations

        if patience_count >= args.early_stop:
            print(f"\n⏹  Early stop at epoch {epoch} "
                  f"(no val improvement for {args.early_stop} epochs)")
            break

    # ── Test evaluation ───────────────────────────────────────────────────────
    print(f"\nLoading best weights from {args.checkpoint} …")
    raw = getattr(model, "_orig_mod", model)
    raw.load_state_dict(torch.load(args.checkpoint, map_location=device,
                                   weights_only=True))

    te_loss, te_acc, preds, labels = eval_epoch(
        model, test_loader, criterion, device, **amp_kw)
    print(f"\nTest Loss {te_loss:.4f}   Test Accuracy {te_acc:.2%}\n")

    print(classification_report(labels, preds, target_names=class_names, digits=4))

    # Confusion matrix — pretty-print
    cm = confusion_matrix(labels, preds)
    col_w = max(len(n) for n in class_names) + 2
    print("Confusion matrix (rows = true class, cols = predicted class):")
    print("  " + " ".join(f"{n:>{col_w}}" for n in class_names))
    for i, row in enumerate(cm):
        print(f"  " + " ".join(f"{v:{col_w}d}" for v in row) +
              f"   ← {class_names[i]}")

    # ── CoreML export ──────────────────────────────────────────────────────────
    if not args.no_coreml:
        print(f"\nExporting CoreML mlpackage → {args.output}")
        export_model = getattr(model, "_orig_mod", model)
        export_coreml(export_model, args.tile_size, class_names, args.output)
    else:
        print("\n(CoreML export skipped — pass without --no-coreml to export)")


if __name__ == "__main__":
    main()

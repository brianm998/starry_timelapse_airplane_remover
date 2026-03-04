#!/usr/bin/env python3
"""
train_tile_classifier.py — Train a CNN to classify sky/earth tiles, then export to CoreML.

Usage:
    python train_tile_classifier.py [options]

Requires (see requirements_ml.txt):
    pip install torch torchvision coremltools scikit-learn Pillow tqdm numpy

Notes:
  • Tile images are expected to be 16-bit RGB TIFFs (as produced by tile_extractor).
    The loader converts them to 8-bit RGB before feeding to the model.
  • The CoreML model expects 8-bit RGB pixel buffers in Swift; scale your 16-bit
    tiles to [0,255] before passing them to the model at inference time.
  • Supports Apple Silicon MPS, CUDA, and CPU.
"""

import argparse
import random
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, Subset
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
            return Image.fromarray(arr, mode="L").convert("RGB")
        else:                                          # RGB / RGBA 16-bit
            return Image.fromarray(arr[..., :3], mode="RGB")

    if arr.dtype != np.uint8:
        # Anything else (float32, int32, …): linear rescale to [0, 255]
        mn, mx = float(arr.min()), float(arr.max())
        if mx > mn:
            arr = ((arr.astype(np.float32) - mn) / (mx - mn) * 255.0)
        arr = arr.clip(0, 255).astype(np.uint8)

    if arr.ndim == 2:
        return Image.fromarray(arr, mode="L").convert("RGB")
    if arr.shape[2] == 4:
        return Image.fromarray(arr, mode="RGBA").convert("RGB")
    return Image.fromarray(arr, mode="RGB")


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
# Training / evaluation
# ─────────────────────────────────────────────────────────────────────────────

def train_epoch(
    model: nn.Module,
    loader: DataLoader,
    optimizer: optim.Optimizer,
    criterion: nn.Module,
    device: torch.device,
) -> tuple[float, float]:
    model.train()
    total_loss = correct = total = 0
    for images, labels in loader:
        images, labels = images.to(device), labels.to(device)
        optimizer.zero_grad()
        out  = model(images)
        loss = criterion(out, labels)
        loss.backward()
        optimizer.step()
        total_loss += loss.item() * len(labels)
        correct    += (out.argmax(1) == labels).sum().item()
        total      += len(labels)
    return total_loss / total, correct / total


@torch.no_grad()
def eval_epoch(
    model: nn.Module,
    loader: DataLoader,
    criterion: nn.Module,
    device: torch.device,
) -> tuple[float, float, list[int], list[int]]:
    model.eval()
    total_loss = correct = total = 0
    all_preds:  list[int] = []
    all_labels: list[int] = []
    for images, labels in loader:
        images, labels = images.to(device), labels.to(device)
        out  = model(images)
        loss = criterion(out, labels)
        total_loss += loss.item() * len(labels)
        preds = out.argmax(1)
        correct    += (preds == labels).sum().item()
        total      += len(labels)
        all_preds.extend(preds.cpu().tolist())
        all_labels.extend(labels.cpu().tolist())
    return total_loss / total, correct / total, all_preds, all_labels


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
      Pass an 8-bit RGB CVPixelBuffer / CGImage of size tile_size×tile_size.
      If your tiles are 16-bit TIFFs, scale them to [0,255] uint8 first.

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
                   help="DataLoader worker processes (set 0 if multiprocessing issues)")
    g.add_argument("--seed",         type=int,   default=42)

    # Output
    g = p.add_argument_group("Output")
    g.add_argument("--output",      default="tile_classifier.mlpackage",
                   help="CoreML mlpackage output path")
    g.add_argument("--checkpoint",  default="tile_classifier_best.pt",
                   help="PyTorch checkpoint path for best weights")
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
    print(f"Device : {dev_label}")

    # ── Dataset ───────────────────────────────────────────────────────────────
    data_root = Path(args.data_dir)
    if not data_root.is_dir():
        sys.exit(f"ERROR: data directory not found: {data_root.resolve()}")

    base_tf = build_transforms(args.tile_size, augment=False)
    aug_tf  = build_transforms(args.tile_size, augment=not args.no_augment)

    # Load twice: once with aug for training, once without for val/test/indexing
    full_ds = datasets.ImageFolder(str(data_root), transform=base_tf,
                                   loader=robust_loader)
    aug_ds  = datasets.ImageFolder(str(data_root), transform=aug_tf,
                                   loader=robust_loader)

    class_names = full_ds.classes
    num_classes = len(class_names)
    targets     = full_ds.targets

    counts = np.bincount(targets, minlength=num_classes)
    print(f"\nClasses ({num_classes}):")
    for name, n in zip(class_names, counts):
        print(f"  {name:<14}  {n:>9,}")
    print(f"  {'TOTAL':<14}  {sum(counts):>9,}")

    # ── Splits ────────────────────────────────────────────────────────────────
    train_idx, val_idx, test_idx = stratified_split(
        targets, args.val_ratio, args.test_ratio, args.seed)
    print(f"\nSplit  →  train {len(train_idx):,}  "
          f"val {len(val_idx):,}  test {len(test_idx):,}")

    train_ds = Subset(aug_ds,  train_idx)
    val_ds   = Subset(full_ds, val_idx)
    test_ds  = Subset(full_ds, test_idx)

    # pin_memory speeds up CPU→GPU transfers; avoid on MPS (not supported)
    pin = (device.type == "cuda")
    loader_kw = dict(batch_size=args.batch_size, num_workers=args.workers,
                     pin_memory=pin, persistent_workers=(args.workers > 0))
    train_loader = DataLoader(train_ds, shuffle=True,  **loader_kw)
    val_loader   = DataLoader(val_ds,   shuffle=False, **loader_kw)
    test_loader  = DataLoader(test_ds,  shuffle=False, **loader_kw)

    # ── Model ─────────────────────────────────────────────────────────────────
    model = TileClassifier(num_classes=num_classes, in_channels=3).to(device)
    n_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"\nModel  →  {model.__class__.__name__}  ({n_params:,} parameters)")

    class_weights = compute_class_weights(targets, train_idx, num_classes).to(device)
    criterion     = nn.CrossEntropyLoss(weight=class_weights)
    optimizer     = optim.AdamW(model.parameters(),
                                lr=args.lr, weight_decay=args.weight_decay)
    scheduler     = optim.lr_scheduler.CosineAnnealingLR(
                        optimizer, T_max=args.epochs, eta_min=1e-6)

    # ── Training loop ────────────────────────────────────────────────────────
    best_val_loss  = float("inf")
    patience_count = 0

    hdr = (f"{'Ep':>4}  {'TrLoss':>8}  {'TrAcc':>7}  "
           f"{'VaLoss':>8}  {'VaAcc':>7}  {'LR':>9}")
    print(f"\n{hdr}")
    print("─" * len(hdr))

    for epoch in range(1, args.epochs + 1):
        t0 = time.time()
        tr_loss, tr_acc       = train_epoch(model, train_loader, optimizer, criterion, device)
        va_loss, va_acc, _, _ = eval_epoch(model, val_loader,   criterion, device)
        scheduler.step()
        lr_now = scheduler.get_last_lr()[0]

        marker = ""
        if va_loss < best_val_loss:
            best_val_loss  = va_loss
            patience_count = 0
            torch.save(model.state_dict(), args.checkpoint)
            marker = " ✓"
        else:
            patience_count += 1

        elapsed = time.time() - t0
        print(f"{epoch:4d}  {tr_loss:8.4f}  {tr_acc:6.2%}  "
              f"{va_loss:8.4f}  {va_acc:6.2%}  {lr_now:9.2e}"
              f"  [{elapsed:.1f}s]{marker}")

        if patience_count >= args.early_stop:
            print(f"\n⏹  Early stop at epoch {epoch} "
                  f"(no val improvement for {args.early_stop} epochs)")
            break

    # ── Test evaluation ──────────────────────────────────────────────────────
    print(f"\nLoading best weights from {args.checkpoint} …")
    model.load_state_dict(torch.load(args.checkpoint, map_location=device,
                                     weights_only=True))

    te_loss, te_acc, preds, labels = eval_epoch(model, test_loader, criterion, device)
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

    # ── CoreML export ─────────────────────────────────────────────────────────
    if not args.no_coreml:
        print(f"\nExporting CoreML mlpackage → {args.output}")
        export_coreml(model, args.tile_size, class_names, args.output)
    else:
        print("\n(CoreML export skipped — pass without --no-coreml to export)")


if __name__ == "__main__":
    main()

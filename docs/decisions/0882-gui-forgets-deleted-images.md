# 0882: the gui forgets deleted images

`FrameViewModel.existingImages` only grew, so after stale-artifact invalidation every frame showed "image not found".
`ImageAccessor.deleteImage` is the one place files are removed, so it reports each removal through `imageDeletedClosure`
(unset in the daemon). The gui hops to the main actor, removes the type for full-size deletions, forgets the loader entry
for any size, and falls back to `.original` via `ImageSequenceViewModel.viewMode(_:whenFrameHas:)`.

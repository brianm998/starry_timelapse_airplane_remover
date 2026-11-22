# 0882: the gui forgets deleted images

`FrameViewModel.existingImages` only grew, so after stale-artifact invalidation every frame showed "image not found".
`ImageAccessor.deleteImage` is the one place files are removed, so it reports each removal through `imageDeletedClosure`
(unset in the daemon). The gui hops to the main actor, removes the type for full-size deletions, forgets the loader entry
for any size, and falls back to `.original` via `ImageSequenceViewModel.viewMode(_:whenFrameHas:)`.

To test that through `imageDeleted` itself, `ImageSequenceViewModel`'s async init is now a convenience init over a
synchronous `init(viewModel:configManager:trashLevel:smallTrashMax:)` that only copies the settings in; opening the
sequence from disk moved, unchanged, into `openSequence`. `ImageDeletionTests` builds a frameless model that way.

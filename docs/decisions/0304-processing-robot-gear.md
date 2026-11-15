# 0304 — Processing robot gear geometry

The PR-1, PR-5a and PR-5b masters in `art/masters/` are each trimmed to their opaque box by `art/export.py`. Lining
up trimmed PR-5a on trimmed PR-1 (mean colour difference over pixels opaque in both) gives scale 1.0 and offset (0, 0):
the body is drawn at the 56 pt box's top-left corner at its own size (41 × 56). Matching PR-5b into PR-1 (scale,
rotation and offset search; the gear is turned about 20° in PR-1) gives a hub at (153.5, 149.5) of 220 px and a diameter
of about 113 px. In the 56 pt box that is hub (0.698, 0.677) and a 28.8 pt gear, rounded to 29 so a fitted `ArtImage`
and the Compose image agree.

- The gear is rotated by its own centre, then offset onto the hub, so it cannot drift off it.
- Animation state is local to the heading's view and stops on disappear (gui) or leaves the composition (desktop), so
  the steps list is never redrawn.
- Compose Desktop has no Reduce Motion setting; the desktop always turns the gear. Reported in the stage note.
- If a master is replaced, re-measure the three constants (they are duplicated in both clients; ProcessingArtTest checks they agree).

# 1176: mac gui ui shard red again: the lines hypothesis of 1060 was disproved

Run 45869432048 (`Gherkin/mac gui (macos-15) · ui`) is red after decision 1060 made the selection lines
`allowsHitTesting(false)`. uiOutlierClickKeeps and uiOutlierClickUndecided still wait 90 s for "1 will keep"
(it says "0 will keep"); uiOutlierInformationClick never sees the outlier window. `outlier.first` was
hittable, 8 x 11 pt, inside the window. So **the lines were not the cause: 1060's hypothesis is disproved.**

Pattern: the scenarios that click a Keep All group (uiOutlierClicks, uiOutlierMultiClick) pass; the ones that
click a removed or undecided group fail. Those draw four arrow images permanently, a kept group none.

New hypothesis (**not confirmed**; the xcresult cannot be read offline): the arrows of a group (or a later
group's arrows) sit over the probe group's tap target and take its click, because each group drew its arrows
and its view together, group after group.

Change: `OutlierGroupView` has a `layer`. `FrameEditImageView` draws every group's arrows and lines first, then
every group's tappable view with `zIndex` by draw position (`groupZIndex`, smaller groups on top), with an
explicit `contentShape(Rectangle())`. The arrows stay tappable. The UI runner now records, after a click on
`outlier.first`, the status counts, the number of `outlier.first` elements and the elements whose frame holds
the click point, and prints them in a failed `says` / `window is open` wait. If the shard stays red, read that
evidence and fix what it names; do not add another guess.

No new strings, no Kotlin change (the desktop leg is green).

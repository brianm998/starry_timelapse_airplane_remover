# 1060: mac gui ui shard red: a click on `outlier.first` has no effect

Run 45463127790 (`Gherkin/mac gui (macos-15) · ui`) is red. uiOutlierClickKeeps and uiOutlierClickUndecided
time out waiting for `status.keep` to say "1 will keep" (it stays "0 will keep"); uiOutlierInformationClick
never sees the outlier window open.

Cause: **hypothesised, not confirmed** (the xcresult could not be read offline, as in decisions 0511, 0601
and 1043). Undecided and to-be-removed groups draw four arrow images and, on hover, selection lines across
the frame; Keep All groups draw none, and the clicks on Keep All groups pass. The lines may take the click.

Change: `outlierFrameLine()` is `allowsHitTesting(false)` (rule `OutlierGroupView.frameLinesTakeHits`, unit
tested). The arrows stay tappable: tapping them is a user feature. The runner now appends the probe's frame,
hittable state, the window frame and the status counts to a failed `says` or `window is open` wait, so a
red that remains names its cause. If it stays red, read that evidence and fix the real cause.

No new strings, no Kotlin change (the desktop leg is not red and its probe is a plain tagged box).

# 0651: gui icon compile failure in Gherkin mac gui CI

Decision: the real actool/ibtoold error from run 44566520821 could NOT be read (the task log tail is cut before it, and the
developer session has no network). The cause is therefore unconfirmed. What is known: only `CompileAssetCatalogVariant` for
target Star failed (Release, Xcode 26.3, macos-15), the cleanup killed an orphan `ibtoold`, and the only recent change to that
step is s588 (StarIcon.icon). Neither a bad bundle nor a GPU-less runner is proven.

So the change is the narrowest safe one: the shard job retries the build once, and only when `CompileAssetCatalogVariant failed`
appears with no test executed; and the failure evidence now prints actool/ibtoold/`error:` lines (also from the first attempt),
so a repeat shows the real cause. The shipped icon (StarIcon.icon) is untouched.

Follow-up: if the retry also fails, read the new "actool / asset catalogue errors" block and fix the bundle in `art/export.py`
or skip the .icon in CI builds.

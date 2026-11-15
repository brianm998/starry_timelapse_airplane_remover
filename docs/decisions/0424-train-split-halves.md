# 0424: read active batches before ready tickets in the train's pick

Cause: task #433, flaky `test_fix_answer_splits_batch` on develop (run 43742832898).
Choice: reorder the two reads in `Train._pick` rather than re-insert dropped groups; any ticket that left `flying` has already become `ready`, so reading `flying` first is consistent. The test is untouched.

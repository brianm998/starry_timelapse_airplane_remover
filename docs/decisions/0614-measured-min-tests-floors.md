# 0614: min_tests floors from static counts

Decision: replace `min_tests = 1 # UNMEASURED` with ~90% of a static test-function count per suite. Shadow runs were not available; floors under the real count avoid false reds, and can be raised once real counts are seen.

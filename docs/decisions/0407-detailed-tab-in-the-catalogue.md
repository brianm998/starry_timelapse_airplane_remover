# 0407: Detailed tab text in the catalogue

Cause: task #252: the Detailed tab was hard-coded English, with typos and two statements that no longer matched the code.

Choice: 22 keys (`ui.info_detailed_intro`, `_<stage>_title`/`_body` for ten stages, `_closing`), both clients read them in the same order; the closing holds two paragraphs joined by `\n\n` and is split on that. The hard-coded `DETAILED_TEXT`/`.detailedText` English is gone; the tests check keys, art and the English typos instead of a SHA of the old text.

Alignment-failure wording follows the code: a doubtful static-tripod frame gets the sequence's best (median) homography (`validateStaticStarAlignment`), a moving one is gap-filled from its neighbours, and only a frame left with no alignment at all uses its own pixels (`FrameAlignmentProcessor`, logged at error level), so nothing is replaced in it. The old "falls back to un-aligned neighbor frames" was wrong.

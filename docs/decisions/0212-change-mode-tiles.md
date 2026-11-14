# 0212: Change Mode tiles via an optional `leading` slot

`VerticalStarPicker` gains `leading: (@Composable (T) -> Unit)? = null`, drawn before each label; other callers pass nothing and are unchanged. The mapping from clean method to tile lives in `HighLevelCleanMethod.changeModeArt` (gui) and `cleanArt` (desktop). Both dirty modes are one `HighLevelClean.DIRTY` choice and share the dirty tile.

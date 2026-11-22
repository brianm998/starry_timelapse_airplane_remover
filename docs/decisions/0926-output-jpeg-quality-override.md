# 0926: the output JPEG quality override is a live box shared by the frames' image accessors

`Config.outputJPEGQuality: Int?` (nil = the input's quality). Frames hold copies of the `ImageAccessor` made when the graph is built, so a
config change would not reach them; the accessor therefore reads the override from an `OutputJPEGQualityOverride` box that every copy shares,
and the daemon session / gui view model set it when the user moves the slider. The proto sends 0 for "same as input" (always present), and
0 sent by a client clears the override. Landing the slider on the input's own quality stores nil, not a redundant override.

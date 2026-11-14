# 0305: Welcome art and the greeter rule

Neither client enforces a minimum window size, so the greeter (150 x 220 pt, lower right) avoids the drop zone, Load buttons and recents by construction rather than by measurement.

- At 900 x 600 or more, the content column gets a trailing inset of greeter width + 2 x 16 pt, so everything sits left of the greeter.
- Below that the greeter is hidden and no inset is added.
- The greeter is an overlay, never part of the VStack/Column, so it adds no height.
- The Information banner shows the 30%-95% band of art_robot_and_dog (294 pt of 453) at 680 pt wide, clipped to the dialog's 20 pt corners; the Kotlin dialog's max width is now 680 dp to match.

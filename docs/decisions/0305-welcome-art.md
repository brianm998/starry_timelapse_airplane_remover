# 0305: Welcome art and the greeter rule

Neither client enforces a minimum window size, so the greeter (150 x 220 pt, upper left, 16 pt margin) is a background layer rather than something the layout makes room for.

- The greeter is a layer in a ZStack: above the night-sky still and intro video, below all the other content. It takes no room, so the drop zone keeps its full size and the content column uses the full window width. (This replaces the earlier rule of a left inset of greeter width + 2 x 16 pt at 900 x 600 or more.)
- It is always shown, at any window size (the earlier hide-below-900 x 600 rule is gone). In a small window the heading, buttons or drop zone may cover it, and that is fine.
- The gui keeps `allowsHitTesting(false)` on it.
- The Information banner shows the 30%-95% band of art_robot_and_dog (294 pt of 453) at 680 pt wide, clipped to the dialog's 20 pt corners; the Kotlin dialog's max width is now 680 dp to match.

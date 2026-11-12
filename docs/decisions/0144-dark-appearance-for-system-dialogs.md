# 0144: Force the dark appearance for system-drawn dialogs on macOS

## Status
Accepted (s149, task #159).

## Context
star has no light theme. macOS draws its own dialogs (SwiftUI alerts, `NSAlert`, `NSOpenPanel`, popovers, default sheet backgrounds) in the system Light/Dark appearance, so on a Light-mode Mac they come up white with black text inside the dark app. The desktop client's AWT `FileDialog` pickers, window title bars and tray menu follow the same system setting.

## Decision
1. gui: set `NSApp.appearance = NSAppearance(named: .darkAqua)` in `AppDelegate.applicationWillFinishLaunching`, so it is in place before any window exists.
2. desktop: set the JVM property `apple.awt.application.appearance=NSAppearanceNameDarkAqua` as the first statement of `main`, on macOS only, because AWT reads it when the toolkit starts.

## Consequences
- Every system-drawn dialog on macOS is dark in both clients, whatever the Mac's setting.
- Windows and Linux are unchanged; their pickers keep their platform look (out of scope).
- A gui view that relied on the light system background with `.primary` text would turn white-on-dark. The main window's views already force `.colorScheme(.dark)` where it matters; sheets are covered by the second ticket of the pair.
- The starTests host is shared, so the test resets `NSApp.appearance` in `tearDown`.

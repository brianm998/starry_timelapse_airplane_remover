# 1100 — Stopped-run alert text

## Problem
The gui alert printed `Resume with: star <path>`, meaningless to a gui user, and printed it even when the config
was gone and no Restart Now button was offered.

## Decision
`RunMarker.briefReport`, which both clients show (through `asWarning.suggestion`), names no path or command. A
restartable run is expressed by the button alone. A run whose saved config has gone says it cannot be restarted. A
run that never named a config says nothing about restarting. The cli's `report` keeps the command: it goes to a
terminal and a log.

Both clients stack the buttons, Restart Now above OK. The plan expected the macOS alert to stack them by itself;
measured on macOS 15.8 it puts them side by side, and SwiftUI's alert gives no way to choose. So the gui shows a
restartable report in its own sheet (a separate window, so the main window is not resized) and keeps the system
alert for every other critical warning. Padding the labels to force the alert to wrap was rejected: it would depend on
each language's text widths. In both clients OK keeps its label and stays
the default, so a stray Return cannot start an hours-long run.

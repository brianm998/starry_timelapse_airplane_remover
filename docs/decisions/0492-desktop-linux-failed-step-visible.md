# 0492: desktop-linux Gherkin: name the failed step, retry network setup

The log tail of #486 showed no failing step. Rather than guess, the job now prints the failed step by name (GitHub jobs API, `continue-on-error`) and summarize-desktop-features.sh says the run script never started. Fetch test data and apt get three tries with growing waits; nothing else of the leg, nor the windows/macos legs, changed.

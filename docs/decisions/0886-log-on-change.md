# 0886: log config blocks only when a value changed

Config updates run dozens of times a minute, so the scheduler/memory/cache lines are keyed on the settings they report (not on live readings such as available memory) via `LogOnChange`, and logged when the key changes. A once-per-open reset was not added: an unchanged config reopened stays quiet, which is the point.

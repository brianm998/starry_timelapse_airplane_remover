#!/bin/bash

find ~/git/nighttime_timelapse_airplane_remover/decision_tree_generator/Sources -name '*.swift' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/cli/Sources -name '*.swift' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/gui/star -name '*.swift' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/StarCore/Sources -name '*.swift' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/StarCpp/Sources -name '*.swift' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/StarCpp/Sources -name '*.cpp' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/StarCpp/Sources -name '*.hpp' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/StarCpp/Sources -name '*.h' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/logging/Sources -name '*.swift' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/logging-objc/Sources -name '*.h' -exec emacsclient -n '{}' ';'
find ~/git/nighttime_timelapse_airplane_remover/logging-objc/Sources -name '*.mm' -exec emacsclient -n '{}' ';'

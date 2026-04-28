#!/bin/bash

# Platform dispatcher — runs release_macos.sh or release_linux.sh.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"

case "$(uname -s)" in
    Darwin) exec ./release_macos.sh ;;
    Linux)  exec ./release_linux.sh ;;
    *)      echo "Unsupported platform: $(uname -s)"; exit 1 ;;
esac

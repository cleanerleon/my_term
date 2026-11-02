#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --product WindAskpass
swift run WindNativeChecks

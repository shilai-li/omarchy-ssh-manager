#!/usr/bin/env bash

# The whole suite. Pure logic under plain node, plus the three shell scripts
# run for real against a throwaway ~/.ssh — no compositor, no shell, and no
# connection to anything but hostnames that cannot resolve.
#
#   bash test/test.sh

set -euo pipefail
cd "$(dirname "$0")/.."

node test/config-test.js
node test/diagnostics-test.js
node test/scripts-test.js

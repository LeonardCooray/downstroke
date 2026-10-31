#!/bin/bash
# Runs the tests. Usage: scripts/test.sh [swift test args]
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools' build intermittently drops this plugin path, failing @Test macros.
PLUGINS="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"

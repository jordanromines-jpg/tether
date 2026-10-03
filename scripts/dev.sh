#!/usr/bin/env bash
# Runs the agent on THIS Mac for local testing: http://localhost:7400
# Dev mode allows header-less (local) requests; never use it for the real deployment.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT/agent"
TETHER_DEV=1 TETHER_WEB_DIR="$ROOT/web" \
  exec "$(swift build --package-path "$ROOT/agent" --show-bin-path)/Tether"

#!/bin/bash
# Control editing keys in page fields, Chromium and WebKit tabs, on an app
# built with Chromium tabs (CONTRIBUTING.md). Exits 1 when a key does not do
# what it does in a Mac field.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec /usr/bin/python3 -u evals/chromium-ctrl-editing/check.py "$@"

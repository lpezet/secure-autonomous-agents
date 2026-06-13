#!/bin/bash
set -euo pipefail

/setup.sh

# TODO: replace with channel listener (e.g. Telegram bot) that invokes:
#   claude -p "$task" --allowedTools "..." /workspace
exec sleep infinity

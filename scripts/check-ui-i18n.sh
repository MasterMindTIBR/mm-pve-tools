#!/bin/sh
set -eu
REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
exec node "$REPO/scripts/check-ui-i18n.js"

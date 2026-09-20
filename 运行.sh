#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$APP_ROOT/构建/阅卷.app/Contents/MacOS/yy阅卷" "$@"

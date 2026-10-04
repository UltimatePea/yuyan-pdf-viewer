#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./构建.sh
node 发布打包.cjs
mkdir -p 构建/发布
COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent 构建/阅卷.app 构建/发布/Yuyan-PDF-Viewer-v0.2.4-macos-arm64.zip
(cd 构建/发布 && shasum -a 256 Yuyan-PDF-Viewer-v0.2.4-macos-arm64.zip > SHA256SUMS.txt)

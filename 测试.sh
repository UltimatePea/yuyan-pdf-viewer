#!/bin/bash
set -euo pipefail
export YY_VIEWER_BACKGROUND=1
cd "$(dirname "$0")"
clang -fobjc-arc -framework Cocoa -framework PDFKit 测试/文本范围.m -o 构建/文本范围测试
构建/文本范围测试
node 测试/回归.cjs
node 测试/重编译.cjs
node 测试/跳点.cjs
node 测试/历史.cjs
node 测试/多窗.cjs
node 测试/搜索.cjs
if [[ -n "${YY_CRASH_PDF:-}" ]]; then node 测试/崩溃.cjs; fi
node 测试/工具栏.cjs

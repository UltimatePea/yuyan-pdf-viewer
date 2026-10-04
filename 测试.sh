#!/bin/bash
set -euo pipefail
export YY_VIEWER_BACKGROUND=1
cd "$(dirname "$0")"
node 测试/回归.cjs
node 测试/重编译.cjs
node 测试/跳点.cjs
node 测试/历史.cjs
node 测试/多窗.cjs
node 测试/搜索.cjs

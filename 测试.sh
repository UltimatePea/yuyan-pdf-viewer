#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
node 测试/回归.cjs
node 测试/重编译.cjs
node 测试/跳点.cjs
node 测试/历史.cjs

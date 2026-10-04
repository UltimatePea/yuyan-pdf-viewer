#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
YY_ROOT="${YY_ROOT:-$APP_ROOT/../yuyan-worktrees/yuyan-wktree-1}"
YY_ROOT="$(cd "$YY_ROOT" && pwd)"
NODE_PREFIX="${NODE_PREFIX:-/opt/homebrew}"
mkdir -p "$APP_ROOT/构建"
if [ ! -x "$YY_ROOT/yy阅卷编译器" ]; then
  (cd "$YY_ROOT" && ./yy豫构_stable 构建 豫言编译器 --编译器 ./yy3_bs --输出 "$YY_ROOT/yy阅卷编译器" -j 4) > "$APP_ROOT/构建/工具链.log" 2>&1
fi
printf '豫构包上下文二\n豫言\t标准库\t%s/库/标准库/标准库。包。豫\n豫言\t阅卷\t%s/源码/阅卷。包。豫\t豫言\t标准库\n' "$YY_ROOT" "$APP_ROOT" > "$APP_ROOT/构建/包.上下文"
(cd "$YY_ROOT" && ./yy阅卷编译器 "$APP_ROOT/源码/入口。豫" --package-context "$APP_ROOT/构建/包.上下文" --target=wasmgc -o "$APP_ROOT/构建/阅卷.wasm") > "$APP_ROOT/构建/编译.log" 2>&1
"$YY_ROOT/yy网页汇编宿主" --组装 "$APP_ROOT/源码/值桥接.wat" "$APP_ROOT/构建/值桥接.wasm"
clang -O2 -fobjc-arc -shared -undefined dynamic_lookup -I"$NODE_PREFIX/include/node" -framework Cocoa -framework PDFKit -framework UniformTypeIdentifiers -o "$APP_ROOT/构建/原生桥.node" "$APP_ROOT/源码/原生桥.m"
BUNDLE="$APP_ROOT/构建/阅卷.app/Contents"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"
cp "$APP_ROOT/构建/阅卷.wasm" "$APP_ROOT/构建/值桥接.wasm" "$APP_ROOT/构建/原生桥.node" "$APP_ROOT/源码/宿主.cjs" "$BUNDLE/Resources/"
ICONSET="$APP_ROOT/构建/图标.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP_ROOT/资源/图标.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$APP_ROOT/资源/图标.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Resources/图标.icns"
clang++ -std=c++20 -O2 -fobjc-arc -I"$NODE_PREFIX/include/node" -L"$NODE_PREFIX/lib" "$NODE_PREFIX"/lib/libnode.*.dylib -Wl,-rpath,"$NODE_PREFIX/lib" -framework Foundation -o "$BUNDLE/MacOS/yy阅卷" "$APP_ROOT/源码/启动.mm"
cat > "$BUNDLE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>yy阅卷</string>
<key>CFBundleIdentifier</key><string>org.yuyan.reader</string>
<key>CFBundleName</key><string>阅卷</string>
<key>CFBundleDisplayName</key><string>阅卷</string>
<key>CFBundleIconFile</key><string>图标.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleShortVersionString</key><string>0.2.4</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>PDF document</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$BUNDLE/Resources/原生桥.node"
codesign --force --sign - "$APP_ROOT/构建/阅卷.app"
printf 'Built: %s/构建/阅卷.app\n' "$APP_ROOT"

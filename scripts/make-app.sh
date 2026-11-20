#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
swift build --package-path "$PROJECT_DIR" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/DolaLite.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/DolaLite" "$APP_DIR/Contents/MacOS/DolaLite"
if [ -f "$PROJECT_DIR/Assets/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
python3 - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as out:
    plistlib.dump({
      'CFBundleExecutable':'DolaLite',
      'CFBundleIdentifier':'com.hiep.dolalite',
      'CFBundleName':'Dola Lite',
      'CFBundleDisplayName':'Dola Lite',
      'CFBundleIconFile':'AppIcon',
      'CFBundlePackageType':'APPL',
      'CFBundleShortVersionString':'1.1.3',
      'CFBundleVersion':'5',
      'LSMinimumSystemVersion':'13.0',
      'LSUIElement':True,
      'NSHighResolutionCapable':True,
      'NSAccessibilityUsageDescription':'Dola Lite đọc đoạn văn bản bạn chọn để dịch, tóm tắt và giải thích.',
    },out,sort_keys=False)
PY
# Ký bằng identity tự tạo ổn định nếu có: TCC (Accessibility…) gắn với certificate
# thay vì cdhash, nên rebuild không bị mất quyền. Fallback ad-hoc nếu chưa có cert.
if security find-identity -p codesigning | grep -q '"DolaLite Dev"'; then
  codesign --force --sign "DolaLite Dev" "$APP_DIR"
else
  codesign --force --sign - "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"

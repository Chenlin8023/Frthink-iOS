#!/usr/bin/env bash
# Frthink for iOS — 构建并打包 .ipa
# 用法（在 macOS 上）：
#   xcodegen generate                 # 先生成 Frthink.xcodeproj
#   ./build_ipa.sh --team TEAM_ID                    # 上架/AdHoc
#   ./build_ipa.sh --team TEAM_ID --method development
#   ./build_ipa.sh --unsigned        # 不签名（仅模拟器/研究用途，不能直接安装到设备）
set -euo pipefail

TEAM_ID=""
METHOD="app-store"
SCHEME="Frthink"
CONFIGURATION="Release"
UNSIGNED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM_ID="$2"; shift 2;;
    --method) METHOD="$2"; shift 2;;
    --unsigned) UNSIGNED=true; shift;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

cd "$(dirname "$0")"
BUILD_DIR="build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> 1/3 xcodebuild archive"
ARCHIVE="$BUILD_DIR/Frthink.xcarchive"
if [[ -n "$TEAM_ID" ]]; then
  xcodebuild archive \
    -project Frthink.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates
else
  xcodebuild archive \
    -project Frthink.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO
fi

if [[ "$UNSIGNED" == true ]]; then
  echo "==> 打包未签名 .ipa（Payload/Frthink.app 压缩，设备安装需自行签名）"
  APP=$(find "$ARCHIVE/Products" -maxdepth 3 -type d -name "Frthink.app" | head -1)
  mkdir -p "$BUILD_DIR/Payload"
  cp -R "$APP" "$BUILD_DIR/Payload/"
  (cd "$BUILD_DIR" && zip -qyr Frthink-unsigned.ipa Payload)
  echo "完成：$BUILD_DIR/Frthink-unsigned.ipa（未签名，需用 e.g. codesign / AltStore / 爱思助手 重签后安装）"
  exit 0
fi

echo "==> 2/3 生成导出配置"
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
EOF

echo "==> 3/3 导出 .ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$BUILD_DIR" \
  -allowProvisioningUpdates

IPA=$(find "$BUILD_DIR" -maxdepth 1 -name "*.ipa" | head -1)
echo "完成：$IPA"

#!/bin/bash
set -e

# ==============================================================================
# Script de création du DMG professionnel TvControl pour macOS (style LaunchPad)
# ==============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/Partage_TvControl"
ICON_PNG="$PROJECT_DIR/TvControl/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
OUTPUT_DMG="$DIST_DIR/TvControl.dmg"
ROOT_DMG="$PROJECT_DIR/TvControl.dmg"
TEMP_DMG_SOURCE="/tmp/tvcontrol_dmg_source"
BG_IMAGE="/tmp/tvcontrol_bg_opaque.png"

cd "$PROJECT_DIR"

echo "🎨 1. Génération des icônes d'application TvControl..."
swiftc -module-cache-path /tmp/clang-module-cache "$PROJECT_DIR/Scripts/generate_app_icon.swift" -o /tmp/gen_tvcontrol_icon
/tmp/gen_tvcontrol_icon "$PROJECT_DIR/TvControl/Assets.xcassets/AppIcon.appiconset"

echo "🖼️ 2. Génération du fond Liquid Glass 24-bit Retina (640x440 @2x)..."
swiftc -module-cache-path /tmp/clang-module-cache "$PROJECT_DIR/Scripts/generate_dmg_background.swift" -o /tmp/gen_tvcontrol_dmg_bg
/tmp/gen_tvcontrol_dmg_bg

echo "📦 3. Compilation de TvControl.app en mode Release..."
xcodebuild -project "$PROJECT_DIR/TvControl.xcodeproj" \
           -scheme TvControl \
           -configuration Release \
           -derivedDataPath /tmp/TvControl_DerivedData \
           CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
           SWIFT_MODULE_CACHE_PATH=/tmp/swift-module-cache \
           OTHER_SWIFT_FLAGS="-disable-sandbox" \
           CODE_SIGN_IDENTITY="-" \
           build -quiet

BUILT_APP="/tmp/TvControl_DerivedData/Build/Products/Release/TvControl.app"
ICON_ICNS="$BUILT_APP/Contents/Resources/AppIcon.icns"

echo "🧹 4. Préparation du dossier source DMG..."
rm -rf "$TEMP_DMG_SOURCE" && mkdir -p "$TEMP_DMG_SOURCE"
ditto "$BUILT_APP" "$TEMP_DMG_SOURCE/TvControl.app"
codesign --force --deep --sign - --identifier "com.tvcontrol.app" "$TEMP_DMG_SOURCE/TvControl.app"

# Copier aussi TvControl.app dans le dossier de partage
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/TvControl.app"
ditto "$TEMP_DMG_SOURCE/TvControl.app" "$DIST_DIR/TvControl.app"

echo "💿 5. Démontage des anciens volumes éventuels..."
hdiutil detach "/Volumes/TvControl" -force 2>/dev/null || true
hdiutil detach "/Volumes/TvControl 1" -force 2>/dev/null || true

echo "🔨 6. Création du fichier DMG Liquid Glass..."
rm -f "$OUTPUT_DMG" "$ROOT_DMG"

if command -v create-dmg >/dev/null 2>&1; then
    VOLICON_ARGS=()
    if [ -f "$ICON_ICNS" ]; then
        VOLICON_ARGS=(--volicon "$ICON_ICNS")
    fi

    create-dmg \
      --volname "TvControl" \
      "${VOLICON_ARGS[@]}" \
      --background "$BG_IMAGE" \
      --window-pos 200 120 \
      --window-size 640 440 \
      --icon-size 96 \
      --text-size 13 \
      --icon "TvControl.app" 175 195 \
      --hide-extension "TvControl.app" \
      --app-drop-link 465 195 \
      --overwrite \
      "$OUTPUT_DMG" \
      "$TEMP_DMG_SOURCE"
else
    ln -sf /Applications "$TEMP_DMG_SOURCE/Applications"
    mkdir -p "$TEMP_DMG_SOURCE/.background"
    cp "$BG_IMAGE" "$TEMP_DMG_SOURCE/.background/background.png"
    if [ -f "$ICON_ICNS" ]; then
        cp "$ICON_ICNS" "$TEMP_DMG_SOURCE/.VolumeIcon.icns"
    fi

    RW_DMG="/tmp/tvcontrol_rw.dmg"
    rm -f "$RW_DMG"
    if hdiutil create -volname "TvControl" -srcfolder "$TEMP_DMG_SOURCE" -ov -format UDRW "$RW_DMG" -quiet 2>/dev/null && \
       hdiutil attach "$RW_DMG" -mountpoint "/Volumes/TvControl" -nobrowse -quiet 2>/dev/null; then
        osascript <<APPLESCRIPT 2>/dev/null || true
        tell application "Finder"
            tell disk "TvControl"
                open
                set current view of container window to icon view
                set toolbar visible of container window to false
                set statusbar visible of container window to false
                set the bounds of container window to {200, 120, 840, 560}
                set viewOptions to the icon view options of container window
                set arrangement of viewOptions to not arranged
                set icon size of viewOptions to 96
                set text size of viewOptions to 13
                set background picture of viewOptions to file ".background:background.png"
                set position of item "TvControl.app" of container window to {175, 195}
                set position of item "Applications" of container window to {465, 195}
                close
                open
                update without registering applications
                delay 1
            end tell
        end tell
APPLESCRIPT
        sync
        hdiutil detach "/Volumes/TvControl" -force -quiet 2>/dev/null || true
        hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG" -quiet
        rm -f "$RW_DMG"
    else
        hdiutil create -volname "TvControl" -srcfolder "$TEMP_DMG_SOURCE" -ov -format UDZO "$OUTPUT_DMG" -quiet
    fi
fi

# Créer aussi l'archive .zip pour le système de mise à jour GitHub
APP_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TEMP_DMG_SOURCE/TvControl.app/Contents/Info.plist" 2>/dev/null || echo "1.0.2")
ditto -c -k --sequesterRsrc --keepParent "$TEMP_DMG_SOURCE/TvControl.app" "$DIST_DIR/TvControl-v${APP_VER}.zip"
cp "$OUTPUT_DMG" "$ROOT_DMG"

echo "✨ 7. Application du logo personnalisé sur le fichier .dmg..."
swift -module-cache-path /tmp/clang-module-cache - << EOF
import AppKit

let dmgPaths = ["$OUTPUT_DMG", "$ROOT_DMG"]
if let img = NSImage(contentsOfFile: "$ICON_PNG") {
    for path in dmgPaths {
        if FileManager.default.fileExists(atPath: path) {
            let success = NSWorkspace.shared.setIcon(img, forFile: path, options: [])
            print("Icône appliquée sur \(path) : \(success)")
        }
    }
}
EOF

echo "✅ DMG prêt : $OUTPUT_DMG (et copié dans $ROOT_DMG)"

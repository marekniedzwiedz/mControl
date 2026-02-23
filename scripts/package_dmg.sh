#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-mControl}"
PRODUCT_NAME="${PRODUCT_NAME:-mControlApp}"
BUNDLE_ID="${BUNDLE_ID:-com.mcontrol.app}"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
ICON_NAME="${ICON_NAME:-mControl}"
APP_BUNDLE_PATH="${APP_BUNDLE_PATH:-$ROOT_DIR/dist/$APP_NAME.app}"
DMG_NAME="${DMG_NAME:-$APP_NAME}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME Installer}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"
STAGING_DIR="$OUTPUT_DIR/.dmg-staging"
ICON_PNG_PATH="$OUTPUT_DIR/$ICON_NAME.png"
CACHE_DIR="$ROOT_DIR/.build/cache"
CONFIG_DIR="$ROOT_DIR/.build/config"
SECURITY_DIR="$ROOT_DIR/.build/security"
MODULE_CACHE_DIR="$ROOT_DIR/.build/clang-module-cache"

mkdir -p "$OUTPUT_DIR" "$CACHE_DIR" "$CONFIG_DIR" "$SECURITY_DIR" "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"

render_icon_png() {
    local output_png="$1"

    swift - "$output_png" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: <script> <output_png_path>\n", stderr)
    exit(EXIT_FAILURE)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager()
do {
    try fileManager.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
} catch {
    fputs("Unable to create output directory: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

let canvasSize: CGFloat = 1_024
let inset: CGFloat = 74
let drawRect = NSRect(
    x: inset,
    y: inset,
    width: canvasSize - (2 * inset),
    height: canvasSize - (2 * inset)
)

func drawSymbol(named symbolName: String, color: NSColor, in rect: NSRect) {
    guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        return
    }

    let sizeConfig = NSImage.SymbolConfiguration(pointSize: 780, weight: .bold)
    let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [color])
    let configured = baseSymbol.withSymbolConfiguration(sizeConfig.applying(paletteConfig)) ?? baseSymbol
    configured.draw(in: rect)
}

let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
image.lockFocus()
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)).fill()
drawSymbol(
    named: "shield.fill",
    color: NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.44, alpha: 1.0),
    in: drawRect
)
drawSymbol(
    named: "shield",
    color: NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.17, alpha: 1.0),
    in: drawRect
)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Unable to render icon PNG.\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Unable to write icon PNG: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
SWIFT
}

apply_custom_icon() {
    local target_path="$1"
    local icon_png_path="$2"

    swift - "$target_path" "$icon_png_path" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: <script> <target_path> <icon_png_path>\n", stderr)
    exit(EXIT_FAILURE)
}

let targetPath = CommandLine.arguments[1]
let iconPath = CommandLine.arguments[2]
let fileManager = FileManager()

guard fileManager.fileExists(atPath: targetPath) else {
    fputs("Target does not exist: \(targetPath)\n", stderr)
    exit(EXIT_FAILURE)
}

guard let iconImage = NSImage(contentsOfFile: iconPath) else {
    fputs("Unable to load icon image: \(iconPath)\n", stderr)
    exit(EXIT_FAILURE)
}

if !NSWorkspace.shared.setIcon(iconImage, forFile: targetPath, options: []) {
    fputs("Failed to apply custom icon to: \(targetPath)\n", stderr)
    exit(EXIT_FAILURE)
}
SWIFT
}

echo "Generating icon assets..."
render_icon_png "$ICON_PNG_PATH"

echo "Building $PRODUCT_NAME ($CONFIGURATION)..."
swift build \
    -c "$CONFIGURATION" \
    --product "$PRODUCT_NAME" \
    --package-path "$ROOT_DIR" \
    --disable-sandbox \
    --scratch-path "$ROOT_DIR/.build" \
    --cache-path "$CACHE_DIR" \
    --config-path "$CONFIG_DIR" \
    --security-path "$SECURITY_DIR" \
    --manifest-cache local

find_binary() {
    local candidate
    for candidate in \
        "$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION/$PRODUCT_NAME" \
        "$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT_NAME"
    do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

BINARY_PATH="$(find_binary || true)"
if [[ -z "$BINARY_PATH" ]]; then
    echo "Could not locate built executable for $PRODUCT_NAME."
    exit 1
fi

echo "Bundling app at $APP_BUNDLE_PATH"
rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$APP_BUNDLE_PATH/Contents/MacOS" "$APP_BUNDLE_PATH/Contents/Resources"
cp "$BINARY_PATH" "$APP_BUNDLE_PATH/Contents/MacOS/$PRODUCT_NAME"
chmod +x "$APP_BUNDLE_PATH/Contents/MacOS/$PRODUCT_NAME"

cat > "$APP_BUNDLE_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

cat > "$APP_BUNDLE_PATH/Contents/PkgInfo" <<EOF
APPL????
EOF

if command -v codesign >/dev/null 2>&1; then
    echo "Applying ad-hoc signature..."
    codesign --force --deep --sign - "$APP_BUNDLE_PATH" >/dev/null
fi

if ! apply_custom_icon "$APP_BUNDLE_PATH" "$ICON_PNG_PATH"; then
    echo "Warning: failed to apply custom icon to app bundle."
fi

echo "Preparing DMG staging folder..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG at $DMG_PATH..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

if ! apply_custom_icon "$DMG_PATH" "$ICON_PNG_PATH"; then
    echo "Warning: failed to apply custom icon to DMG file."
fi

echo "Done."
echo "Installer DMG: $DMG_PATH"
echo "Open it and drag '$APP_NAME.app' to 'Applications'."

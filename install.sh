#!/bin/bash
# install.sh — run deadzone in the background automatically at every login.
#
#   Install:    bash install.sh 0.25 left
#   Uninstall:  bash install.sh uninstall
#
# Keep install.sh and deadzone.m in the same folder (e.g. Downloads).

LABEL="com.deadzone.agent"
DIR="$HOME/Library/Application Support/deadzone"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/deadzone.log"
GUI="gui/$(id -u)"

# Stop any copy that's already running (background or Terminal)
launchctl bootout "$GUI/$LABEL" 2>/dev/null
pkill -x deadzone 2>/dev/null
sleep 1

if [ "$1" = "uninstall" ]; then
    rm -f "$PLIST"
    rm -rf "$DIR"
    echo "deadzone removed. Your screen is back to normal."
    exit 0
fi

FRACTION="${1:-0.25}"
SIDE="${2:-left}"
SRC="$(cd "$(dirname "$0")" && pwd)/deadzone.m"
if [ ! -f "$SRC" ]; then
    echo "Can't find deadzone.m next to install.sh. Put both in the same folder."
    exit 1
fi

mkdir -p "$DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

echo "Building..."
if ! clang -O2 -fobjc-arc "$SRC" -o "$DIR/deadzone" \
    -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia \
    -framework CoreVideo -framework QuartzCore -framework Carbon; then
    echo "Build failed. Send a photo of the errors above."
    exit 1
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/deadzone</string>
        <string>$FRACTION</string>
        <string>$SIDE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart if it crashes, but NOT if you quit it with Control+Option+Command+Q -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "$GUI" "$PLIST"
echo ""
echo "Installed. deadzone now runs in the background and starts at every login."
echo "You can close Terminal."
echo ""
echo "The first time, macOS will ask to allow 'deadzone' for Accessibility and"
echo "Screen Recording. Turn both on; it will start within about a minute."

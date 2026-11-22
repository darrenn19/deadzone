# deadzone

Use a MacBook with a damaged screen without an external monitor.

If part of your built-in display is broken (lines, stripes, dead pixels along one side), **deadzone** squeezes your entire desktop, including the menu bar, Dock, windows and mouse pointer, into the part of the screen that still works. The broken strip is left black, and nothing you need ever sits under it.

## How it works

1. Creates a virtual display exactly the size of the undamaged area.
2. Makes that virtual display the main display, so the menu bar, Dock and new windows live there.
3. Shows the virtual display live on the built-in screen, flush against the good edge, using ScreenCaptureKit.
4. Keeps the mouse pointer on the virtual display, and moves any window left on the hidden part of the screen over to it.

It is event-driven (it only does work when the mouse moves, an app launches, or the screen changes), so it uses almost no CPU when idle.

Everything is reverted automatically the moment deadzone quits: the display arrangement change is app-only, and the virtual display disappears with the process.

## Requirements

- A Mac running macOS 13 Ventura or later (originally tested on a 13" MacBook Pro).
- Apple's Command Line Tools: `xcode-select --install`

## Install (runs in the background at every login)

```bash
git clone https://github.com/darrenn19/deadzone.git
cd deadzone
bash install.sh 0.25 left
```

- The first number is the **fraction of the screen width that is damaged** (`0.25` = 25%).
- The second is **which side** is damaged: `left` or `right`.

The first time it runs, macOS will ask you to allow **deadzone** under **Privacy & Security** in two places:

- **Accessibility** (to move windows off the hidden area)
- **Screen & System Audio Recording** (to show the desktop on the good part of the screen)

Turn on accessibility -> Run Again,
Turn on Screen & System Audio Recording -> Run Again,
deadzone will start within about a minute.

## Usage

| What | How |
| --- | --- |
| Pause until next login | **Control + Option + Command + Q** |
| Start again without logging out | `launchctl kickstart gui/$(id -u)/com.deadzone.agent` |
| Change the size or side | `bash install.sh 0.30 left` |
| Uninstall completely | `bash install.sh uninstall` |
| View the log | `cat ~/Library/Logs/deadzone.log` |

## Run once without installing

```bash
clang -O2 -fobjc-arc deadzone.m -o deadzone -framework Cocoa -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon
./deadzone 0.25 left
```

When it is run from Terminal, the permissions go to Terminal instead of deadzone.

## Safety

- **Control + Option + Command + Q** quits it instantly and restores the normal screen.
- If no picture appears within 8 seconds of starting, deadzone quits on its own.
- Restarting the Mac always restores the normal screen.

## Limitations

- The broken pixels still show their stripes. deadzone keeps your content away from them but can't turn them off.
- It uses `CGVirtualDisplay`, a private macOS API (the same one used by BetterDisplay and DeskPad). A future macOS update could break it.
- Newer macOS versions sometimes ask whether deadzone can keep recording the screen. Click **Allow**.
- Rebuilding the program (re-running `install.sh`) may require granting the permissions again.

## Troubleshooting

**`redefinition of module 'SwiftBridging'` or `could not build module 'Foundation'` when building**
This is a known Command Line Tools bug. Rename the duplicate file:

```bash
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
        /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.bak
```

**The picture doesn't cover the stripes, or leaves extra black space**
Re-run the installer with a bigger or smaller first number, for example `bash install.sh 0.30 left`.

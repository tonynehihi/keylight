# KeyLight 2.1 by @tonynehihi

Menu bar app for MacBook keyboard backlight, with global hotkeys.

## Download

Download `KeyLight-2.1.zip` from Releases, unzip it, move `KeyLight.app` to `/Applications`, then run:

```bash
xattr -dr com.apple.quarantine /Applications/KeyLight.app && open /Applications/KeyLight.app
```

**Why this command is needed:** KeyLight is not signed with a paid Apple Developer ID, so macOS Gatekeeper blocks a downloaded unsigned app and may report it as damaged with no Open Anyway button. The command above removes the download quarantine flag, then the app opens normally. After that, grant Input Monitoring and Accessibility in the Permissions window, then quit and reopen KeyLight.

- Default hotkeys: Option + Up Arrow = brighter, Option + Down Arrow = dimmer
- Menu bar: click the keyboard icon > drag the Control Center-style slider (dim sun on the left, bright sun on the right) to set brightness directly, sliding to 0 turns it off / Settings / Permissions / Quit. Opening the menu shows the current brightness and moves the slider to it if the hardware can be read; on a Mac without a backlight the slider is disabled. Global hotkeys (Option + Up/Down by default, customisable in Settings) still work even though there are no Increase / Decrease menu buttons.
- App icon: lineart keyboard on a white rounded square, dark key outlines, amber backlit keys, a dark up-arrow key and thin amber light rays above the keyboard (`keylight-icon-1024.png`, built into `AppIcon.icns`), so Spotlight and Finder show a real icon instead of the generic one.
- Settings: change the Increase and Decrease hotkeys. Each hotkey needs at least one modifier, and the two must be different. Saved automatically.
- Step size: about 10% per press.

## Warning about the default hotkeys

Option + Up/Down is also macOS paragraph navigation in text fields. KeyLight uses a global monitor that does NOT swallow the key event, so in a text field Option + Up will both move by paragraph AND change brightness. That is the trade-off of the chosen default. If that bothers you, open Settings and change the hotkeys to a combination with no system function, for example Control + Option + Up/Down.

## Permissions

On first launch KeyLight shows a Permissions window. Global hotkeys need Input Monitoring (and, in some setups, Accessibility). The window explains that KeyLight does not record what you type, it only reacts to your hotkey, and its buttons open the exact System Settings panes:
- Input Monitoring
- Accessibility

Status circles: red = not granted, green = granted. Each row puts its circle right beside its Open Settings button, so the status and the fix are on the same line.
- Accessibility circle is checked live.
- Input Monitoring circle cannot be checked by any public macOS API, so it turns green only after a real hotkey test passes: switch to another app (for example Finder), press your Increase hotkey, come back to the Permissions window, then click Check Again. If the app received that hotkey, the circle turns green. Pressing the hotkey while the Permissions window itself is in front does not count, because global monitors only see events sent to other apps.

If hotkeys do not work after enabling, quit and reopen KeyLight, because macOS only re-checks permissions when the app starts. The Permissions window is also available any time from the menu as Permissions...

## Build (on an Apple Silicon Mac, same pattern as FixNotif)

```bash
bash build.sh
open KeyLight.app
```

## Before testing

1. System Settings > Keyboard: turn off "Adjust keyboard brightness in low light", otherwise the system may pull brightness back after you change it by hand.
2. If hotkeys do not work but menu clicks do change brightness: missing permission. Open the Permissions window from the menu, enable KeyLight, quit and reopen.
3. If menu clicks do not change brightness and the icon turns into a warning triangle for 2 seconds: the app cannot read/write the IOKit service on that machine. Check on a MacBook with a backlit keyboard, not on a Mac mini.

## Scope

- Apple Silicon only (M1, M2, M3, M4...). Intel Macs are not supported.
- Build works on any Apple Silicon Mac, including a Mac mini M4 (same arm64 binary). Only backlight testing requires a MacBook with a backlit keyboard, because a Mac mini has no such IOKit service.
- Test first on Tony's MacBooks (M1 Max, Air M4) before a wider release, because service names and brightness levels can differ by generation.

## If the build fails

- Error about `kIOMainPortDefault`: replace it with `kIOMasterPortDefault` in KeyLight.swift and build again.
- Error about `IOServiceMatching`: depending on the SDK, it may need `.takeUnretainedValue()` after `IOServiceMatching(name)`.
- Error about `ApplicationServices` / `AXIsProcessTrusted`: remove the import and the accessibility status line in the Permissions window, then build again; the permission buttons still work.

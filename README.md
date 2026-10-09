<h1 align="center">Dimmer</h1>
<p align="center">Your MacBook's keyboard backlight and screen dim as you close the lid, and are off before it shuts.</p>
<p align="center">
  <a href="https://github.com/kalkman-code/dimmer/releases/latest"><img src="https://img.shields.io/github/v/release/kalkman-code/dimmer" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/kalkman-code/dimmer" alt="Licence"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform: macOS">
</p>

Dimmer is a small menu bar app. It reads the angle of the lid from the Mac's own hinge sensor and
sets the keyboard backlight from it: full while the lid is open past 100 degrees, fading as it
closes, off at 68 degrees. The Settings window draws those ranges on one lid-angle axis, with a
live marker for the lid; drag any end sideways for its angle and up or down for its brightness, or
type exact values. When you pause it, quit it or the Mac goes to
sleep, it puts the backlight back the way it found it, automatic brightness included.
If macOS has dimmed the keyboard for inactivity, Dimmer leaves it dark. While paused, it finishes
keyboard restoration when input wakes the backlight; quitting while idle keeps the recovery record
for the next launch. Wake the keyboard before quitting to restore it immediately.

It dims the built-in screen along its own range, by default from your own brightness at 100 degrees
down to black at 68 degrees, and puts it back when you open the lid again, pause or quit. It leaves the Mac's
automatic screen brightness setting alone. Screen dimming and keyboard dimming are both on by default;
each lane in Settings has its own switch, so either can be left alone.

Settings also has an optional snap-to-blur privacy veil, off by default. Once on, a quick lid snap
into its angle zone (68 to 99 degrees by default) frosts every screen at once; typing, moving the
mouse or trackpad, scrolling or clicking clears it at once, and pushing the lid back up clears it
with a fade duration you set (80 ms by default), after detecting a 3-degree lift. Set the snap size and speed and the blur strength
there too, and a tint from a light frost to dark smoke, with a live preview of the veil. With the
default ranges the screen still dims inside the default zone, so when you turn snap on Settings
says so and offers to move the screen range below the zone.

A quick downward movement that falls short of a full snap shows a partial veil, then fades away;
input clears this near-miss veil immediately. Reduce Transparency skips near-miss veils and uses
an opaque cover for a locked snap or privacy shortcut.

The privacy shortcut, Ctrl+Cmd+P, blurs every screen: press and release it in any app and the veil
comes up at once, snap on or off; typing, the trackpad or lifting the lid clears it. Change or
clear it in Settings.

Go dark, in the panel and the menu bar icon's right-click menu, is available when the lid sensor
has connected. It fades the keyboard and screen to off without
moving the lid, even with either dimming lane off or the keyboard handed back to you. The fade
starts from their current brightness. A key, the trackpad or mouse, or moving the lid brings them back;
a keyboard that had been handed back stays under your control afterwards.

Keep awake keeps the Mac awake for 15 minutes, 1, 2 or 5 hours, until a time you choose, or
indefinitely, and can keep the display awake too. The panel has Off, 1 hour and Indefinitely; the
full list is in Settings. It does not stop a closed
MacBook from sleeping.

It does not change what happens when the lid shuts. It makes no network connections and has no
account or telemetry. About opens a local window; Report a bug opens that window and the GitHub
issue form, and View latest release opens GitHub in your browser.

It asks for no Accessibility, Input Monitoring or Screen Recording permission: it notices typing and
the trackpad from macOS's idle counters, which say only that input happened, and the veil is a
standard macOS frosted layer, not a capture of your screen. VoiceOver can read and set every value
in Settings, the axis ends move with the arrow keys, and Reduce Motion and Reduce Transparency are
respected.

If you moved either slider in 1.0, your angles carry over to both ranges. If you never moved them,
you get the 1.1 defaults; drag the ends in Settings to change them. The Settings axis runs from
0 to 130 degrees; migrated endpoints beyond that range are clamped to its limits.

If you change the keyboard brightness yourself, with the keys or Control Centre, Dimmer steps aside
with the keyboard and says so in its panel; screen dimming, the privacy veil and Go dark carry on.
Press Pause, then Resume, to hand the keyboard back to it. The screen is different:
while the lid is part closed Dimmer keeps it on the curve even if automatic brightness moves it,
fades the picture to black at the off angle when the range ends at 0%, and always puts your brightness back when the lid is
fully open again.

## What's new in 1.2

- Ctrl+Cmd+P blurs every screen from any app; change or clear it in Settings, where the field now
  has an outline and says to click it. If you upgrade from 1.1 without a shortcut set, including
  one you cleared, you get Ctrl+Cmd+P, because 1.1 did not record clearing it; clear it again in
  Settings if you do not want it.
- If macOS has dimmed the keyboard for inactivity, Dimmer leaves it dark and lets macOS bring it
  back. Screen dimming and the privacy veil carry on meanwhile.
- One press of a keyboard brightness key always hands the keyboard back to you; before, a press
  close to Dimmer's own level could be undone. If automatic keyboard brightness was on, it comes
  back at the level you chose.
- Go dark and Keep awake are in the menu bar panel. Go dark starts from the current brightness
  and darkens both keyboard and screen even with a lane switched off.
- Settings fits smaller screens and opens where you left it. An uninstall guide is under More in
  the panel.
- VoiceOver reads each Settings control's name once, and every switch and the shortcut field now
  have names. With Reduce Transparency on, near-miss partial veils are skipped.
- Every other 1.1 setting carries over unchanged.

## Will it work on my Mac?

Tested on one machine: a 16-inch MacBook Pro with M1 Max (2021, `MacBookPro18,2`) on macOS 27.2.
It needs macOS 14 or later and a MacBook with a lid-angle sensor. If your Mac has no sensor, the
panel says "Built-in lid angle sensor is unavailable." and Dimmer dims nothing.

The app is universal, so it also runs on Intel Macs, but Intel is untested. Only an Intel MacBook
with the hinge sensor can work, reportedly the 2019 16-inch MacBook Pro onwards. If you try it on
one, a bug report saying whether it worked is welcome either way.

Dimmer uses interfaces Apple does not document: the lid-angle sensor over IOKit HID, the private
CoreBrightness framework for the keyboard backlight, the private DisplayServices framework for
the screen, and a private SkyLight window-server property that lets it hide the pointer while the
privacy veil is up. A macOS update can break any of them without notice. If it stops working, [open a bug report](https://github.com/kalkman-code/dimmer/issues/new?template=bug_report.yml)
with your Mac model and macOS version.

## Install

1. Download `Dimmer-1.2.0.dmg` from the [latest release](https://github.com/kalkman-code/dimmer/releases/latest).
   It is signed with a Developer ID and notarised by Apple.
2. Open it and drag Dimmer to Applications.
3. Open Dimmer. Its icon, a diamond cut across by a line, appears in the menu bar. Click it for the
   panel; right-click it for Settings, Go dark, About, Pause and Quit; the diamond turns to an outline while
   paused. The first time Dimmer opens, Settings shows a short welcome that explains what runs and offers Launch at Login, which is
   also in Settings. You can hide the menu bar icon there too; open Dimmer again from Applications
   or Spotlight to get Settings back.

To check a download, compare `shasum -a 256 Dimmer-1.2.0.dmg` with `SHA256SUMS` on the release.

## Uninstall

Turn off Launch at Login in Dimmer Settings. Wake the keyboard with a key or trackpad input,
then choose Quit Dimmer. Check that the keyboard and screen brightness have returned; quitting
also restores automatic keyboard brightness, screen colour and releases Keep awake.
Move Dimmer from Applications to the Bin in Finder.

After restoration and quitting, optional leftovers are
`~/Library/Preferences/uk.co.kalkmancode.Dimmer.plist`,
`~/Library/Application Support/Dimmer/keyboard-recovery.json` and
`~/Library/Application Support/Dimmer/display-recovery.json`.
Remove only these files; the Application Support folder can be removed if empty.
If brightness did not return, keep the recovery files and reopen Dimmer with the keyboard awake
before trying again. An in-app guide is available under More → Uninstall Dimmer… and in the app menu.

## Build from source

You need a release (not beta) Xcode 16 or later, for the Swift 6 tools.

```sh
git clone https://github.com/kalkman-code/dimmer.git
cd dimmer
scripts/build-app.sh
open build/Dimmer.app
```

`scripts/build-app.sh` builds the release binary and assembles an ad hoc signed `build/Dimmer.app`.
`swift test` runs the tests.

## Reporting a bug

Use the [bug report form](https://github.com/kalkman-code/dimmer/issues/new?template=bug_report.yml).
About Dimmer (in the menu bar icon's right-click menu) shows your version, build, macOS and Mac
model, with a button that copies them. The form asks for those and what the Dimmer panel shows, which is usually enough
to tell a missing sensor from a macOS change. Forks and pull requests are welcome.

## Licence

GPL-3.0. See [LICENSE](LICENSE). Dimmer is not affiliated with or endorsed by Apple.

The optional privacy shortcut uses [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
by Sindre Sorhus, under the MIT licence. Its notice is included in the app’s resources.

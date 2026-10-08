<h1 align="center">Dimmer</h1>
<p align="center">Your MacBook's keyboard backlight dims as you close the lid, and is off before it shuts.</p>
<p align="center">
  <a href="https://github.com/kalkman-code/dimmer/releases/latest"><img src="https://img.shields.io/github/v/release/kalkman-code/dimmer" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/kalkman-code/dimmer" alt="Licence"></a>
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" alt="Platform: macOS">
</p>

Dimmer is a small menu bar app. It reads the angle of the lid from the Mac's own hinge sensor and
sets the keyboard backlight from it: full brightness while the lid is open past 85 degrees, fading
as it closes, off at 30 degrees. Both angles are sliders in its panel. When you pause it, quit it
or the Mac goes to sleep, it puts the backlight back the way it found it, automatic brightness
included.

It dims the built-in screen along the same curve, from the brightness it had while the lid was
fully open, and puts it back when you open the lid again, pause or quit. It leaves the Mac's
automatic screen brightness setting alone. Screen dimming is on by default; turn off Dim screen
too in the panel if you only want the keyboard.

It does not change what happens when the lid shuts. It makes no network connections and has no
account or telemetry.

If you change the keyboard brightness yourself, with the keys or Control Centre, Dimmer steps aside
and says so in its panel; press Pause, then Resume, to hand control back to it. The screen is different:
while the lid is part closed Dimmer keeps it on the curve even if automatic brightness moves it,
fades the picture to black at the off angle, and always puts your brightness back when the lid is
fully open again.

## Will it work on my Mac?

Tested on one machine: a 16-inch MacBook Pro with M1 Max (2021, `MacBookPro18,2`) on macOS 27.2.
It needs macOS 14 or later and a MacBook with a lid-angle sensor. If your Mac has no sensor, the
panel says "Built-in lid angle sensor is unavailable." and Dimmer does nothing.

The app is universal, so it also runs on Intel Macs, but Intel is untested. Only an Intel MacBook
with the hinge sensor can work, reportedly the 2019 16-inch MacBook Pro onwards. If you try it on
one, a bug report saying whether it worked is welcome either way.

Dimmer uses interfaces Apple does not document: the lid-angle sensor over IOKit HID, the private
CoreBrightness framework for the keyboard backlight and the private DisplayServices framework for
the screen. A macOS update can break any of them without notice. If it stops working, [open a bug report](https://github.com/kalkman-code/dimmer/issues/new?template=bug_report.yml)
with your Mac model and macOS version.

## Install

1. Download `Dimmer-1.0.1.dmg` from the [latest release](https://github.com/kalkman-code/dimmer/releases/latest).
   It is signed with a Developer ID and notarised by Apple.
2. Open it and drag Dimmer to Applications.
3. Open Dimmer. Its icon, a diamond cut across by a line, appears in the menu bar. Click it for the
   panel; right-click it to pause or quit, and the diamond turns to an outline while paused. Turn on
   Launch at Login in the panel if you want it at every start.

To check a download, compare `shasum -a 256 Dimmer-1.0.1.dmg` with `SHA256SUMS` on the release.

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
It asks for your macOS version, Mac model and what the Dimmer panel shows, which is usually enough
to tell a missing sensor from a macOS change. Forks and pull requests are welcome.

## Licence

GPL-3.0. See [LICENSE](LICENSE). Dimmer is not affiliated with or endorsed by Apple.

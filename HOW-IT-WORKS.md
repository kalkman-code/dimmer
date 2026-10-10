# How Dimmer works

## Lid angle and brightness

Dimmer reads the lid angle from the MacBook’s hinge sensor. By default, the keyboard is full above 100 degrees and fades to off at 68 degrees. The built-in screen has its own range: it takes your normal brightness at 100 degrees and dims to black at 68 degrees. Keyboard and screen dimming are both on by default, and each has its own switch in Settings.

Settings shows the ranges on one lid-angle axis from 0 to 130 degrees, with a live marker for the lid. Drag an endpoint sideways to change its angle and up or down to change its brightness, or type exact values. Endpoints migrated from an earlier version that fall outside the axis are clamped to its limits.

Dimmer leaves the Mac’s automatic screen brightness setting alone. While the lid is partly closed, it keeps the screen on its curve even if automatic brightness moves it. When the lid is fully open again, it restores your brightness. If the screen range ends at 0%, the picture fades to black at the off angle.

## Keyboard control and recovery

If you change keyboard brightness yourself with the keys or Control Centre, Dimmer steps aside with the keyboard and says so in its panel; one press of a brightness key is always enough, even close to Dimmer's own level. Screen dimming, the privacy veil and Go dark carry on. Press Pause, then Resume, to hand the keyboard back to Dimmer. If automatic keyboard brightness was on, it returns at the level you chose.

When macOS dims the keyboard for inactivity, Dimmer leaves it dark and lets macOS bring it back. While paused, Dimmer finishes keyboard restoration when input wakes the backlight. If you quit while the keyboard is idle-dimmed, Dimmer keeps the recovery record for the next launch. Wake the keyboard before quitting to restore it immediately.

When you pause or quit Dimmer, or the Mac goes to sleep, it restores the keyboard backlight to the way it found it, including automatic brightness. It also restores the screen brightness when paused or quit, and when the lid is fully open again.

Dimmer does not change what happens when the lid shuts. Quitting also restores screen colour and releases Keep awake.

## Menu bar and windows

Click the menu bar icon for the panel; right-click it for Settings, Go dark, About, Pause and Quit. The diamond turns to an outline while paused. You can hide the menu bar icon in Settings; open Dimmer again from Applications or Spotlight to get Settings back. Settings fits smaller screens and opens where you left it.

About opens a local window. Report a bug opens that window and the GitHub issue form, and View latest release opens GitHub in your browser; Dimmer itself makes no network connections.

## Privacy veil

The optional snap-to-blur veil is off by default. Turn it on in Settings, then snap the lid quickly down into its zone, 68 to 99 degrees by default. Closing the lid slowly does not trigger it. A locked snap frosts every screen at once and hides the pointer. Typing, moving or touching the trackpad or mouse, scrolling, or clicking clears the veil at once. Pushing the lid back up clears it with a fade; the default fade duration is 80 ms, and the default lift detection is 3 degrees. Settings lets you change the snap zone, speed, blur strength, tint and fade, with a live preview.

With the default ranges, the screen still dims inside the default snap zone. Settings explains the overlap and offers to move the screen range below the zone.

A quick downward movement that falls short of a full snap shows a partial near-miss veil, then fades away. Input clears it immediately. With Reduce Transparency enabled, near-miss veils are skipped and a locked snap or privacy shortcut uses an opaque cover.

Ctrl+Cmd+P brings up the same veil from any app, whether snap-to-blur is on or off. Change or clear the shortcut in Settings. Typing, trackpad input or lifting the lid clears it.

## Go dark and Keep awake

Go dark is available in the panel and the menu bar icon’s right-click menu when the lid sensor has connected. It fades the keyboard and screen to off without moving the lid, even if either dimming lane is off or the keyboard has been handed back to you. The fade starts from their current brightness. A key, trackpad or mouse input, or moving the lid brings them back; a keyboard that had been handed back stays under your control.

Keep awake can keep the Mac awake for 15 minutes, 1, 2 or 5 hours, until a time you choose, or indefinitely. It can keep the display awake too. The panel offers Off, 1 hour and Indefinitely; the full list is in Settings. Keep awake does not stop a closed MacBook from sleeping.

## System interfaces

Dimmer uses undocumented Apple interfaces: the lid-angle sensor over IOKit HID, the private CoreBrightness framework for keyboard backlight control, the private DisplayServices framework for the screen, and a private SkyLight window-server property that lets it hide the pointer while the privacy veil is up. A macOS update can break any of them without notice.

## Earlier settings

If you moved either slider in version 1.0, your angles carry over to both ranges. If you never moved them, you get the defaults: full past 100 degrees and off at 68 degrees. Drag the endpoints in Settings to change them.

Version 1.2 keeps settings from 1.1. If you had no privacy shortcut, including one you cleared, version 1.2 gives you Ctrl+Cmd+P because 1.1 did not record that the shortcut was cleared. Clear it again in Settings if you do not want one. Every other 1.1 setting carries over unchanged.

## Accessibility

VoiceOver can read and set every value in Settings, and the axis endpoints move with the arrow keys. Dimmer respects Reduce Motion and Reduce Transparency. With Reduce Transparency on, near-miss partial veils are skipped.

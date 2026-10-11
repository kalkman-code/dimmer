# How Dimmer works

## Lid angle and brightness

Dimmer reads the lid angle from the MacBook’s hinge sensor. By default, the keyboard is full above 100 degrees and fades to off at 68 degrees. The built-in screen has its own range: it takes your normal brightness at 100 degrees and dims to black at 68 degrees. Keyboard and screen dimming are both on by default, and each has its own switch in Settings.

Settings has one box per feature (Keyboard, Screen, Snap to blur, Blur by angle and Privacy veil). The four lid features each have a bar on a lid-angle scale from 0 to 130 degrees, with a live marker for the lid, while switched on. When Snap to blur is off, its box collapses to the title and switch; its tint and restore controls are hidden. Snap tint affects only the snap veil. Privacy veil has a separate tint for the shortcut veil. Drag an endpoint sideways to change its angle and up or down to change its brightness, or type exact values. With an endpoint focused, left and right change its angle by 1 degree; up and down change its brightness by 5 percentage points. For the snap-zone endpoints, left and right still change the angle by 1 degree, while up and down change the shared blur strength by 5 points. Exact typing keeps normal caret behaviour. Endpoints migrated from an earlier version that fall outside the axis are clamped to its limits.

Press Cmd+Z in Settings to undo a completed change to either range or to the privacy settings, and Shift+Cmd+Z to redo it. One drag, one slider movement or one exact value typed in is one step, and undoing a drag that pushed the other end of a range along returns both ends. While you are typing a number, Cmd+Z undoes the typing, not the setting. Restore keyboard range, Restore screen range, Restore snap defaults, Restore blur defaults and Restore privacy veil defaults each reset only their own settings. Snap restore resets its zone, snap distance, speed and tint; Blur restore resets its range and tint; Privacy veil restore resets blur strength, clear speed and shortcut tint, leaving Snap tint unchanged. Each restore can be undone, leaves other boxes alone, does not change shortcut assignments, and does not switch Snap on or off.

Dimmer leaves the Mac’s automatic screen brightness setting alone. While the lid is partly closed, it keeps the screen on its curve even if automatic brightness moves it. When the lid is fully open again, it restores your brightness. If the screen range ends at 0%, the picture fades to black at the off angle. When Dimmer cannot dim the screen, it says why under the Screen readout in the panel and in Settings: waiting for the lid to open fully once, restoring your brightness, or unable to control the display.

## Keyboard control and recovery

If you change keyboard brightness yourself with the keys or Control Centre, Dimmer steps aside with the keyboard and says so in its panel; one press of a brightness key is always enough, even close to Dimmer's own level. Screen dimming, the privacy veil and Go dark carry on. Choose Resume keyboard dimming in the menu bar panel to hand the keyboard back to Dimmer. If automatic keyboard brightness was on, it returns at the level you chose.

When macOS dims the keyboard for inactivity, Dimmer leaves it dark and lets macOS bring it back. While paused, Dimmer finishes keyboard restoration when input wakes the backlight. If you quit while the keyboard is idle-dimmed, Dimmer restores your brightness anyway. If the hardware ignores it, Dimmer keeps the recovery record so reopening the app finishes it.

When you pause or quit Dimmer, or the Mac goes to sleep, it restores the keyboard backlight to the way it found it, including automatic brightness. It also restores the screen brightness when paused or quit, and when the lid is fully open again.

Dimmer does not change what happens when the lid shuts. Quitting also restores screen colour and releases Keep awake.

## Menu bar and windows

Click the menu bar icon for the panel; right-click it for Settings, About, Check for updates…, Go dark, Pause and Quit. The diamond turns to an outline while paused. Pause for 15 minutes or 1 hour, from the panel or the right-click menu, and Dimmer resumes by itself: the panel shows the time, and a pause that ran out while the Mac slept ends as soon as it wakes. Resume ends it early. You can hide the menu bar icon in Settings; open Dimmer again from Applications or Spotlight to get Settings back. Settings fits smaller screens and opens where you left it.

About opens a local window. Report a bug opens that window and the GitHub issue form, and View latest release opens GitHub in your browser. The update check below is the only connection Dimmer itself makes.

## Updates

Dimmer 1.3 and later update through [Sparkle](https://sparkle-project.org) 2.10.0. Earlier versions have no updater, so 1.2.1 and before are updated to 1.3 by hand, once.

Nothing is checked until you agree. On Dimmer's second launch Sparkle asks whether to check for updates automatically; Settings → Updates changes that answer at any time. With automatic checks on, Dimmer fetches `https://kalkmancode.co.uk/dimmer/appcast.xml` once a day while it is running. Check for updates…, in the app menu, the menu bar icon's right-click menu and the panel's More menu, or Check now in Settings → Updates, checks once whenever you choose it; Settings also shows when Dimmer last checked. The request is a plain HTTPS GET: it carries your IP address, an `Accept-Language` header with your preferred languages and a User-Agent of the form `Dimmer/1.3.0 Sparkle/2.10.0`, and no identifier or system profile, which is switched off. Cloudflare serves the feed for kalkmancode.co.uk; an update itself downloads from Dimmer's GitHub releases.

When a scheduled check finds an update, Dimmer does not throw a window in front of you. The panel shows Update available…, the right-click menu reads Update available… and Settings says an update is ready; choosing any of them brings Sparkle's update window forward with the release notes, where you install, skip that version or leave it for later. Install updates automatically is off by default and needs automatic checks on; when it is on, Sparkle downloads and installs signed updates without asking first.

Each update is checked twice before anything is replaced. The feed itself is signed with Dimmer's EdDSA key, and the downloaded disk image must carry a valid EdDSA signature from the same key, checked before it is opened, and the new app must carry a valid Apple code signature. Sparkle does not check notarisation itself; each release is notarised before it is published. If the feed's signature has failed for 20 days in a row, Sparkle's documented fallback lets it offer an update whose disk image is still correctly signed, so a replaced feed key cannot strand everyone on an old version; the disk image check never relaxes.

Installing quits Dimmer the same way Quit does, so the keyboard and screen get their brightness back first, then Sparkle replaces the app and opens the new version. Your settings, recovery records and Launch at Login stay as they were.

## Privacy veil

The optional snap-to-blur veil is off by default. Turn it on in Settings, then snap the lid quickly down into its zone, 68 to 99 degrees by default. Closing the lid slowly does not trigger it. A locked snap frosts every screen at once and hides the pointer. Typing, moving or touching the trackpad or mouse, scrolling, or clicking fades a locked snap or shortcut veil using Clear speed. Clear speed ranges from 0 to 600 ms in 10 ms steps and defaults to 80 ms; it also sets the fade after lifting the lid 3 degrees from its lowest position. Pausing, sleeping, going dark or quitting clears the veil immediately; disabling Snap clears a snap-triggered veil, leaving a shortcut veil alone. Snap tint controls only the snap veil and is available only while Snap to blur is on. Privacy veil is on by default and has its own switch. Turning it off collapses its Settings box, unregisters the shortcut and clears an active shortcut veil immediately; the recorded chord is kept, and Snap to blur and Blur by angle are unaffected. While it is on, Privacy veil holds the shortcut, its own tint, blur strength, clear speed and preview settings. Its restore link resets blur strength, clear speed and shortcut tint without changing the switch, shortcut or Snap tint.

With the default ranges, the screen still dims inside the default snap zone. Settings explains the overlap and offers to move the screen range below the zone.

A quick downward movement that falls short of a full snap shows a partial near-miss veil, then fades away with its own short fade. Input clears it using Clear speed. With Reduce Motion enabled, it clears without a fade. With Reduce Transparency enabled, near-miss veils are skipped and a locked snap or privacy shortcut uses an opaque cover that disappears immediately when cleared.

Ctrl+Cmd+P brings up the privacy veil from any app only while Privacy veil is on, whether snap-to-blur is on or off. Change or clear the shortcut in Settings. Typing or trackpad input fades it using Clear speed; lifting the lid uses the same duration.

## Blur by angle

An optional bar, off by default, blurs every screen by an amount that follows the lid angle between two ends you set (by default full at 68 degrees, none at 100). Turn it on under Blur by angle in Settings; drag its ends or type exact values like the other bars. Its Frost to Smoke tint control darkens the angle veil in proportion to its blur strength. Snap and angle blur share one window per screen: the stronger strength sets the blur, while darkness is the greater of each veil's strength-weighted tint, scaled by that stronger strength. The privacy shortcut uses its own tint, independent of Snap tint. This prevents blur or tint from stacking. Unlike the snap veil it is not cleared by typing or the trackpad and it never hides the pointer, because it is a function of the lid, not a privacy action. Pause, sleep, Go dark and quitting clear it at once, and with Reduce Transparency on it is switched off rather than turned into an opaque cover.

## Go dark and Keep awake

Go dark is available in the panel and the menu bar icon’s right-click menu when the lid sensor has connected. It fades the keyboard and screen to off without moving the lid, even if either dimming lane is off or the keyboard has been handed back to you. The fade starts from their current brightness. A key, trackpad or mouse input, or moving the lid brings them back; a keyboard that had been handed back stays under your control. You can also record a shortcut for Go dark in Settings; none is set by default, it cannot match the privacy shortcut, it acts when you let go of it, and it does nothing while Dimmer is paused or the Mac is asleep.

Keep awake can keep the Mac awake for 15 minutes, 1, 2 or 5 hours, until a time you choose, or indefinitely. It can keep the display awake too. The panel offers every preset except "Until a time", which stays in Settings. Keep awake does not stop a closed MacBook from sleeping.

## System interfaces

Dimmer uses undocumented Apple interfaces: the lid-angle sensor over IOKit HID, the private CoreBrightness framework for keyboard backlight control, the private DisplayServices framework for the screen, and a private SkyLight window-server property that lets it hide the pointer while the privacy veil is up. A macOS update can break any of them without notice.

## Earlier settings

If you moved either slider in version 1.0, your angles carry over to both ranges. If you never moved them, you get the defaults: full past 100 degrees and off at 68 degrees. Drag the endpoints in Settings to change them.

Version 1.2 keeps settings from 1.1. If you had no privacy shortcut, including one you cleared, version 1.2 gives you Ctrl+Cmd+P because 1.1 did not record that the shortcut was cleared. Clear it again in Settings if you do not want one. Every other 1.1 setting carries over unchanged.

## Accessibility

VoiceOver can read and set every value in Settings, and the axis endpoints move with the arrow keys. Dimmer respects Reduce Motion and Reduce Transparency. With Reduce Transparency on, near-miss partial veils are skipped.

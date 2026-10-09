# Design

## Surfaces

Dimmer has a compact menu-bar panel for live status and quick actions, plus one fixed-width Settings window for configuration. The settings window uses the dark veil body (`#141416`), raised grouped sections, native macOS typography and controls. It opens as a regular app and returns to accessory mode when closed.

## Lid axis

The settings hero maps the full hinge angle to one horizontal axis. Keyboard and Screen use independent brightness ramps: warm lamp (`#E9C891`) and silver (`#E2E5EA`). Privacy uses a hatched moonlight band (`#B9C8E6`). Filled endpoint handles show each angle and level and grow on hover, with a hand cursor (↔ on the zone edges) and a live value label while dragging; the live lid position is a white line and capsule. Drag anywhere near an end to move it, or type exact endpoints in the grid of equal 46 pt fields below the axis. Screen control is handed back above its high endpoint.

The lanes dim when their feature is off. Hairlines use `#2A2A30`; secondary labels use `#9A9EA7`. The screen's dashed continuation marks the brightness returned to the user.

## Snap to blur

The privacy veil appears immediately on every display after a sufficiently fast lid snap lands in the configured zone. Its strength is the opacity of the frosted layer and is previewed with a document tile in Settings. Keyboard, pointer, scroll or click input after the grace period clears the veil; lifting the lid above the zone clears it as well. The full-screen windows ignore mouse events.

## Menu bar panel

The panel shows the current state, lid angle, keyboard level and screen level, with “Yours” when display control has been handed back. A segmented Keep awake control exposes Off, 1 hour and Indefinitely, plus the selected duration when another choice is active. Settings…, Pause/Resume and Quit Dimmer are the remaining actions.

## Interaction

Changes apply immediately. Every axis handle is keyboard and accessibility adjustable. Left and right move one degree; up and down change brightness by five percentage points. Keep motion to native control feedback; privacy blur appears without animation.

## Menu bar mark

Use a white template SF Symbol for the dimming control. Do not place text beside it; use its state to distinguish active from paused.

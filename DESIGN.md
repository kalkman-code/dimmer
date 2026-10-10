# Design

## Surfaces

Dimmer has a compact menu-bar panel for live status and quick actions, plus one resizable Settings window for configuration. The settings window uses the dark veil body (`#141416`), raised grouped sections, native macOS typography and controls. It opens as a regular app and returns to accessory mode when closed. It cannot be minimised; its position and width are remembered and its height fits the available screen, with the Form scrolling on smaller displays. Localised descriptions wrap; the welcome scrolls within the available height. The panel is 320 points wide in every language; Keep awake becomes a pop-up menu where its segments do not fit.

## Lid axis

The settings hero maps 0–130 degrees to one horizontal axis; migrated endpoints are clamped to those limits. Keyboard and Screen use independent brightness ramps: warm lamp (`#E9C891`) and silver (`#E2E5EA`). Privacy uses a flat moonlight band (`#B9C8E6`), hidden with snap off. Filled endpoint handles have floating capsule tags for angle and brightness; each number becomes a borderless field while editing. Hover changes the cursor; handles retain their size. Drag near an endpoint to move it, or activate its number to type an exact value. The live lid position is a white line and angle capsule. Screen control is handed back above its high endpoint.

The lanes dim when their feature is off. Hairlines use `#2A2A30`; secondary labels use `#9A9EA7`. Wells use `#111113`, value tags `#232328`, axis ticks `#4A4D55` and controls `#6F84AD`. The screen ramp stops at its high endpoint with a vertical return mark.

## Snap to blur

The privacy veil appears immediately on every display after a sufficiently fast lid snap lands in the configured zone. Near misses show a partial veil that fades away and clears immediately on input; Reduce Transparency skips them and keeps a locked snap or shortcut as an opaque cover. Its strength is previewed with a document tile in Settings. Input after the grace period clears a locked veil; lifting the lid 3 degrees from its lowest position also clears it. Clear speed controls the fade after that lift is detected, including a privacy shortcut. The full-screen windows ignore mouse events.

## Menu bar panel

The panel shows the current state, lid angle, keyboard level and screen level, with “Yours” when display control has been handed back. Keep awake exposes Off, 1 hour and Indefinitely, plus the selected duration when another choice is active; a segmented control uses a native menu when its translated labels exceed the available width. Its deadline or error appears below. Go dark is directly available alongside Settings…, Pause/Resume and Quit Dimmer. More contains About, support, release and uninstall guidance.

## Interaction

Changes apply immediately. Axis number controls use edit focus interactions and a custom focus ring so they can join the Tab loop with system Keyboard navigation off; live acceptance remains an integrator check. Left and right move angles by one degree; up and down change brightness by five percentage points. Locked privacy blur appears without animation; partial veils and clearing use short fades, disabled with Reduce Motion. Go dark is disabled until a live lid sample is available. It captures current keyboard, display and gamma levels for its fade, regardless of lane switches or a keyboard yield; waking returns to ordinary lane behaviour and preserves the yield.

## Menu bar mark

Use the diamond template glyph for the dimming control, outlined while paused. Do not place text beside it; use its state to distinguish active from paused.

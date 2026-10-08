# Design

## Surface

One compact menu-bar control panel. Use native macOS typography, spacing, labels, sliders, and switches. No standalone window or branded colour palette.

## Hierarchy

1. Current state: running, paused, or the reason hardware control is unavailable.
2. Current lid angle, keyboard brightness and screen brightness.
3. The two adjustable angle endpoints: fully lit and off.
4. Screen dimming and Launch at Login.
5. Pause and Quit.

## Menu bar mark

Use a white template SF Symbol for a dimming control. Do not place text beside it; use its state to distinguish active from paused.

## Interaction

Changes apply immediately. Sliders show values in degrees. Keep the surface concise and avoid animation beyond native control feedback.

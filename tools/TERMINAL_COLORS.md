# Terminal text contrast

Anvil corrects low-contrast text in Terminal Views. The default target is 4.5:1.
The correction works with light and dark Color Themes.

## Settings

Open Settings, then Terminal. Change **Minimum Text Contrast**.

- Set `1` to turn correction off.
- Set a higher value to request more contrast.
- Changes apply to running Terminal Views.

The Lua setting is `config.plugins.terminal.minimum_contrast`.

## Behavior

Anvil checks text against its cell background after reversed colors and selection highlighting.
It includes dim-text opacity in the check. Readable text keeps its original color and opacity.

For low-contrast text, Anvil changes Oklab lightness. It reduces chroma when needed to fit sRGB.
It keeps hue where possible and checks the final RGB color against the requested contrast.
It does not rotate colors toward the Color Theme or replace program backgrounds.

Hidden text stays hidden. Box-drawing, block, Powerline, and legacy graphics keep their requested colors.
Terminal Text Capture uses the same correction without the live terminal selection highlight.
Saved captures retain their captured colors.

Anvil changes display colors only. Color queries still report the terminal model's original colors.
The bounded session cache stores results for text/background/opacity combinations.
Changing the contrast setting clears that cache.

A high target can exceed the best possible contrast for a background.
In that case, Anvil uses black or white, whichever gives more contrast.
A contrast target does not certify the whole interface for WCAG compliance.

## Code

- `src/terminal_contrast.c`: Oklab correction, RGB contrast checks, and caching.
- `src/api/terminal_native.c`: cell colors, selection backgrounds, and capture colors.
- `data/plugins/terminal.lua`: settings and display.
- `data/plugins/anvil_defaults.lua`: the first-party contrast default.

The Oklab matrices come from Bjorn Ottosson's public-domain reference code:
https://bottosson.github.io/posts/oklab/

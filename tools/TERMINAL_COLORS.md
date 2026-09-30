# Terminal text contrast

Anvil corrects low-contrast text in Terminal Views. The default target is 4.5:1.
The correction works with light and dark Color Themes.

## Settings

Open Settings, then Terminal. Change **Minimum Text Contrast**.

- Set `1` to turn correction off.
- Set a higher value to request more contrast.
- Changes apply to running Terminal Views.

The theme default is `style.terminal_minimum_contrast`.

The Command Palette also has **Terminal: Set Minimum Text Contrast**.
It opens the Global Prompt Bar and saves the entered value for the displayed theme.

### Color Vividness

Run **Terminal: Set Color Vividness** and enter a percentage from `0` to `100`.
You can also change **Color Vividness** under Settings, then Terminal.

- `0` keeps the previous correction. This is the default.
- `100` requests the strongest available color intensity while keeping hue and contrast.
- Intermediate values increase color intensity between those two results.

The value applies to corrected text only. Already-readable text keeps its original color.
Neutral text stays neutral. High contrast targets can leave little room for color intensity.
Changing vividness can also change lightness to keep the requested contrast.

The theme default is `style.terminal_color_vividness`.
Anvil saves personal changes in `USERDIR/colors/edits/<theme>.lua`, under `terminal`.
Each theme keeps its own values. Switching themes restores those values.
Changes apply to running Terminal Views, including hidden Views.

### Copy tested values

Run **Terminal: Copy Color Settings** after you tune a theme.
Paste the result into an agent to request a source-default change.

The text contains the displayed theme, loaded source file, and both effective values.
For bundled themes, it also names the repository file under `data/colors/`.
The command copies Lua assignments and asks the agent to make them the theme defaults.
It does not change source files.

The base schema defines both values in `data/colors/default.lua`.
Other themes can override them. Personal changes take priority over source defaults.
Remove the theme's personal terminal changes when you want to test new source defaults.
The former global plugin settings no longer control these values.

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
Changing vividness also clears the cache. Vividness uses a bounded Oklab chroma search inside sRGB.
The search checks final RGB contrast and keeps the closest available lightness at the requested chroma.

A high target can exceed the best possible contrast for a background.
In that case, Anvil uses black or white, whichever gives more contrast.
A contrast target does not certify the whole interface for WCAG compliance.

## Code

- `src/terminal_contrast.c`: Oklab correction, RGB contrast checks, and caching.
- `src/api/terminal_native.c`: cell colors, selection backgrounds, and capture colors.
- `data/plugins/terminal.lua`: settings and display.
- `data/colors/default.lua`: the base contrast and vividness defaults.
- `data/core/theme_edits.lua`: per-theme personal changes.

The Oklab matrices come from Bjorn Ottosson's public-domain reference code:
https://bottosson.github.io/posts/oklab/

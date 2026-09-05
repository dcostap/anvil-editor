# Resources

This folder contains resources that is used for building or packaging the project.

### Build

- `cross/*.ini`: Meson [cross files][1] for cross-compiling anvil on other platforms.

### Packaging

- `icons/logo.svg`: source artwork for the Anvil app logo.
- `icons/logo.png`, `icons/icon.{icns,ico,inl,rc}`: Anvil icons for each platform.
- `linux/io.github.dcostap.Anvil.appdata.xml`: AppStream metadata.
- `linux/io.github.dcostap.Anvil.desktop`: Desktop file for Linux desktops.
- `macos/appdmg.png`: Background image for packaging MacOS DMGs.
- `macos/Info.plist.in`: Template for generating `info.plist` on MacOS. See `macos/macos-retina-display.md` for details.
- `windows/001-lua-unicode.diff`: Patch for allowing Lua to load files with UTF-8 filenames on Windows.
- `portable/README.md`: Copied to the `user` directory of portable builds.

### Development

Regenerate all app icons and installer images from `icons/logo.svg`:

```sh
python tools/update_anvil_icon.py --inkscape "C:/Program Files/Inkscape/bin/inkscape.exe"
```

Run this command from the repository root. It needs Python, Pillow, and Inkscape.
If Inkscape is on `PATH`, omit `--inkscape`.
Normal builds use the generated files. They do not need Inkscape or Pillow.

The square icons keep the artwork's proportions and transparent background.
The Windows icon includes sizes from 16 to 256 pixels.
The macOS icon includes sizes up to 1024 pixels.
The native window icon uses 64-pixel RGBA data in `icons/icon.inl`.
The welcome screen and Linux packages use `icons/logo.png`.

- `include/anvil_plugin_api.h`: Native plugin API header. See the contents
of `anvil_plugin_api.h` for more details. (TODO: to be dropped in favor of
dynamic linking)

### Other Files

- `shell.html`: A shell file for use with WASM builds.


[1]: https://mesonbuild.com/Cross-compilation.html

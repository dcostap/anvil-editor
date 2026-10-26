# Anvil

A fast Windows code editor with built-in terminals, made for running coding agents side by side.

![Anvil with several Projects and coding agents](docs/screenshots/workspace.png)

## Download

Get `anvil.exe` from the [latest release](https://github.com/dcostap/anvil-editor/releases/latest) and run it. Nothing to install.

The exe is not signed, so Windows SmartScreen can warn you. Click **More info**, then **Run anyway**.

## Build

```bat
git clone https://github.com/dcostap/anvil-editor
cd anvil-editor
build.bat
```

The result is `dist\anvil.exe`. `build.bat` installs MSYS2 and the build tools when they are missing.

## Credits

Anvil started as a fork of [Pragtical](https://github.com/pragtical/pragtical), which comes from [Lite XL](https://github.com/lite-xl/lite-xl) and [lite](https://github.com/rxi/lite). MIT license.

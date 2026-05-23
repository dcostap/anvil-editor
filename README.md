# Anvil

The practical and pragmatic code editor.

[website] | [documentation] | [download]

[![Build Rolling]](https://github.com/dcostap/anvil-editor/actions/workflows/rolling.yml)
[![Discord]](https://discord.gg/8V2yJtn3Fc)

![screenshot](https://github.com/dcostap/anvil-editor/assets/img/editor.png)

## Download

* **[Get Anvil]** — Download Pre-built releases for Windows, Linux and Mac OS.
* **[Get Plugins]** — Add additional functionality.
* **[Get Color Themes]** — Additional color themes (bundled with all releases
of Anvil by default).

A list of changes is registered on the [changelog] file. Please refer to our
[website] for the user and developer [documentation], including more detailed
[build] instructions.

## Quick Build Guide

1. Clone this repository

```sh
git clone https://github.com/dcostap/anvil-editor
```

2. Setup and compile the project

```sh
meson setup --wrap-mode=forcefallback -Dportable=true build
meson compile -C build
```

> [!NOTE]
> We set `--wrap-mode` to forcefallback to download and build all the dependencies
> which will take longer. If you have all dependencies installed on your system
> you can skip this flag. Also notice we set the `portable` flag to true, this
> way the install process will generate a directory structure that is easily
> relocatable.

3. Install and profit!

```sh
meson install -C build --destdir ../anvil
```

You will now see a new directory called `anvil` that will contain the
executable and all the necessary files to run the editor. Feel free to move or
rename this directory however you wish.

For more detailed instructions visit: https://github.com/dcostap/anvil-editor#building

## Contributing

Pull requests to improve or modify the editor itself are welcome.

Additional functionality can be added through a plugin by sending a
pull request to the [plugins repository]. If you think the functionality should
be added to the core editor open an issue so we can discuss it.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

See the [licenses] directory for details on licenses used by the required dependencies.


[Build Rolling]:      https://github.com/dcostap/anvil-editor/actions/workflows/rolling.yml/badge.svg
[Discord]:            https://discord.com/api/guilds/1285023036071743542/widget.png?style=shield
[website]:            https://github.com/dcostap/anvil-editor
[documentation]:      https://github.com/dcostap/anvil-editor
[download]:           https://github.com/dcostap/anvil-editor/releases
[build]:              https://github.com/dcostap/anvil-editor#building
[Get Anvil]:      https://github.com/dcostap/anvil-editor/releases
[Get Plugins]:        https://github.com/pragtical/plugins
[Get Color Themes]:   https://github.com/pragtical/colors
[plugins repository]: https://github.com/pragtical/plugins
[changelog]:          changelog.md
[LICENSE]:            LICENSE
[licenses]:           licenses/licenses.md

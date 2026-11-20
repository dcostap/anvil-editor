# Third-party notices

Anvil includes the components below. Their licenses apply to those components, not to Anvil as a whole.

The Windows standalone executable embeds this document and the license texts. It extracts them to `%LOCALAPPDATA%\Anvil\runtime\<build-id>\data\doc` on first start. Installed builds include them in the documentation folder.

## FreeType

Anvil uses FreeType 2.14.3 under the FreeType License, not its alternative GPL license.

This software is based in part on the work of the FreeType Team.

Portions of this software are copyright © 1996-2026 The FreeType Project (https://freetype.org). All rights reserved.

See [FreeType licenses](third-party/freetype-licenses.txt), [FreeType License](third-party/freetype.txt), [BDF notices](third-party/freetype-bdf.txt), and [PCF notices](third-party/freetype-pcf.txt).

## LuaJIT

Anvil uses LuaJIT, including code from Lua and dlmalloc. See [copyright notices and license terms](third-party/luajit.txt).

The pinned source revision is `a4c064539ea931274d407e1249b4bb575424a0f4` in [LuaJIT](https://github.com/LuaJIT/LuaJIT).

## PCRE2

Anvil links PCRE2 10.47. The bundled ripgrep helper includes PCRE2 10.45.

See [PCRE2 10.47](third-party/pcre2.txt), [PCRE2 10.45](third-party/ripgrep-pcre2.txt), and [SLJIT](third-party/sljit.txt) for copyright notices and license terms.

## Mbed TLS and TF-PSA-Crypto

Anvil uses Mbed TLS 4.1.0 and its TF-PSA-Crypto library under Apache License 2.0, not their alternative GPL license.

Copyright The Mbed TLS Contributors.

See [Mbed TLS license terms](third-party/mbedtls.txt) and [TF-PSA-Crypto license terms](third-party/tf-psa-crypto.txt).

## libpng and zlib

Anvil uses libpng 1.6.58 and zlib 1.3.2. See [libpng notices](third-party/libpng.txt) and [zlib notices](third-party/zlib.txt).

## libjpeg-turbo

Anvil uses the libjpeg API from libjpeg-turbo 3.2.0.

This software is based in part on the work of the Independent JPEG Group.

See [libjpeg-turbo licenses](third-party/libjpeg-turbo.txt) and the [Independent JPEG Group README](third-party/jpeg-ijg.txt).

## HarfBuzz

Anvil uses HarfBuzz 13.0.1 under the Old MIT license. See [HarfBuzz notices](third-party/harfbuzz.txt).

## SDL

Anvil uses SDL3 3.4.18, SDL3_image 3.4.4, and SDL_net.

See [SDL3 notices](third-party/sdl3.txt), [SDL3_image notices](third-party/sdl3-image.txt), and [SDL_net notices](third-party/sdl3-net.txt).

## linenoise

Anvil includes linenoise. See [linenoise notices](third-party/linenoise.txt).

## uchardet

Anvil uses uchardet 0.0.8 under Mozilla Public License 1.1, not its alternative GPL or LGPL licenses.

The original code is the Mozilla universal charset detector. The initial developer is Netscape Communications Corporation.

The uchardet source code is available under MPL 1.1 from the [0.0.8 source archive](https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz). Anvil does not change its library source. Anvil's build files are in [subprojects/packagefiles/uchardet](https://github.com/dcostap/anvil-editor/tree/master/subprojects/packagefiles/uchardet).

See [uchardet license terms](third-party/uchardet.txt). The file retains all upstream license alternatives.

## ripgrep

Anvil bundles ripgrep 15.1.0 as `plugins/fuzzy_searcher/rg.exe`. It runs as a separate program; Anvil does not link it.

Anvil distributes ripgrep under the MIT license. See [ripgrep notices](third-party/ripgrep.txt) and the PCRE2 notices above. Source: [ripgrep 15.1.0](https://github.com/BurntSushi/ripgrep/tree/15.1.0).

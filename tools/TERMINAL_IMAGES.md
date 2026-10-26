# Inline terminal images

Anvil displays static images through the Kitty graphics protocol.
Programs must send image bytes through the terminal stream with direct transfer (`t=d`).
Anvil does not read image files or shared memory named by terminal output.

Supported features:

- PNG, RGB, and RGBA images.
- Chunked transfers and compression handled by Ghostty.
- Image placement, scaling, source cropping, and transparency.
- Images below cell backgrounds, below text, or above text.
- Scrolling, image replacement, and deletion.

Programs can query Kitty graphics support through the protocol.
`TERM_PROGRAM` remains `anvil`. Programs that check only known terminal names may need an explicit Kitty output option.

New Terminal Sessions set `PI_IMAGE_PROTOCOL=kitty` for Pi unless the user already set a value.
Existing shells keep their environment after an editor update. Open a new Terminal Session to get this default.
Pi's explicit `terminal.images` setting takes precedence over this environment variable.

## Quick check

Run this in a new Anvil PowerShell terminal. It displays a red rectangle:

```powershell
$e = [char]27
[Console]::Write($e + '_Ga=T,f=32,s=1,v=1,i=42,p=1,c=12,r=4,q=2;/wAA/w==' + $e + '\')
```

Delete that image:

```powershell
[Console]::Write($e + '_Ga=d,d=I,i=42,q=2' + $e + '\')
```

## Limits

- Animation and Unicode-placeholder placements are not supported by Anvil's image renderer.
- Ghostty's terminal snapshot format omits image pixels and placements.
  Programs must retransmit images after a Terminal Session reconnect or editor restart.
- Each terminal screen has a 32 MiB image storage limit.
- Visible image canvases have a 64 MiB limit. Placements beyond that limit are not drawn.
- File and shared-memory transfer methods remain disabled.

## Implementation and checks

`src/terminal_model.c` enables bounded image storage and supplies PNG decoding through SDL_image.
`src/api/terminal_native.c` copies visible source regions into owned canvases.
It reuses canvases by Ghostty image generation and source rectangle.
Cropping occurs before scaling, so filtering cannot read pixels outside the source region.
`data/plugins/terminal.lua` draws those canvases in protocol layer order.
A click opens the complete stored image in the Image Overlay, not the cropped canvas.
Pi crops a placement to the rows that its own scrolling shows.

Run the focused integration tests:

```sh
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/terminal_graphics.lua
```

The test sends real image sequences through ConPTY.
It checks pixels, placement, replacement, PNG decoding, cropping, scrolling, deletion, and retransmission after reconnect.

Run the private pixel checks on both renderers:

```sh
python tools/run_render_perf_gate.py --scenario terminal-images --renderer software --no-build --report-only
python tools/run_render_perf_gate.py --scenario terminal-images --renderer d3d11 --no-build --report-only
```

Use `--no-build` only when the native build is current.
The checks cover transparency, crop edges, terminal bounds, and image layers without using the user's windows.

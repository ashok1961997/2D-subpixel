# 2D Subpixel Proof of Concept

This is a dependency-free Zig experiment for the rendering idea discussed above.
It renders 48 BMP frames, each with two copies of a diagonal sword moving at
fractional-pixel speed:

- **Left panel:** conventional pixel-art movement. The transform is rounded to
  whole pixels and each output pixel is evaluated once.
- **Right panel:** the sword retains 8-bit fixed-point positions (256 positions
  per output pixel). Fully covered or empty pixels cost no additional work;
  pixels crossing an edge are resolved with an 8 x 8 micro-sample grid.

The point is deliberately modest: a display pixel remains one pixel. The
right-hand side only changes the *rule for resolving subpixel geometry into
that pixel*. The blend at edges makes coverage visible; a production pixel-art
renderer might replace that blend with a limited palette and ordered dithering.

## Run

With Zig 0.16 or newer installed:

```powershell
zig run main.zig
```

Name your BMPs sequentially — e.g. frame001.bmp, frame002.bmp, frame003.bmp, etc. (same folder, same base name, incrementing number).
Open the first file in Aseprite — it will auto-detect the sequence and load all frames as a sprite animation. 
Adjust frame timing in the timeline panel if needed. 
Export via File → Export to an animated format:
GIF – most universally compatible
WebP – better quality/compression
FLI / FLC – legacy animation formats
Sprite Sheet (PNG, BMP, TGA, etc.) + JSON – for game engines

On each frame, the
left panel will stay still for several frames and jump; the right panel tracks
the fractional transform continuously through changing edge coverage.

## Next experiments

1. Swap blended coverage for palette-aware Bayer dithering.
2. Keep sprites crisp but resolve only particles, weapon edges, and effects.
3. Replace the procedural sword with an animated polygon or sprite mask.
4. Move the per-pixel coverage pass into a GPU shader after the output style is
   proven useful.

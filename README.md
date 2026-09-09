# 2D Subpixel Proof of Concept

This is a dependency-free Zig experiment for the rendering idea discussed above.
It renders 48 BMP frames, each with four copies of a sword moving at
fractional-pixel speed and swinging between 30 and 60 degrees. Its sine and
cosine values come from a Q12 integer lookup table; rendering and animation do
not use floating-point math.

- **Left panel:** conventional pixel-art movement. The transform is rounded to
  whole pixels and each output pixel is evaluated once.
- **Middle panel:** the sword retains 8-bit fixed-point positions (256 positions
  per output pixel). Edge pixels are resolved with an 8 x 8 micro-sample grid
  and composited with continuous coverage — the smooth, anti-aliased baseline.
- **Right panel:** the identical micro-sample coverage is converted with a 4 x
  4 Bayer threshold pattern. It selects either the existing scene color or the
  sword color, so it does not introduce blended edge colors.
- **Far-right panel (recommended):** coverage maps to six artist-selected,
  opaque blue palette entries. It eliminates the Bayer checker pattern while
  retaining a controlled pixel-art ramp instead of unconstrained blending.

In every panel the orange hilt is a five-by-five whole-pixel sprite, drawn
after the blade. It is an intentionally simple per-object resolution budget:
keep a character component crisp while applying the fractional edge treatment
only to the weapon.

The point is deliberately modest: a display pixel remains one pixel. The
second and third panels only change the *rule for resolving subpixel geometry
into that pixel*. This separates the visual question — smooth blends versus a
limited-palette dither — from the fixed-point animation itself.

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
left panel will stay still for several frames and jump; the remaining panels
track the fractional transform through changing edge coverage. Compare the
middle panel's anti-aliasing, the right panel's binary dither, and the
far-right panel's palette-indexed edge ramp.

## Next experiments

1. Apply the selective adaptive treatment to particles and effects.
2. Let artists author a per-sprite coverage ramp, rather than sharing the
   sword's default six blue shades.
3. Replace the procedural sword with an animated polygon or sprite mask.
4. Move the per-pixel coverage pass into a GPU shader after the output style is
   proven useful.

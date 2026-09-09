const std = @import("std");

// Every screen pixel is represented internally by 256 fixed-point units.
// Keeping coordinates integral makes the animation deterministic while still
// allowing 256 positions between neighbouring output pixels.
const subpixel_bits = 8;
const units_per_pixel: i32 = 1 << subpixel_bits;

const panel_width: usize = 256;
const height: usize = 144;
const width: usize = panel_width * 4 + 3;
const frame_count: usize = 48;
const edge_samples: i32 = 8;
const trig_scale: i32 = 4096;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const background = Color{ .r = 18, .g = 22, .b = 35 };
const sword_color = Color{ .r = 106, .g = 215, .b = 255 };
const hilt_color = Color{ .r = 255, .g = 184, .b = 77 };
const divider_color = Color{ .r = 68, .g = 78, .b = 105 };

const ResolveMode = enum {
    alpha_coverage,
    ordered_dither,
    palette_ramp,
};

// Bayer ranks distribute partial coverage into a stable 4 x 4 pattern.
// This lets an edge use only its existing two palette colors.
const bayer_4x4 = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

// An artist-controlled blue ramp. These are ordinary opaque palette entries,
// not colors blended by the renderer at runtime.
const sword_coverage_ramp = [_]Color{
    .{ .r = 31, .g = 70, .b = 98 },
    .{ .r = 43, .g = 101, .b = 138 },
    .{ .r = 57, .g = 132, .b = 176 },
    .{ .r = 72, .g = 162, .b = 207 },
    .{ .r = 89, .g = 190, .b = 233 },
    sword_color,
};

const BladeTransform = struct {
    x: i32,
    y: i32,
    cos: i32,
    sin: i32,
};

// Q12 fixed-point cos/sin samples for a 30-to-60-degree swing, in two-degree
// steps. No float values participate in rendering or animation.
const swing_vectors = [_]struct { cos: i32, sin: i32 }{
    .{ .cos = 3547, .sin = 2048 }, // 30 degrees
    .{ .cos = 3474, .sin = 2171 },
    .{ .cos = 3395, .sin = 2291 },
    .{ .cos = 3313, .sin = 2408 },
    .{ .cos = 3227, .sin = 2522 },
    .{ .cos = 3138, .sin = 2634 },
    .{ .cos = 3044, .sin = 2740 },
    .{ .cos = 2947, .sin = 2846 },
    .{ .cos = 2896, .sin = 2896 }, // 45 degrees
    .{ .cos = 2846, .sin = 2947 },
    .{ .cos = 2740, .sin = 3044 },
    .{ .cos = 2634, .sin = 3138 },
    .{ .cos = 2522, .sin = 3227 },
    .{ .cos = 2408, .sin = 3313 },
    .{ .cos = 2291, .sin = 3395 },
    .{ .cos = 2171, .sin = 3474 },
    .{ .cos = 2048, .sin = 3547 }, // 60 degrees
};

const Framebuffer = struct {
    pixels: [width * height]Color = undefined,

    fn clear(self: *Framebuffer, color: Color) void {
        @memset(&self.pixels, color);
    }

    fn set(self: *Framebuffer, x: usize, y: usize, color: Color) void {
        self.pixels[y * width + x] = color;
    }
};

fn abs(value: i32) i32 {
    return if (value < 0) -value else value;
}

fn mix(background_color: Color, foreground_color: Color, coverage: i32) Color {
    // coverage is 0..edge_samples^2. This is the deliberately smooth,
    // palette-expanding comparison mode.
    const total = edge_samples * edge_samples;
    const r = @divTrunc(@as(i32, background_color.r) * (total - coverage) + @as(i32, foreground_color.r) * coverage, total);
    const g = @divTrunc(@as(i32, background_color.g) * (total - coverage) + @as(i32, foreground_color.g) * coverage, total);
    const b = @divTrunc(@as(i32, background_color.b) * (total - coverage) + @as(i32, foreground_color.b) * coverage, total);
    return .{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b) };
}

fn isInsideSword(sample_x: i32, sample_y: i32, blade: BladeTransform) bool {
    // Rotate the point into blade-local coordinates using Q12 lookup values.
    const dx = sample_x - blade.x;
    const dy = sample_y - blade.y;
    const along = @divTrunc(dx * blade.cos + dy * blade.sin, trig_scale);
    const across = @divTrunc(-dx * blade.sin + dy * blade.cos, trig_scale);
    const half_length = 37 * units_per_pixel;
    const half_width = 3 * units_per_pixel;
    return abs(along) <= half_length and abs(across) <= half_width;
}

fn bladeForFrame(frame: usize) BladeTransform {
    const swing_period = swing_vectors.len * 2 - 2;
    const phase = frame % swing_period;
    const vector_index = if (phase < swing_vectors.len) phase else swing_period - phase;
    const vector = swing_vectors[vector_index];

    // 0.34765625 screen pixels per frame: deliberately not an integer rate.
    const travel_x = @as(i32, @intCast(frame)) * 89;
    const travel_y = @as(i32, @intCast(frame)) * 31;
    return .{
        .x = 70 * units_per_pixel + @mod(travel_x, 110 * units_per_pixel),
        .y = 54 * units_per_pixel + @mod(travel_y, 38 * units_per_pixel),
        .cos = vector.cos,
        .sin = vector.sin,
    };
}

fn drawGrid(framebuffer: *Framebuffer, panel_x: usize) void {
    // A faint 16-pixel grid makes the one-pixel jumps in the left panel easy
    // to spot without affecting the sampling algorithm.
    for (0..height) |y| {
        for (0..panel_width) |local_x| {
            if (local_x % 16 == 0 or y % 16 == 0) {
                const old = framebuffer.pixels[y * width + panel_x + local_x];
                framebuffer.set(panel_x + local_x, y, .{
                    .r = old.r +| 7,
                    .g = old.g +| 7,
                    .b = old.b +| 7,
                });
            }
        }
    }
}

fn drawClassicSword(framebuffer: *Framebuffer, panel_x: usize, blade: BladeTransform) void {
    // The conventional result: snap the object's transform, then test one
    // sample at each pixel centre.
    const snapped_blade = BladeTransform{
        .x = @divTrunc(blade.x + units_per_pixel / 2, units_per_pixel) * units_per_pixel,
        .y = @divTrunc(blade.y + units_per_pixel / 2, units_per_pixel) * units_per_pixel,
        .cos = blade.cos,
        .sin = blade.sin,
    };

    for (0..height) |y| {
        for (0..panel_width) |local_x| {
            const center_x: i32 = @as(i32, @intCast(local_x)) * units_per_pixel + units_per_pixel / 2;
            const center_y: i32 = @as(i32, @intCast(y)) * units_per_pixel + units_per_pixel / 2;
            if (isInsideSword(center_x, center_y, snapped_blade)) {
                framebuffer.set(panel_x + local_x, y, sword_color);
            }
        }
    }
}

fn drawCrispHilt(framebuffer: *Framebuffer, panel_x: usize, blade: BladeTransform) void {
    // Per-object resolution budget: the hilt remains a deliberately crisp
    // sprite, even while its attached blade resolves fractional movement.
    const center_x = @divTrunc(blade.x + units_per_pixel / 2, units_per_pixel);
    const center_y = @divTrunc(blade.y + units_per_pixel / 2, units_per_pixel);
    const sprite = [5][5]bool{
        .{ false, false, true, false, false },
        .{ true, true, true, true, true },
        .{ false, false, true, false, false },
        .{ false, false, true, false, false },
        .{ false, true, true, true, false },
    };

    for (sprite, 0..) |row, sprite_y| {
        for (row, 0..) |filled, sprite_x| {
            if (!filled) continue;
            const x = center_x - 2 + @as(i32, @intCast(sprite_x));
            const y = center_y - 2 + @as(i32, @intCast(sprite_y));
            framebuffer.set(panel_x + @as(usize, @intCast(x)), @intCast(y), hilt_color);
        }
    }
}

fn drawAdaptiveSword(framebuffer: *Framebuffer, panel_x: usize, blade: BladeTransform, mode: ResolveMode) void {
    // Most pixels do no micro-sampling. Only pixels that have mixed corner
    // coverage, or lie in the sword's small conservative bounding box, are
    // refined with an 8 x 8 sample grid. The bounding-box rule matters for a
    // thin diagonal: it can cross a pixel without containing any corner.
    const sample_step = @divExact(units_per_pixel, edge_samples);
    const sample_center = @divExact(sample_step, 2);
    const bounding_radius = 21 * units_per_pixel;
    for (0..height) |y| {
        for (0..panel_width) |local_x| {
            const x0: i32 = @as(i32, @intCast(local_x)) * units_per_pixel;
            const y0: i32 = @as(i32, @intCast(y)) * units_per_pixel;
            const x1 = x0 + units_per_pixel - 1;
            const y1 = y0 + units_per_pixel - 1;

            if (x1 < blade.x - bounding_radius or x0 > blade.x + bounding_radius or y1 < blade.y - bounding_radius or y0 > blade.y + bounding_radius) continue;

            const corners = [_]bool{
                isInsideSword(x0, y0, blade),
                isInsideSword(x1, y0, blade),
                isInsideSword(x0, y1, blade),
                isInsideSword(x1, y1, blade),
            };
            const inside_count: usize = @as(usize, @intFromBool(corners[0])) + @as(usize, @intFromBool(corners[1])) + @as(usize, @intFromBool(corners[2])) + @as(usize, @intFromBool(corners[3]));

            if (inside_count == 4) {
                framebuffer.set(panel_x + local_x, y, sword_color);
                continue;
            }

            var covered: i32 = 0;
            for (0..edge_samples) |sample_y| {
                for (0..edge_samples) |sample_x| {
                    const sx = x0 + @as(i32, @intCast(sample_x)) * sample_step + sample_center;
                    const sy = y0 + @as(i32, @intCast(sample_y)) * sample_step + sample_center;
                    if (isInsideSword(sx, sy, blade)) covered += 1;
                }
            }
            switch (mode) {
                .alpha_coverage => {
                    // Composite over what is already in the framebuffer.
                    // Using a constant background here would erase the grid
                    // for zero-coverage pixels, producing an opaque square.
                    const destination = framebuffer.pixels[y * width + panel_x + local_x];
                    framebuffer.set(panel_x + local_x, y, mix(destination, sword_color, covered));
                },
                .ordered_dither => {
                    // Convert continuous coverage back into a binary palette
                    // choice. The 4 x 4 threshold pattern is screen-locked,
                    // so it reads as intentional pixel texture rather than a
                    // newly invented anti-aliased edge color.
                    const rank = bayer_4x4[y % 4][local_x % 4];
                    const threshold: i32 = @as(i32, rank) * 4 + 2;
                    if (covered > threshold) framebuffer.set(panel_x + local_x, y, sword_color);
                },
                .palette_ramp => {
                    // Quantize coverage into a small, hand-selected color
                    // ramp. Unlike spatial dithering, every edge pixel has a
                    // stable color: no checker pattern and no invented RGB.
                    if (covered == 0) continue;
                    const total = edge_samples * edge_samples;
                    const index: usize = @intCast(@divTrunc(covered * @as(i32, sword_coverage_ramp.len) - 1, total));
                    framebuffer.set(panel_x + local_x, y, sword_coverage_ramp[index]);
                },
            }
        }
    }
}

fn writeU16LE(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeU32LE(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn writeBmp(io: std.Io, framebuffer: *const Framebuffer, frame: usize) !void {
    const row_bytes = width * 3;
    const row_stride = (row_bytes + 3) & ~@as(usize, 3);
    const pixel_bytes = row_stride * height;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "out/comparison_{d:0>3}.bmp", .{frame});
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    // A 24-bit BMP makes the output directly viewable on Windows without a
    // third-party library. Rows are BGR and stored bottom-up.
    var header: [54]u8 = [_]u8{0} ** 54;
    header[0] = 'B';
    header[1] = 'M';
    writeU32LE(&header, 2, @intCast(header.len + pixel_bytes));
    writeU32LE(&header, 10, header.len);
    writeU32LE(&header, 14, 40);
    writeU32LE(&header, 18, @intCast(width));
    writeU32LE(&header, 22, @intCast(height));
    writeU16LE(&header, 26, 1);
    writeU16LE(&header, 28, 24);
    writeU32LE(&header, 34, @intCast(pixel_bytes));
    writeU32LE(&header, 38, 2_835); // 72 DPI
    writeU32LE(&header, 42, 2_835);
    try file.writeStreamingAll(io, &header);

    var bytes: [pixel_bytes]u8 = [_]u8{0} ** pixel_bytes;
    for (0..height) |row| {
        const source_y = height - 1 - row;
        for (0..width) |x| {
            const pixel = framebuffer.pixels[source_y * width + x];
            const offset = row * row_stride + x * 3;
            bytes[offset] = pixel.b;
            bytes[offset + 1] = pixel.g;
            bytes[offset + 2] = pixel.r;
        }
    }
    try file.writeStreamingAll(io, &bytes);
}

pub fn main(init: std.process.Init) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, "out");

    var framebuffer: Framebuffer = undefined;
    for (0..frame_count) |frame| {
        framebuffer.clear(background);
        drawGrid(&framebuffer, 0);
        drawGrid(&framebuffer, panel_width + 1);
        drawGrid(&framebuffer, panel_width * 2 + 2);
        drawGrid(&framebuffer, panel_width * 3 + 3);

        const blade = bladeForFrame(frame);

        drawClassicSword(&framebuffer, 0, blade);
        for (0..height) |y| framebuffer.set(panel_width, y, divider_color);
        drawAdaptiveSword(&framebuffer, panel_width + 1, blade, .alpha_coverage);
        for (0..height) |y| framebuffer.set(panel_width * 2 + 1, y, divider_color);
        drawAdaptiveSword(&framebuffer, panel_width * 2 + 2, blade, .ordered_dither);
        for (0..height) |y| framebuffer.set(panel_width * 3 + 2, y, divider_color);
        drawAdaptiveSword(&framebuffer, panel_width * 3 + 3, blade, .palette_ramp);
        const panel_origins = [_]usize{ 0, panel_width + 1, panel_width * 2 + 2, panel_width * 3 + 3 };
        for (panel_origins) |panel_x| drawCrispHilt(&framebuffer, panel_x, blade);
        try writeBmp(init.io, &framebuffer, frame);
    }

    std.debug.print("Wrote {d} comparison frames to out/.\n", .{frame_count});
    std.debug.print("Panels: snapped, alpha coverage, ordered dither, and palette-ramp coverage.\n", .{});
}

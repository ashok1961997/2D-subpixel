const std = @import("std");

// Every screen pixel is represented internally by 256 fixed-point units.
// Keeping coordinates integral makes the animation deterministic while still
// allowing 256 positions between neighbouring output pixels.
const subpixel_bits = 8;
const units_per_pixel: i32 = 1 << subpixel_bits;

const panel_width: usize = 256;
const height: usize = 144;
const width: usize = panel_width * 2 + 1;
const frame_count: usize = 48;
const edge_samples: i32 = 8;

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

const background = Color{ .r = 18, .g = 22, .b = 35 };
const sword_color = Color{ .r = 106, .g = 215, .b = 255 };
const divider_color = Color{ .r = 68, .g = 78, .b = 105 };

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

fn clamp(value: i32, low: i32, high: i32) i32 {
    return @max(low, @min(value, high));
}

fn mix(background_color: Color, foreground_color: Color, coverage: i32) Color {
    // coverage is 0..edge_samples^2. This is intentionally palette-free so
    // the coverage transition is obvious. A pixel-art renderer could instead
    // use a hand-authored palette or a dither pattern at this point.
    const total = edge_samples * edge_samples;
    const r = @divTrunc(@as(i32, background_color.r) * (total - coverage) + @as(i32, foreground_color.r) * coverage, total);
    const g = @divTrunc(@as(i32, background_color.g) * (total - coverage) + @as(i32, foreground_color.g) * coverage, total);
    const b = @divTrunc(@as(i32, background_color.b) * (total - coverage) + @as(i32, foreground_color.b) * coverage, total);
    return .{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b) };
}

// A 45-degree sword is a rotated rectangle. The u/v transform avoids floats:
// u = dx + dy and v = dx - dy. Its long diagonal axis is u.
fn isInsideSword(sample_x: i32, sample_y: i32, sword_x: i32, sword_y: i32) bool {
    const dx = sample_x - sword_x;
    const dy = sample_y - sword_y;
    const along = dx + dy;
    const across = dx - dy;
    const half_length = 37 * units_per_pixel;
    const half_width = 3 * units_per_pixel;
    return abs(along) <= half_length and abs(across) <= half_width;
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

fn drawClassicSword(framebuffer: *Framebuffer, panel_x: usize, sword_x: i32, sword_y: i32) void {
    // The conventional result: snap the object's transform, then test one
    // sample at each pixel centre.
    const snapped_x = @divTrunc(sword_x + units_per_pixel / 2, units_per_pixel) * units_per_pixel;
    const snapped_y = @divTrunc(sword_y + units_per_pixel / 2, units_per_pixel) * units_per_pixel;

    for (0..height) |y| {
        for (0..panel_width) |local_x| {
            const center_x: i32 = @as(i32, @intCast(local_x)) * units_per_pixel + units_per_pixel / 2;
            const center_y: i32 = @as(i32, @intCast(y)) * units_per_pixel + units_per_pixel / 2;
            if (isInsideSword(center_x, center_y, snapped_x, snapped_y)) {
                framebuffer.set(panel_x + local_x, y, sword_color);
            }
        }
    }
}

fn drawAdaptiveSword(framebuffer: *Framebuffer, panel_x: usize, sword_x: i32, sword_y: i32) void {
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

            if (x1 < sword_x - bounding_radius or x0 > sword_x + bounding_radius or y1 < sword_y - bounding_radius or y0 > sword_y + bounding_radius) continue;

            const corners = [_]bool{
                isInsideSword(x0, y0, sword_x, sword_y),
                isInsideSword(x1, y0, sword_x, sword_y),
                isInsideSword(x0, y1, sword_x, sword_y),
                isInsideSword(x1, y1, sword_x, sword_y),
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
                    if (isInsideSword(sx, sy, sword_x, sword_y)) covered += 1;
                }
            }
            // Composite over what is already in the framebuffer. Using the
            // constant background here would erase the grid for zero-coverage
            // candidate pixels, producing a visible opaque bounding square.
            const destination = framebuffer.pixels[y * width + panel_x + local_x];
            framebuffer.set(panel_x + local_x, y, mix(destination, sword_color, covered));
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

        // 0.34765625 screen pixels per frame: this is deliberately not an
        // integer motion rate, so snapping causes visible temporal jumps.
        const travel_x = @as(i32, @intCast(frame)) * 89;
        const travel_y = @as(i32, @intCast(frame)) * 31;
        const sword_x = 70 * units_per_pixel + @mod(travel_x, 110 * units_per_pixel);
        const sword_y = 54 * units_per_pixel + @mod(travel_y, 38 * units_per_pixel);

        drawClassicSword(&framebuffer, 0, sword_x, sword_y);
        for (0..height) |y| framebuffer.set(panel_width, y, divider_color);
        drawAdaptiveSword(&framebuffer, panel_width + 1, sword_x, sword_y);
        try writeBmp(init.io, &framebuffer, frame);
    }

    std.debug.print("Wrote {d} comparison frames to out/.\n", .{frame_count});
    std.debug.print("Left: snapped one-sample rendering. Right: fixed-point adaptive coverage.\n", .{});
}

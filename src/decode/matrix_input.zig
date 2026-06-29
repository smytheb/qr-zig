//! Parse a rendered QR symbol back into a `Matrix` for decoding. Handles the
//! formats this tool emits: `ascii` ('#' = dark), `pbm` (P1 bitmap), and `png`
//! (8-bit grayscale, non-interlaced). `parse` auto-detects from the input bytes.
//!
//! In every case the quiet zone is auto-detected: a QR symbol's three finder
//! patterns sit in the top-left, top-right, and bottom-left corners, so the
//! bounding box of all dark cells is exactly the symbol — parsing is independent
//! of the quiet-zone width. For raster formats the integer module size (scale)
//! is recovered from the 7-module dark run of the top-left finder, then each
//! module is sampled at its center pixel.

const std = @import("std");
const tables = @import("../qr/tables.zig");
const matrix = @import("../qr/matrix.zig");
const flate = std.compress.flate;

const Matrix = matrix.Matrix;

pub const ParseError = error{
    /// The input is not a recognizable QR symbol in a supported format/size.
    BadInput,
} || std.mem.Allocator.Error;

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

/// The version for a valid QR side length (21..177 in steps of 4), or null.
fn versionForSize(size: usize) ?u8 {
    if (size < 21 or size > 177 or (size - 17) % 4 != 0) return null;
    return @intCast((size - 17) / 4);
}

/// Auto-detect the format from the leading bytes and parse accordingly.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError!Matrix {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], &png_signature)) return fromPng(allocator, data);
    if (std.mem.startsWith(u8, data, "P1")) return fromPbm(allocator, data);
    return fromAscii(allocator, data);
}

/// Parse an ASCII-rendered QR symbol ('#' = dark) into a loadable `Matrix`.
pub fn fromAscii(allocator: std.mem.Allocator, text: []const u8) ParseError!Matrix {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var width: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, line);
        width = @max(width, line.len);
    }
    const height = lines.items.len;
    if (width == 0 or height == 0) return error.BadInput;

    // Lay the characters out as a 1-module-per-cell pixel grid and reuse the
    // raster path: '#' is dark, and the finder run resolves the scale to 1.
    const grid = try allocator.alloc(bool, width * height);
    defer allocator.free(grid);
    @memset(grid, false);
    for (lines.items, 0..) |line, y| {
        for (line, 0..) |c, x| grid[y * width + x] = (c == '#');
    }
    return fromPixels(allocator, grid, width, height);
}

/// Build a `Matrix` from a `width x height` grid of dark/light pixels (a
/// rendered raster). Auto-detects the symbol bounds, the integer module scale,
/// and samples each module's center pixel.
fn fromPixels(allocator: std.mem.Allocator, pixels: []const bool, w: usize, h: usize) ParseError!Matrix {
    var min_x: usize = std.math.maxInt(usize);
    var min_y: usize = std.math.maxInt(usize);
    var max_x: usize = 0;
    var max_y: usize = 0;
    var any = false;
    for (0..h) |y| {
        for (0..w) |x| {
            if (!pixels[y * w + x]) continue;
            any = true;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
    }
    if (!any) return error.BadInput;

    const bw = max_x - min_x + 1;
    if (bw != max_y - min_y + 1) return error.BadInput;

    // The top-left finder's top border is 7 dark modules wide, so the leading
    // dark run along the symbol's top edge is 7 * scale.
    var run: usize = 0;
    while (min_x + run <= max_x and pixels[min_y * w + min_x + run]) run += 1;
    if (run == 0 or run % 7 != 0) return error.BadInput;
    const scale = run / 7;
    if (bw % scale != 0) return error.BadInput;
    const size = bw / scale;
    const version = versionForSize(size) orelse return error.BadInput;

    var m = try matrix.buildFunctionMatrix(allocator, version);
    errdefer m.deinit();
    const half = scale / 2;
    var my: usize = 0;
    while (my < size) : (my += 1) {
        const py = min_y + my * scale + half;
        var mx: usize = 0;
        while (mx < size) : (mx += 1) {
            const px = min_x + mx * scale + half;
            m.setModule(mx, my, pixels[py * w + px]);
        }
    }
    return m;
}

/// Read a base-10 unsigned integer from `data` at `*i`, skipping leading
/// non-digit bytes (whitespace).
fn readUint(data: []const u8, i: *usize) ParseError!usize {
    while (i.* < data.len and !std.ascii.isDigit(data[i.*])) i.* += 1;
    var v: usize = 0;
    var got = false;
    while (i.* < data.len and std.ascii.isDigit(data[i.*])) : (i.* += 1) {
        v = v * 10 + (data[i.*] - '0');
        got = true;
    }
    if (!got) return error.BadInput;
    return v;
}

/// Parse a Netpbm P1 (ASCII bitmap, 1 = dark) rendering.
pub fn fromPbm(allocator: std.mem.Allocator, data: []const u8) ParseError!Matrix {
    if (!std.mem.startsWith(u8, data, "P1")) return error.BadInput;
    var i: usize = 2;
    const w = try readUint(data, &i);
    const h = try readUint(data, &i);
    if (w == 0 or h == 0 or w > 1 << 13 or h > 1 << 13) return error.BadInput;

    const pixels = try allocator.alloc(bool, w * h);
    defer allocator.free(pixels);
    var count: usize = 0;
    while (i < data.len and count < w * h) : (i += 1) {
        switch (data[i]) {
            '1' => {
                pixels[count] = true;
                count += 1;
            },
            '0' => {
                pixels[count] = false;
                count += 1;
            },
            else => {},
        }
    }
    if (count != w * h) return error.BadInput;
    return fromPixels(allocator, pixels, w, h);
}

fn absDiff(x: i32, a: u8) i32 {
    const d = x - @as(i32, a);
    return if (d < 0) -d else d;
}

/// PNG Paeth predictor.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = absDiff(p, a);
    const pb = absDiff(p, b);
    const pc = absDiff(p, c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Parse an 8-bit grayscale, non-interlaced PNG (the format this tool emits, and
/// other simple grayscale PNGs). RGB/palette/interlaced inputs are rejected.
pub fn fromPng(allocator: std.mem.Allocator, data: []const u8) ParseError!Matrix {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_signature)) return error.BadInput;

    var off: usize = 8;
    var width: usize = 0;
    var height: usize = 0;
    var have_ihdr = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    while (off + 8 <= data.len) {
        const length = std.mem.readInt(u32, data[off..][0..4], .big);
        const ctype = data[off + 4 .. off + 8];
        const dstart = off + 8;
        if (dstart + length + 4 > data.len) return error.BadInput; // data + CRC
        const cdata = data[dstart .. dstart + length];
        off = dstart + length + 4;
        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (length < 13) return error.BadInput;
            width = std.mem.readInt(u32, cdata[0..4], .big);
            height = std.mem.readInt(u32, cdata[4..8], .big);
            // bit depth 8, color type 0 (grayscale), interlace 0.
            if (cdata[8] != 8 or cdata[9] != 0 or cdata[12] != 0) return error.BadInput;
            have_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(allocator, cdata);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
    }
    if (!have_ihdr or width == 0 or height == 0 or width > 1 << 13 or height > 1 << 13) {
        return error.BadInput;
    }

    // Inflate the zlib stream into raw filtered scanlines.
    var in: std.Io.Reader = .fixed(idat.items);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var dec: flate.Decompress = .init(&in, .zlib, window);
    var raw_buf: std.Io.Writer.Allocating = .init(allocator);
    defer raw_buf.deinit();
    _ = dec.reader.streamRemaining(&raw_buf.writer) catch return error.BadInput;
    const raw = raw_buf.written();

    const stride = 1 + width; // filter byte + width grayscale samples (bpp = 1)
    if (raw.len < stride * height) return error.BadInput;

    const pixels = try allocator.alloc(bool, width * height);
    defer allocator.free(pixels);
    const prev = try allocator.alloc(u8, width);
    defer allocator.free(prev);
    @memset(prev, 0);
    const cur = try allocator.alloc(u8, width);
    defer allocator.free(cur);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const filter = raw[y * stride];
        const src = raw[y * stride + 1 ..][0..width];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const a: u8 = if (x >= 1) cur[x - 1] else 0; // left
            const b: u8 = prev[x]; // up
            const c: u8 = if (x >= 1) prev[x - 1] else 0; // up-left
            const val: u8 = switch (filter) {
                0 => src[x],
                1 => src[x] +% a,
                2 => src[x] +% b,
                3 => src[x] +% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => src[x] +% paeth(a, b, c),
                else => return error.BadInput,
            };
            cur[x] = val;
            pixels[y * width + x] = val < 128; // dark if closer to black
        }
        @memcpy(prev, cur);
    }
    return fromPixels(allocator, pixels, width, height);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const generate = @import("../qr/generate.zig");
const decode = @import("decode.zig");
const ascii = @import("../render/ascii.zig");
const pbm = @import("../render/pbm.zig");
const png = @import("../render/png.zig");

fn renderAscii(a: std.mem.Allocator, m: *const Matrix, quiet: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try ascii.render(&buf.writer, m, .{ .quiet = quiet, .dark = '#', .light = ' ' });
    return a.dupe(u8, buf.written());
}

fn renderPbm(a: std.mem.Allocator, m: *const Matrix, quiet: usize, scale: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try pbm.render(&buf.writer, m, .{ .quiet = quiet, .scale = scale });
    return a.dupe(u8, buf.written());
}

fn renderPng(a: std.mem.Allocator, m: *const Matrix, quiet: usize, scale: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try png.render(a, &buf.writer, m, .{ .quiet = quiet, .scale = scale });
    return a.dupe(u8, buf.written());
}

/// Parse `art` and decode it, asserting the text matches `expect`.
fn expectDecodes(a: std.mem.Allocator, art: []const u8, expect: []const u8) !void {
    var m = try parse(a, art);
    defer m.deinit();
    const dec = try decode.decodeMatrix(a, &m);
    defer a.free(dec.text);
    try std.testing.expectEqualStrings(expect, dec.text);
}

test "parse auto-detects ascii / pbm / png and round-trips" {
    const a = std.testing.allocator;
    const text = "Decode me 123";
    var g = try generate.generate(a, text, .m, .none);
    defer g.deinit();

    const art = try renderAscii(a, &g.matrix, 4);
    defer a.free(art);
    try expectDecodes(a, art, text);

    const p = try renderPbm(a, &g.matrix, 2, 3);
    defer a.free(p);
    try expectDecodes(a, p, text);

    const n = try renderPng(a, &g.matrix, 4, 8);
    defer a.free(n);
    try expectDecodes(a, n, text);
}

test "pbm/png decode across scales, quiet zones, and a higher version" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "HELLO WORLD", "https://ziglang.org/learn", "x" ** 120 };
    for (cases) |text| {
        var g = try generate.generate(a, text, .q, .none);
        defer g.deinit();

        for ([_]usize{ 1, 4 }) |scale| {
            const p = try renderPbm(a, &g.matrix, 3, scale);
            defer a.free(p);
            try expectDecodes(a, p, text);

            const n = try renderPng(a, &g.matrix, 0, scale * 2);
            defer a.free(n);
            try expectDecodes(a, n, text);
        }
    }
}

test "parse rejects malformed input" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadInput, parse(a, "       \n   \n")); // no dark ascii
    try std.testing.expectError(error.BadInput, parse(a, "##\n##")); // 2x2, not a valid size
    try std.testing.expectError(error.BadInput, parse(a, "P1\n3 3\n101010101\n")); // 3x3 raster
    try std.testing.expectError(error.BadInput, fromPng(a, &png_signature)); // signature only
}

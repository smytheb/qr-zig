//! PNG renderer: an 8-bit grayscale (color type 0) image, one byte per pixel
//! (0x00 dark, 0xFF light), each module expanded to `scale x scale` pixels with
//! a `quiet`-module border. Scanlines use filter type 0 (None) and are deflated
//! with the standard library's zlib compressor; the QR matrix is so repetitive
//! that even at high `scale` the IDAT stays small.
//!
//! Unlike the other renderers this one needs an allocator: it builds the raw
//! image and captures the compressed stream before the IDAT length/CRC are
//! known.

const std = @import("std");
const flate = std.compress.flate;
const Matrix = @import("../qr/matrix.zig").Matrix;

pub const Options = struct {
    quiet: usize = 4,
    scale: usize = 8,
};

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

fn moduleDark(m: *const Matrix, quiet: usize, mx: usize, my: usize) bool {
    const in_quiet = mx < quiet or my < quiet or mx >= quiet + m.size or my >= quiet + m.size;
    if (in_quiet) return false;
    return m.get(mx - quiet, my - quiet);
}

fn writeU32(w: *std.Io.Writer, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try w.writeAll(&b);
}

/// Emit one PNG chunk: length, type, data, then a CRC-32 over type+data.
fn writeChunk(w: *std.Io.Writer, typ: *const [4]u8, data: []const u8) !void {
    try writeU32(w, @intCast(data.len));
    try w.writeAll(typ);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    try writeU32(w, crc.final());
}

pub fn render(allocator: std.mem.Allocator, writer: *std.Io.Writer, m: *const Matrix, opts: Options) !void {
    const modules = m.size + 2 * opts.quiet;
    const n = modules * opts.scale; // image is n x n pixels

    // Raw image: n scanlines, each a filter byte (0 = None) + n grayscale bytes.
    const stride = 1 + n;
    const raw = try allocator.alloc(u8, stride * n);
    defer allocator.free(raw);
    var ry: usize = 0;
    while (ry < n) : (ry += 1) {
        const row = raw[ry * stride ..][0..stride];
        row[0] = 0; // filter type: None
        const my = ry / opts.scale;
        var rx: usize = 0;
        while (rx < n) : (rx += 1) {
            const mx = rx / opts.scale;
            row[1 + rx] = if (moduleDark(m, opts.quiet, mx, my)) 0x00 else 0xFF;
        }
    }

    // Deflate the scanlines into a zlib stream (header + Adler-32 handled by std).
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var idat: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer idat.deinit();
    var comp = try flate.Compress.init(&idat.writer, window, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();

    // IHDR: width, height, bit depth 8, color type 0 (grayscale), all methods 0.
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(n), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(n), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 0; // color type: grayscale
    ihdr[10] = 0; // compression method
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace method

    try writer.writeAll(&signature);
    try writeChunk(writer, "IHDR", &ihdr);
    try writeChunk(writer, "IDAT", idat.written());
    try writeChunk(writer, "IEND", "");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const qr = @import("../qr/root.zig");

test "PNG has a valid signature, IHDR dimensions, and IEND" {
    const a = std.testing.allocator;
    var g = try qr.generateWithMask(a, "Hi!", .m, 0, .auto);
    defer g.deinit();

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try render(a, &out.writer, &g.matrix, .{ .quiet = 4, .scale = 2 });
    const bytes = out.written();

    // Signature.
    try std.testing.expect(std.mem.startsWith(u8, bytes, &signature));
    // IHDR appears right after the 8-byte signature + 4-byte length.
    try std.testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    // Width/height = (size + 2*quiet) * scale = (21 + 8) * 2 = 58.
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    try std.testing.expectEqual(@as(u32, 58), w);
    try std.testing.expectEqual(@as(u32, 58), h);
    // Stream ends with the (empty) IEND chunk and its CRC.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82 }, bytes[bytes.len - 8 ..]);
}

test "PNG round-trips to the source matrix at scale 1 / quiet 0" {
    const a = std.testing.allocator;
    var g = try qr.generateWithMask(a, "Hi!", .m, 0, .auto);
    defer g.deinit();

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try render(a, &out.writer, &g.matrix, .{ .quiet = 0, .scale = 1 });
    const bytes = out.written();

    // Pull the IDAT payload back out and inflate it, then compare pixels to the
    // matrix: a dark module must be a 0x00 sample, a light module 0xFF.
    const size = g.matrix.size;
    const idat = bytes[33 + 8 ..][0..std.mem.readInt(u32, bytes[33..37], .big)];
    var in: std.Io.Reader = .fixed(idat);
    var dbuf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &dbuf);
    var pixels: std.Io.Writer.Allocating = .init(a);
    defer pixels.deinit();
    _ = try dec.reader.streamRemaining(&pixels.writer);
    const raw = pixels.written();

    const stride = 1 + size;
    var y: usize = 0;
    while (y < size) : (y += 1) {
        try std.testing.expectEqual(@as(u8, 0), raw[y * stride]); // filter None
        var x: usize = 0;
        while (x < size) : (x += 1) {
            const sample = raw[y * stride + 1 + x];
            try std.testing.expectEqual(g.matrix.get(x, y), sample == 0x00);
        }
    }
}

//! Data encoding: turn input text into the sequence of data codewords
//! (pre error-correction) for a chosen version and EC level.
//!
//! The input is split into an optimal sequence of mixed-mode segments (see
//! `segment.zig`), each numeric, alphanumeric, or byte. Pipeline: for every
//! segment write mode indicator -> character count -> mode data; then a
//! terminator -> pad to a byte boundary -> pad bytes (0xEC / 0x11).

const std = @import("std");
const tables = @import("tables.zig");
const segment = @import("segment.zig");
const BitWriter = @import("bitstream.zig").BitWriter;
const BitReader = @import("bitstream.zig").BitReader;

pub const EcLevel = tables.EcLevel;
pub const Mode = segment.Mode;
pub const Segment = segment.Segment;

pub const Error = error{
    /// Input does not fit any supported version at the requested EC level.
    DataTooLong,
} || std.mem.Allocator.Error;

/// Extended Channel Interpretation policy. `auto` declares ECI 26 (UTF-8) only
/// when the input contains non-ASCII bytes; `none` never declares one; `value`
/// forces a specific ECI assignment number.
pub const Eci = union(enum) {
    none,
    auto,
    value: u32,
};

/// UTF-8 ECI assignment number.
pub const eci_utf8: u32 = 26;

fn hasNonAscii(text: []const u8) bool {
    for (text) |c| {
        if (c > 127) return true;
    }
    return false;
}

/// Resolve an ECI policy against the input to a concrete assignment number
/// (or null for "no ECI segment").
pub fn resolveEci(text: []const u8, eci: Eci) ?u32 {
    return switch (eci) {
        .none => null,
        .auto => if (hasNonAscii(text)) eci_utf8 else null,
        .value => |n| n,
    };
}

/// Bits occupied by an ECI header (mode indicator + assignment number).
fn eciHeaderBits(n: u32) usize {
    return 4 + @as(usize, if (n <= 127) 8 else if (n <= 16383) 16 else 24);
}

/// Write the ECI header: mode indicator 0111 + variable-length assignment.
fn writeEci(bw: *BitWriter, a: std.mem.Allocator, n: u32) !void {
    try bw.writeBits(a, 0b0111, 4);
    if (n <= 127) {
        try bw.writeBits(a, n, 8);
    } else if (n <= 16383) {
        try bw.writeBits(a, 0x8000 | n, 16);
    } else {
        try bw.writeBits(a, 0xC00000 | n, 24);
    }
}

pub const Encoded = struct {
    version: u8,
    level: EcLevel,
    eci: ?u32,
    /// Owned by the caller's allocator; length == data-codeword capacity.
    data_codewords: []u8,
};

/// Smallest supported version whose data capacity holds `text` at `level`,
/// using the optimal segmentation for each version tier.
pub fn chooseVersion(allocator: std.mem.Allocator, text: []const u8, level: EcLevel, eci: Eci) Error!u8 {
    const eci_bits: usize = if (resolveEci(text, eci)) |n| eciHeaderBits(n) else 0;
    // Segmentation only depends on the version tier (char-count widths), so the
    // bit cost is computed once per tier rather than per version.
    const bits_by_tier = [3]usize{
        try segment.optimalBits(allocator, text, 1),
        try segment.optimalBits(allocator, text, 10),
        try segment.optimalBits(allocator, text, 27),
    };
    var v: u8 = tables.min_version;
    while (v <= tables.max_version) : (v += 1) {
        const bits = eci_bits + bits_by_tier[if (v <= 9) 0 else if (v <= 26) @as(usize, 1) else 2];
        if (bits <= tables.blockStructure(v, level).dataCodewords() * 8) return v;
    }
    return error.DataTooLong;
}

// -- per-segment data writers ----------------------------------------------

fn writeNumeric(bw: *BitWriter, a: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i + 3 <= text.len) : (i += 3) {
        const v: u32 = @as(u32, text[i] - '0') * 100 +
            @as(u32, text[i + 1] - '0') * 10 + (text[i + 2] - '0');
        try bw.writeBits(a, v, 10);
    }
    switch (text.len - i) {
        2 => try bw.writeBits(a, @as(u32, text[i] - '0') * 10 + (text[i + 1] - '0'), 7),
        1 => try bw.writeBits(a, text[i] - '0', 4),
        else => {},
    }
}

fn writeAlphanumeric(bw: *BitWriter, a: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i + 2 <= text.len) : (i += 2) {
        const v = @as(u32, segment.alphanumericValue(text[i]).?) * 45 +
            segment.alphanumericValue(text[i + 1]).?;
        try bw.writeBits(a, v, 11);
    }
    if (text.len - i == 1) try bw.writeBits(a, segment.alphanumericValue(text[i]).?, 6);
}

fn writeByteData(bw: *BitWriter, a: std.mem.Allocator, text: []const u8) !void {
    for (text) |b| try bw.writeBits(a, b, 8);
}

/// Encode `text` for an explicit version/level into data codewords.
/// Caller owns the returned slice (freed with `allocator`).
pub fn encodeVersion(
    allocator: std.mem.Allocator,
    text: []const u8,
    version: u8,
    level: EcLevel,
    eci: Eci,
) Error![]u8 {
    const total_data = tables.blockStructure(version, level).dataCodewords();
    const segments = try segment.optimalSegments(allocator, text, version);
    defer allocator.free(segments);

    const eci_n = resolveEci(text, eci);
    var needed: usize = if (eci_n) |n| eciHeaderBits(n) else 0;
    for (segments) |s| {
        needed += 4 + @as(usize, segment.charCountBits(s.mode, version)) + segment.dataBits(s.mode, s.len);
    }
    if (needed > total_data * 8) return error.DataTooLong;

    var bw: BitWriter = .empty;
    defer bw.deinit(allocator);

    if (eci_n) |n| try writeEci(&bw, allocator, n);
    for (segments) |s| {
        try bw.writeBits(allocator, s.mode.indicator(), 4);
        try bw.writeBits(allocator, @intCast(s.len), segment.charCountBits(s.mode, version));
        const chunk = text[s.start .. s.start + s.len];
        switch (s.mode) {
            .numeric => try writeNumeric(&bw, allocator, chunk),
            .alphanumeric => try writeAlphanumeric(&bw, allocator, chunk),
            .byte => try writeByteData(&bw, allocator, chunk),
        }
    }

    // Terminator: up to four 0 bits, but never past capacity.
    const capacity_bits = total_data * 8;
    const terminator: u6 = @intCast(@min(@as(usize, 4), capacity_bits - bw.nbits));
    try bw.writeBits(allocator, 0, terminator);
    try bw.padToByte(allocator);

    // Pad bytes alternate 0xEC, 0x11 until capacity is reached.
    var use_ec = true;
    while (bw.byteLen() < total_data) : (use_ec = !use_ec) {
        try bw.writeBits(allocator, if (use_ec) 0xEC else 0x11, 8);
    }

    const out = try bw.data.toOwnedSlice(allocator);
    std.debug.assert(out.len == total_data);
    return out;
}

/// Encode `text`, auto-selecting the smallest fitting version.
pub fn encode(allocator: std.mem.Allocator, text: []const u8, level: EcLevel, eci: Eci) Error!Encoded {
    const version = try chooseVersion(allocator, text, level, eci);
    const data = try encodeVersion(allocator, text, version, level, eci);
    return .{ .version = version, .level = level, .eci = resolveEci(text, eci), .data_codewords = data };
}

// ===========================================================================
// Decoding (data codewords -> text)
// ===========================================================================
//
// The inverse of `encodeVersion`: read the ECI header (if any) and each segment
// (mode + count + payload) back into the original bytes, stopping at the
// terminator or when the stream runs into padding.

pub const DecodeError = error{
    /// The bitstream does not parse as valid QR segments.
    MalformedData,
} || std.mem.Allocator.Error;

pub const Decoded = struct {
    /// Owned by the caller's allocator.
    text: []u8,
    eci: ?u32,
};

fn modeFromIndicator(ind: u32) ?Mode {
    return switch (ind) {
        0b0001 => .numeric,
        0b0010 => .alphanumeric,
        0b0100 => .byte,
        else => null, // terminator / ECI / unsupported handled by the caller
    };
}

/// Read a variable-length ECI assignment number (8, 16, or 24 bits) whose
/// leading bits encode its width: 0xxxxxxx, 10xxxxxx…, 110xxxxx….
fn readEciNumber(r: *BitReader) DecodeError!u32 {
    if (r.remaining() < 8) return error.MalformedData;
    const b0 = r.readBits(8);
    if (b0 & 0x80 == 0) return b0; // 7-bit value
    if (b0 & 0xC0 == 0x80) {
        if (r.remaining() < 8) return error.MalformedData;
        return ((b0 & 0x3F) << 8) | r.readBits(8); // 14-bit value
    }
    if (b0 & 0xE0 == 0xC0) {
        if (r.remaining() < 16) return error.MalformedData;
        return ((b0 & 0x1F) << 16) | r.readBits(16); // 21-bit value
    }
    return error.MalformedData;
}

fn decodeSegmentData(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    r: *BitReader,
    mode: Mode,
    count: u32,
) DecodeError!void {
    switch (mode) {
        .numeric => {
            var left = count;
            while (left >= 3) : (left -= 3) {
                if (r.remaining() < 10) return error.MalformedData;
                const v = r.readBits(10);
                if (v > 999) return error.MalformedData;
                try out.append(allocator, '0' + @as(u8, @intCast(v / 100)));
                try out.append(allocator, '0' + @as(u8, @intCast((v / 10) % 10)));
                try out.append(allocator, '0' + @as(u8, @intCast(v % 10)));
            }
            if (left == 2) {
                if (r.remaining() < 7) return error.MalformedData;
                const v = r.readBits(7);
                if (v > 99) return error.MalformedData;
                try out.append(allocator, '0' + @as(u8, @intCast(v / 10)));
                try out.append(allocator, '0' + @as(u8, @intCast(v % 10)));
            } else if (left == 1) {
                if (r.remaining() < 4) return error.MalformedData;
                const v = r.readBits(4);
                if (v > 9) return error.MalformedData;
                try out.append(allocator, '0' + @as(u8, @intCast(v)));
            }
        },
        .alphanumeric => {
            var left = count;
            while (left >= 2) : (left -= 2) {
                if (r.remaining() < 11) return error.MalformedData;
                const v = r.readBits(11);
                const hi = segment.alphanumericChar(v / 45) orelse return error.MalformedData;
                const lo = segment.alphanumericChar(v % 45) orelse return error.MalformedData;
                try out.append(allocator, hi);
                try out.append(allocator, lo);
            }
            if (left == 1) {
                if (r.remaining() < 6) return error.MalformedData;
                const c = segment.alphanumericChar(r.readBits(6)) orelse return error.MalformedData;
                try out.append(allocator, c);
            }
        },
        .byte => {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (r.remaining() < 8) return error.MalformedData;
                try out.append(allocator, @intCast(r.readBits(8)));
            }
        },
    }
}

/// Decode data codewords back into the original byte string (inverse of
/// `encodeVersion`). `version` selects the character-count widths. Caller owns
/// the returned `text`.
pub fn decodeSegments(allocator: std.mem.Allocator, data: []const u8, version: u8) DecodeError!Decoded {
    var r = BitReader.init(data);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var eci: ?u32 = null;

    while (r.remaining() >= 4) {
        const ind = r.readBits(4);
        if (ind == 0) break; // terminator
        if (ind == 0b0111) { // ECI header
            eci = try readEciNumber(&r);
            continue;
        }
        const mode = modeFromIndicator(ind) orelse break; // padding / unsupported
        const cc_bits = segment.charCountBits(mode, version);
        if (r.remaining() < cc_bits) return error.MalformedData;
        const count = r.readBits(cc_bits);
        try decodeSegmentData(allocator, &out, &r, mode, count);
    }

    return .{ .text = try out.toOwnedSlice(allocator), .eci = eci };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "numeric data bits match the spec example 01234567" {
    const a = std.testing.allocator;
    var bw: BitWriter = .empty;
    defer bw.deinit(a);
    try writeNumeric(&bw, a, "01234567");
    // 0000001100 0101011001 1000011  (27 bits)
    try std.testing.expectEqual(@as(usize, 27), bw.nbits);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x15, 0x98, 0x60 }, bw.data.items);
}

test "alphanumeric data bits match the spec example AC-42" {
    const a = std.testing.allocator;
    var bw: BitWriter = .empty;
    defer bw.deinit(a);
    try writeAlphanumeric(&bw, a, "AC-42");
    // 00111001110 11100111001 000010  (28 bits)
    try std.testing.expectEqual(@as(usize, 28), bw.nbits);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x39, 0xDC, 0xE4, 0x20 }, bw.data.items);
}

test "compact modes select smaller versions than byte mode" {
    const a = std.testing.allocator;
    const digits = "012345678901234567890123456789"; // 30 digits
    try std.testing.expectEqual(@as(u8, 1), try chooseVersion(a, digits, .m, .none));
}

test "encode produces capacity-sized codewords" {
    const a = std.testing.allocator;
    const result = try encode(a, "Hello, World!", .m, .auto);
    defer a.free(result.data_codewords);
    try std.testing.expectEqual(@as(u8, 1), result.version);
    try std.testing.expectEqual(@as(usize, 16), result.data_codewords.len);
    try std.testing.expectEqual(@as(?u32, null), result.eci); // ASCII -> no ECI
}

test "rejects input that exceeds version 40 capacity" {
    const a = std.testing.allocator;
    const huge = "x" ** 5000; // byte mode, beyond v40
    try std.testing.expectError(error.DataTooLong, chooseVersion(a, huge, .l, .none));
}

test "ECI assignment-number encoding boundaries" {
    const a = std.testing.allocator;
    const Case = struct { n: u32, bits: usize, bytes: []const u8 };
    const cases = [_]Case{
        .{ .n = 26, .bits = 12, .bytes = &.{ 0x71, 0xA0 } }, // 0111 00011010 (UTF-8)
        .{ .n = 127, .bits = 12, .bytes = &.{ 0x77, 0xF0 } }, // 0111 01111111
        .{ .n = 128, .bits = 20, .bytes = &.{ 0x78, 0x08, 0x00 } }, // 0111 10000000 10000000
        .{ .n = 16384, .bits = 28, .bytes = &.{ 0x7C, 0x04, 0x00, 0x00 } }, // 0111 110... 21-bit
    };
    for (cases) |c| {
        var bw: BitWriter = .empty;
        defer bw.deinit(a);
        try writeEci(&bw, a, c.n);
        try std.testing.expectEqual(c.bits, bw.nbits);
        try std.testing.expectEqualSlices(u8, c.bytes, bw.data.items);
    }
}

test "auto ECI declares UTF-8 only for non-ASCII; golden codewords" {
    const a = std.testing.allocator;
    // "é" == UTF-8 bytes C3 A9. With auto ECI -> ECI(26) + byte segment.
    const result = try encode(a, "é", .m, .auto);
    defer a.free(result.data_codewords);
    try std.testing.expectEqual(@as(?u32, 26), result.eci);
    try std.testing.expectEqual(@as(u8, 1), result.version);
    // ECI 0111 00011010 | byte 0100 | count 00000010 | C3 | A9 | term/pad
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x71, 0xA4, 0x02, 0xC3, 0xA9, 0x00,
        0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
        0xEC, 0x11, 0xEC, 0x11,
    }, result.data_codewords);

    // The same input with ECI disabled drops the 12-bit header.
    const no_eci = try encode(a, "é", .m, .none);
    defer a.free(no_eci.data_codewords);
    try std.testing.expectEqual(@as(?u32, null), no_eci.eci);
    try std.testing.expectEqual(@as(u8, 0x40), no_eci.data_codewords[0]); // byte mode indicator
}

test "decodeSegments round-trips encoded text across modes" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "12345", // numeric, partial trailing group (2)
        "0123456789012345", // numeric, exact + partial
        "8", // numeric, single trailing digit
        "HELLO WORLD", // alphanumeric, trailing single
        "AC-42", // alphanumeric, full charset
        "Hello, World!", // byte
        "ABC123def456GHI", // mixed: alnum / numeric / byte
        "the quick brown fox jumps over 13 lazy dogs", // long mixed
    };
    for (cases) |text| {
        const enc = try encode(a, text, .m, .none);
        defer a.free(enc.data_codewords);
        const dec = try decodeSegments(a, enc.data_codewords, enc.version);
        defer a.free(dec.text);
        try std.testing.expectEqualStrings(text, dec.text);
        try std.testing.expectEqual(@as(?u32, null), dec.eci);
    }
}

test "decodeSegments recovers the ECI declaration and non-ASCII bytes" {
    const a = std.testing.allocator;
    const enc = try encode(a, "café", .m, .auto); // ECI 26 + byte segment
    defer a.free(enc.data_codewords);
    const dec = try decodeSegments(a, enc.data_codewords, enc.version);
    defer a.free(dec.text);
    try std.testing.expectEqualStrings("café", dec.text);
    try std.testing.expectEqual(@as(?u32, 26), dec.eci);
}

test "decodeSegments round-trips a higher-version payload" {
    const a = std.testing.allocator;
    const text = "x" ** 400 ++ " 12345 ABCDEF"; // multi-block, mixed tail
    const enc = try encode(a, text, .q, .none);
    defer a.free(enc.data_codewords);
    const dec = try decodeSegments(a, enc.data_codewords, enc.version);
    defer a.free(dec.text);
    try std.testing.expectEqualStrings(text, dec.text);
}

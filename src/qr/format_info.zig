//! Format information (EC level + mask, BCH(15,5)) and version information
//! (version, BCH(18,6)) — drawn into the reserved areas after masking.

const std = @import("std");
const Matrix = @import("matrix.zig").Matrix;
const tables = @import("tables.zig");

/// 2-bit EC-level field used in the format string (distinct from the enum's
/// own ordering): M=00, L=01, H=10, Q=11.
fn ecLevelBits(level: tables.EcLevel) u32 {
    return switch (level) {
        .l => 0b01,
        .m => 0b00,
        .q => 0b11,
        .h => 0b10,
    };
}

/// The 15-bit format string for (level, mask): 5 data bits + BCH(15,5) EC,
/// XOR-masked with 0x5412.
pub fn formatBits(level: tables.EcLevel, mask: u3) u15 {
    const data: u32 = (ecLevelBits(level) << 3) | mask;
    var rem: u32 = data;
    var i: usize = 0;
    while (i < 10) : (i += 1) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    const bits = ((data << 10) | rem) ^ 0x5412;
    return @intCast(bits & 0x7FFF);
}

/// The 18-bit version string for `version` (>= 7): 6 data bits + BCH(18,6).
pub fn versionBits(version: u8) u18 {
    var rem: u32 = version;
    var i: usize = 0;
    while (i < 12) : (i += 1) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    const bits = (@as(u32, version) << 12) | rem;
    return @intCast(bits & 0x3FFFF);
}

fn bit(value: u32, i: usize) bool {
    return (value >> @intCast(i)) & 1 == 1;
}

/// Draw both copies of the format information for (level, mask).
pub fn drawFormat(m: *Matrix, level: tables.EcLevel, mask: u3) void {
    const bits: u32 = formatBits(level, mask);
    const size = m.size;

    // First copy: around the top-left finder.
    var i: usize = 0;
    while (i <= 5) : (i += 1) m.setReserved(8, i, bit(bits, i));
    m.setReserved(8, 7, bit(bits, 6));
    m.setReserved(8, 8, bit(bits, 7));
    m.setReserved(7, 8, bit(bits, 8));
    i = 9;
    while (i < 15) : (i += 1) m.setReserved(14 - i, 8, bit(bits, i));

    // Second copy: split across the top-right and bottom-left finders.
    i = 0;
    while (i < 8) : (i += 1) m.setReserved(size - 1 - i, 8, bit(bits, i));
    i = 8;
    while (i < 15) : (i += 1) m.setReserved(8, size - 15 + i, bit(bits, i));

    // The always-dark module.
    m.setReserved(8, size - 8, true);
}

/// Draw both copies of the version information (no-op for versions < 7).
pub fn drawVersion(m: *Matrix) void {
    if (m.version < 7) return;
    const bits: u32 = versionBits(m.version);
    const size = m.size;
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const b = bit(bits, i);
        const col = size - 11 + (i % 3);
        const row = i / 3;
        m.setReserved(col, row, b); // top-right block
        m.setReserved(row, col, b); // bottom-left block (transposed)
    }
}

// ---------------------------------------------------------------------------
// Reading (decode side)
// ---------------------------------------------------------------------------

pub const FormatInfo = struct { level: tables.EcLevel, mask: u3 };

pub const ReadError = error{BadFormat};

const all_levels = [_]tables.EcLevel{ .l, .m, .q, .h };

fn setBit(bits: *u15, i: usize) void {
    bits.* |= @as(u15, 1) << @intCast(i);
}

/// Read one of the two 15-bit format copies off the matrix. `which` 0 is the
/// copy around the top-left finder; 1 is the copy split across the top-right and
/// bottom-left finders. The bit layout mirrors `drawFormat` exactly.
fn readFormatCopy(m: *const Matrix, which: u1) u15 {
    var bits: u15 = 0;
    const size = m.size;
    if (which == 0) {
        var i: usize = 0;
        while (i <= 5) : (i += 1) if (m.get(8, i)) setBit(&bits, i);
        if (m.get(8, 7)) setBit(&bits, 6);
        if (m.get(8, 8)) setBit(&bits, 7);
        if (m.get(7, 8)) setBit(&bits, 8);
        i = 9;
        while (i < 15) : (i += 1) if (m.get(14 - i, 8)) setBit(&bits, i);
    } else {
        var i: usize = 0;
        while (i < 8) : (i += 1) if (m.get(size - 1 - i, 8)) setBit(&bits, i);
        i = 8;
        while (i < 15) : (i += 1) if (m.get(8, size - 15 + i)) setBit(&bits, i);
    }
    return bits;
}

const Match = struct { info: FormatInfo, dist: u32 };

/// The nearest BCH(15,5) format codeword to `raw` (read off the matrix, still
/// XOR-masked with 0x5412) and its Hamming distance.
fn nearestFormat(raw: u15) Match {
    var best = Match{ .info = .{ .level = .m, .mask = 0 }, .dist = 16 };
    for (all_levels) |level| {
        var mask: u3 = 0;
        while (true) : (mask += 1) {
            const dist: u32 = @popCount(formatBits(level, mask) ^ raw);
            if (dist < best.dist) best = .{ .info = .{ .level = level, .mask = mask }, .dist = dist };
            if (mask == 7) break;
        }
    }
    return best;
}

/// Decode a 15-bit format string to its (level, mask). The 32 valid strings have
/// minimum distance 7, so up to 3 bit errors are correctable; returns null when
/// no codeword is within that radius.
pub fn decodeFormatBits(raw: u15) ?FormatInfo {
    const m = nearestFormat(raw);
    return if (m.dist <= 3) m.info else null;
}

/// Recover the (level, mask) from a matrix's format information. Both copies are
/// decoded and the closer match wins, so a badly damaged copy can't override a
/// clean one. Works on a still-masked matrix (format modules are drawn after
/// data masking and are not themselves data-masked).
pub fn readFormat(m: *const Matrix) ReadError!FormatInfo {
    const b0 = nearestFormat(readFormatCopy(m, 0));
    const b1 = nearestFormat(readFormatCopy(m, 1));
    const best = if (b0.dist <= b1.dist) b0 else b1;
    return if (best.dist <= 3) best.info else error.BadFormat;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "format bits match known spec values" {
    // EC=M, mask=0 -> data 00000 -> 0 ^ 0x5412 == 0x5412.
    try std.testing.expectEqual(@as(u15, 0x5412), formatBits(.m, 0));
    // EC=L, mask=0 -> known string 111011111000100b == 0x77C4.
    try std.testing.expectEqual(@as(u15, 0x77C4), formatBits(.l, 0));
}

test "version bits known value for version 7" {
    // Version 7 information string is 000111110010010100 == 0x07C94.
    try std.testing.expectEqual(@as(u18, 0x07C94), versionBits(7));
}

test "decodeFormatBits round-trips every (level, mask) clean" {
    for (all_levels) |level| {
        var mask: u3 = 0;
        while (true) : (mask += 1) {
            const info = decodeFormatBits(formatBits(level, mask)).?;
            try std.testing.expectEqual(level, info.level);
            try std.testing.expectEqual(mask, info.mask);
            if (mask == 7) break;
        }
    }
}

test "decodeFormatBits corrects up to 3 bit errors" {
    for (all_levels) |level| {
        var mask: u3 = 0;
        while (true) : (mask += 1) {
            const clean = formatBits(level, mask);
            var nerr: usize = 0;
            while (nerr <= 3) : (nerr += 1) {
                var corrupt = clean;
                for (0..nerr) |b| corrupt ^= @as(u15, 1) << @intCast(b * 4); // bits 0,4,8
                const info = decodeFormatBits(corrupt).?;
                try std.testing.expectEqual(level, info.level);
                try std.testing.expectEqual(mask, info.mask);
            }
            if (mask == 7) break;
        }
    }
}

test "decodeFormatBits rejects strings far from every codeword" {
    // A BCH(15,5) word outside the distance-3 ball of all 32 codewords must
    // decode to null. Such words exist (the code isn't perfect); find one.
    var w: u16 = 0;
    const bad: u15 = while (w < 0x8000) : (w += 1) {
        if (nearestFormat(@intCast(w)).dist >= 4) break @intCast(w);
    } else unreachable;
    try std.testing.expectEqual(@as(?FormatInfo, null), decodeFormatBits(bad));
}

test "readFormat recovers (level, mask) from a drawn matrix" {
    const a = std.testing.allocator;
    for (all_levels) |level| {
        var mask: u3 = 0;
        while (true) : (mask += 1) {
            var m = try Matrix.init(a, 1);
            defer m.deinit();
            drawFormat(&m, level, mask);
            const info = try readFormat(&m);
            try std.testing.expectEqual(level, info.level);
            try std.testing.expectEqual(mask, info.mask);
            if (mask == 7) break;
        }
    }
}

test "readFormat corrects a damaged copy and falls back to the clean one" {
    const a = std.testing.allocator;

    // Both copies damaged within their 3-bit radius, so the winning copy must be
    // BCH-corrected through the matrix path (neither is clean).
    {
        var m = try Matrix.init(a, 1);
        defer m.deinit();
        drawFormat(&m, .q, 5);
        m.flip(8, 0); // 3 errors in copy 0 (top-left)
        m.flip(8, 1);
        m.flip(8, 2);
        m.flip(20, 8); // 3 errors in copy 1 (split)
        m.flip(19, 8);
        m.flip(18, 8);
        const info = try readFormat(&m);
        try std.testing.expectEqual(tables.EcLevel.q, info.level);
        try std.testing.expectEqual(@as(u3, 5), info.mask);
    }

    // The top-left copy wrecked beyond its radius; the split copy still wins.
    {
        var m = try Matrix.init(a, 1);
        defer m.deinit();
        drawFormat(&m, .h, 2);
        var i: usize = 0;
        while (i <= 5) : (i += 1) m.flip(8, i); // 6 errors in copy 0
        const info = try readFormat(&m);
        try std.testing.expectEqual(tables.EcLevel.h, info.level);
        try std.testing.expectEqual(@as(u3, 2), info.mask);
    }
}

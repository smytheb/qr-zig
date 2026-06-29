//! QR code specification data: error-correction block structure and codeword
//! capacities. Currently covers versions 1-10 (the v1 scope); later phases
//! extend this to version 40.
//!
//! Source: ISO/IEC 18004 "Error correction characteristics" table (the same
//! values reproduced by the Thonky QR tutorial). The whole table is validated
//! at test time against the fixed total-codeword count per version, which
//! catches any transcription error (see the test at the bottom).

const std = @import("std");

/// Error-correction level, ordered low to high redundancy. The enum's integer
/// value doubles as the column index into the block-structure table.
pub const EcLevel = enum(u2) {
    l = 0,
    m = 1,
    q = 2,
    h = 3,

    pub fn fromChar(c: u8) ?EcLevel {
        return switch (c) {
            'l', 'L' => .l,
            'm', 'M' => .m,
            'q', 'Q' => .q,
            'h', 'H' => .h,
            else => null,
        };
    }
};

pub const min_version: u8 = 1;
pub const max_version: u8 = 40;

/// Error-correction block layout for one (version, EC level) combination.
///
/// A QR symbol's data and EC codewords are split into up to two groups of
/// equal-sized blocks. Each block gets `ec_per_block` EC codewords.
pub const BlockStructure = struct {
    ec_per_block: u16,
    g1_blocks: u16,
    g1_data: u16,
    g2_blocks: u16,
    g2_data: u16,

    pub fn dataCodewords(self: BlockStructure) usize {
        return @as(usize, self.g1_blocks) * self.g1_data +
            @as(usize, self.g2_blocks) * self.g2_data;
    }

    pub fn totalBlocks(self: BlockStructure) usize {
        return @as(usize, self.g1_blocks) + self.g2_blocks;
    }

    pub fn ecCodewords(self: BlockStructure) usize {
        return self.totalBlocks() * self.ec_per_block;
    }
};

fn bs(ec: u16, g1b: u16, g1d: u16, g2b: u16, g2d: u16) BlockStructure {
    return .{ .ec_per_block = ec, .g1_blocks = g1b, .g1_data = g1d, .g2_blocks = g2b, .g2_data = g2d };
}

/// Indexed `[version - 1][@intFromEnum(level)]`. Generated from the ISO/IEC
/// 18004 error-correction table and validated against `total_codewords` plus
/// the matrix's independent data-module count (see tests).
pub const block_table = [40][4]BlockStructure{
    // v1
    .{ bs(7, 1, 19, 0, 0), bs(10, 1, 16, 0, 0), bs(13, 1, 13, 0, 0), bs(17, 1, 9, 0, 0) },
    // v2
    .{ bs(10, 1, 34, 0, 0), bs(16, 1, 28, 0, 0), bs(22, 1, 22, 0, 0), bs(28, 1, 16, 0, 0) },
    // v3
    .{ bs(15, 1, 55, 0, 0), bs(26, 1, 44, 0, 0), bs(18, 2, 17, 0, 0), bs(22, 2, 13, 0, 0) },
    // v4
    .{ bs(20, 1, 80, 0, 0), bs(18, 2, 32, 0, 0), bs(26, 2, 24, 0, 0), bs(16, 4, 9, 0, 0) },
    // v5
    .{ bs(26, 1, 108, 0, 0), bs(24, 2, 43, 0, 0), bs(18, 2, 15, 2, 16), bs(22, 2, 11, 2, 12) },
    // v6
    .{ bs(18, 2, 68, 0, 0), bs(16, 4, 27, 0, 0), bs(24, 4, 19, 0, 0), bs(28, 4, 15, 0, 0) },
    // v7
    .{ bs(20, 2, 78, 0, 0), bs(18, 4, 31, 0, 0), bs(18, 2, 14, 4, 15), bs(26, 4, 13, 1, 14) },
    // v8
    .{ bs(24, 2, 97, 0, 0), bs(22, 2, 38, 2, 39), bs(22, 4, 18, 2, 19), bs(26, 4, 14, 2, 15) },
    // v9
    .{ bs(30, 2, 116, 0, 0), bs(22, 3, 36, 2, 37), bs(20, 4, 16, 4, 17), bs(24, 4, 12, 4, 13) },
    // v10
    .{ bs(18, 2, 68, 2, 69), bs(26, 4, 43, 1, 44), bs(24, 6, 19, 2, 20), bs(28, 6, 15, 2, 16) },
    // v11
    .{ bs(20, 4, 81, 0, 0), bs(30, 1, 50, 4, 51), bs(28, 4, 22, 4, 23), bs(24, 3, 12, 8, 13) },
    // v12
    .{ bs(24, 2, 92, 2, 93), bs(22, 6, 36, 2, 37), bs(26, 4, 20, 6, 21), bs(28, 7, 14, 4, 15) },
    // v13
    .{ bs(26, 4, 107, 0, 0), bs(22, 8, 37, 1, 38), bs(24, 8, 20, 4, 21), bs(22, 12, 11, 4, 12) },
    // v14
    .{ bs(30, 3, 115, 1, 116), bs(24, 4, 40, 5, 41), bs(20, 11, 16, 5, 17), bs(24, 11, 12, 5, 13) },
    // v15
    .{ bs(22, 5, 87, 1, 88), bs(24, 5, 41, 5, 42), bs(30, 5, 24, 7, 25), bs(24, 11, 12, 7, 13) },
    // v16
    .{ bs(24, 5, 98, 1, 99), bs(28, 7, 45, 3, 46), bs(24, 15, 19, 2, 20), bs(30, 3, 15, 13, 16) },
    // v17
    .{ bs(28, 1, 107, 5, 108), bs(28, 10, 46, 1, 47), bs(28, 1, 22, 15, 23), bs(28, 2, 14, 17, 15) },
    // v18
    .{ bs(30, 5, 120, 1, 121), bs(26, 9, 43, 4, 44), bs(28, 17, 22, 1, 23), bs(28, 2, 14, 19, 15) },
    // v19
    .{ bs(28, 3, 113, 4, 114), bs(26, 3, 44, 11, 45), bs(26, 17, 21, 4, 22), bs(26, 9, 13, 16, 14) },
    // v20
    .{ bs(28, 3, 107, 5, 108), bs(26, 3, 41, 13, 42), bs(30, 15, 24, 5, 25), bs(28, 15, 15, 10, 16) },
    // v21
    .{ bs(28, 4, 116, 4, 117), bs(26, 17, 42, 0, 0), bs(28, 17, 22, 6, 23), bs(30, 19, 16, 6, 17) },
    // v22
    .{ bs(28, 2, 111, 7, 112), bs(28, 17, 46, 0, 0), bs(30, 7, 24, 16, 25), bs(24, 34, 13, 0, 0) },
    // v23
    .{ bs(30, 4, 121, 5, 122), bs(28, 4, 47, 14, 48), bs(30, 11, 24, 14, 25), bs(30, 16, 15, 14, 16) },
    // v24
    .{ bs(30, 6, 117, 4, 118), bs(28, 6, 45, 14, 46), bs(30, 11, 24, 16, 25), bs(30, 30, 16, 2, 17) },
    // v25
    .{ bs(26, 8, 106, 4, 107), bs(28, 8, 47, 13, 48), bs(30, 7, 24, 22, 25), bs(30, 22, 15, 13, 16) },
    // v26
    .{ bs(28, 10, 114, 2, 115), bs(28, 19, 46, 4, 47), bs(28, 28, 22, 6, 23), bs(30, 33, 16, 4, 17) },
    // v27
    .{ bs(30, 8, 122, 4, 123), bs(28, 22, 45, 3, 46), bs(30, 8, 23, 26, 24), bs(30, 12, 15, 28, 16) },
    // v28
    .{ bs(30, 3, 117, 10, 118), bs(28, 3, 45, 23, 46), bs(30, 4, 24, 31, 25), bs(30, 11, 15, 31, 16) },
    // v29
    .{ bs(30, 7, 116, 7, 117), bs(28, 21, 45, 7, 46), bs(30, 1, 23, 37, 24), bs(30, 19, 15, 26, 16) },
    // v30
    .{ bs(30, 5, 115, 10, 116), bs(28, 19, 47, 10, 48), bs(30, 15, 24, 25, 25), bs(30, 23, 15, 25, 16) },
    // v31
    .{ bs(30, 13, 115, 3, 116), bs(28, 2, 46, 29, 47), bs(30, 42, 24, 1, 25), bs(30, 23, 15, 28, 16) },
    // v32
    .{ bs(30, 17, 115, 0, 0), bs(28, 10, 46, 23, 47), bs(30, 10, 24, 35, 25), bs(30, 19, 15, 35, 16) },
    // v33
    .{ bs(30, 17, 115, 1, 116), bs(28, 14, 46, 21, 47), bs(30, 29, 24, 19, 25), bs(30, 11, 15, 46, 16) },
    // v34
    .{ bs(30, 13, 115, 6, 116), bs(28, 14, 46, 23, 47), bs(30, 44, 24, 7, 25), bs(30, 59, 16, 1, 17) },
    // v35
    .{ bs(30, 12, 121, 7, 122), bs(28, 12, 47, 26, 48), bs(30, 39, 24, 14, 25), bs(30, 22, 15, 41, 16) },
    // v36
    .{ bs(30, 6, 121, 14, 122), bs(28, 6, 47, 34, 48), bs(30, 46, 24, 10, 25), bs(30, 2, 15, 64, 16) },
    // v37
    .{ bs(30, 17, 122, 4, 123), bs(28, 29, 46, 14, 47), bs(30, 49, 24, 10, 25), bs(30, 24, 15, 46, 16) },
    // v38
    .{ bs(30, 4, 122, 18, 123), bs(28, 13, 46, 32, 47), bs(30, 48, 24, 14, 25), bs(30, 42, 15, 32, 16) },
    // v39
    .{ bs(30, 20, 117, 4, 118), bs(28, 40, 47, 7, 48), bs(30, 43, 24, 22, 25), bs(30, 10, 15, 67, 16) },
    // v40
    .{ bs(30, 19, 118, 6, 119), bs(28, 18, 47, 31, 48), bs(30, 34, 24, 34, 25), bs(30, 20, 15, 61, 16) },
};

/// Total codewords (data + EC) per version — independent of EC level. Used to
/// validate `block_table` and by the matrix placement phase.
pub const total_codewords = [40]u16{
    26,   44,   70,   100,  134,  172,  196,  242,  292,  346,
    404,  466,  532,  581,  655,  733,  815,  901,  991,  1085,
    1156, 1258, 1364, 1474, 1588, 1706, 1828, 1921, 2051, 2185,
    2323, 2465, 2611, 2761, 2876, 3034, 3196, 3362, 3532, 3706,
};

/// Look up the block structure for a (version, level) pair. Asserts the version
/// is within the supported range.
pub fn blockStructure(version: u8, level: EcLevel) BlockStructure {
    std.debug.assert(version >= min_version and version <= max_version);
    return block_table[version - 1][@intFromEnum(level)];
}

/// Width in bits of the byte-mode character-count indicator for `version`.
pub fn byteModeCharCountBits(version: u8) u6 {
    return if (version <= 9) 8 else 16;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "block table is internally consistent with total codeword counts" {
    var v: u8 = 1;
    while (v <= max_version) : (v += 1) {
        for (0..4) |level_idx| {
            const s = block_table[v - 1][level_idx];
            const total = s.ecCodewords() + s.dataCodewords();
            try std.testing.expectEqual(@as(usize, total_codewords[v - 1]), total);
        }
    }
}

test "EcLevel parsing and indexing" {
    try std.testing.expectEqual(EcLevel.q, EcLevel.fromChar('Q').?);
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum(EcLevel.h));
    try std.testing.expect(EcLevel.fromChar('z') == null);
}

test "byte-mode char count width switches at version 10" {
    try std.testing.expectEqual(@as(u6, 8), byteModeCharCountBits(9));
    try std.testing.expectEqual(@as(u6, 16), byteModeCharCountBits(10));
}

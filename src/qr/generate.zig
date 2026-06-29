//! High-level orchestration: text -> data codewords -> interleaved codewords ->
//! module matrix -> mask selection -> format/version information.

const std = @import("std");
const encode = @import("encode.zig");
const reed_solomon = @import("reed_solomon.zig");
const matrix = @import("matrix.zig");
const mask = @import("mask.zig");
const format_info = @import("format_info.zig");
const tables = @import("tables.zig");

pub const EcLevel = tables.EcLevel;
pub const Matrix = matrix.Matrix;
pub const Error = encode.Error;
pub const Eci = encode.Eci;

pub const Generated = struct {
    matrix: Matrix,
    version: u8,
    level: EcLevel,
    mask: u3,

    pub fn deinit(self: *Generated) void {
        self.matrix.deinit();
    }
};

/// Encode `text` at `level` and build the unmasked QR matrix (no format/version
/// information). Mainly useful for testing the placement phase in isolation.
pub fn generateUnmasked(
    allocator: std.mem.Allocator,
    text: []const u8,
    level: EcLevel,
    eci: Eci,
) !Matrix {
    const encoded = try encode.encode(allocator, text, level, eci);
    defer allocator.free(encoded.data_codewords);

    const interleaved = try reed_solomon.interleaveCodewords(
        allocator,
        encoded.data_codewords,
        encoded.version,
        level,
    );
    defer allocator.free(interleaved);

    return matrix.build(allocator, encoded.version, interleaved);
}

/// Full pipeline with an explicit mask (skips penalty-based selection). Used for
/// deterministic testing against reference encoders.
pub fn generateWithMask(
    allocator: std.mem.Allocator,
    text: []const u8,
    level: EcLevel,
    chosen_mask: u3,
    eci: Eci,
) !Generated {
    var m = try generateUnmasked(allocator, text, level, eci);
    errdefer m.deinit();
    mask.applyMask(&m, chosen_mask);
    format_info.drawFormat(&m, level, chosen_mask);
    format_info.drawVersion(&m);
    return .{ .matrix = m, .version = m.version, .level = level, .mask = chosen_mask };
}

/// Full pipeline: encode, build, choose the lowest-penalty mask, and draw
/// format/version information. Caller owns the result (call `deinit`).
pub fn generate(
    allocator: std.mem.Allocator,
    text: []const u8,
    level: EcLevel,
    eci: Eci,
) !Generated {
    var m = try generateUnmasked(allocator, text, level, eci);
    errdefer m.deinit();

    var best_mask: u3 = 0;
    var best_penalty: usize = std.math.maxInt(usize);
    var p: u3 = 0;
    while (true) : (p += 1) {
        mask.applyMask(&m, p);
        format_info.drawFormat(&m, level, p);
        const score = mask.penalty(&m);
        if (score < best_penalty) {
            best_penalty = score;
            best_mask = p;
        }
        mask.applyMask(&m, p); // revert (format bits are overwritten next round)
        if (p == 7) break;
    }

    mask.applyMask(&m, best_mask);
    format_info.drawFormat(&m, level, best_mask);
    format_info.drawVersion(&m);
    return .{ .matrix = m, .version = m.version, .level = level, .mask = best_mask };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unmasked end-to-end produces a v1 matrix" {
    const a = std.testing.allocator;
    var m = try generateUnmasked(a, "HELLO WORLD", .m, .auto);
    defer m.deinit();
    try std.testing.expectEqual(@as(u8, 1), m.version);
    try std.testing.expect(m.get(0, 0));
}

test "masked pipeline picks a mask and fills format info" {
    const a = std.testing.allocator;
    var g = try generate(a, "HELLO WORLD", .m, .auto);
    defer g.deinit();
    try std.testing.expectEqual(@as(u8, 1), g.version);
    // The dark module is always set.
    try std.testing.expect(g.matrix.get(8, g.matrix.size - 8));
}

test "high-version pipeline builds without error" {
    const a = std.testing.allocator;
    const text = "x" ** 1500; // lands well into the multi-alignment range
    var g = try generate(a, text, .m, .auto);
    defer g.deinit();
    try std.testing.expect(g.version >= 14 and g.version <= 40);
    try std.testing.expectEqual(@as(usize, 17 + 4 * @as(usize, g.version)), g.matrix.size);
    try std.testing.expect(g.matrix.get(8, g.matrix.size - 8)); // dark module present
}

test "auto mask selection chooses the lowest-penalty mask" {
    const a = std.testing.allocator;
    var g = try generate(a, "Hello, World!", .m, .auto);
    defer g.deinit();
    // Verified against the spec penalty (and qrcode's lost_point): mask 6 wins.
    try std.testing.expectEqual(@as(u3, 6), g.mask);
}

test "golden: 'Hi!' v1-M mask 0 matches the oracle-verified fixture" {
    // This exact module layout was confirmed module-for-module against the
    // `qrcode` reference library. Guards the whole pipeline without Python.
    const expected =
        \\#######.......#######
        \\#.....#.###.#.#.....#
        \\#.###.#...###.#.###.#
        \\#.###.#..#.#..#.###.#
        \\#.###.#.#...#.#.###.#
        \\#.....#..#..#.#.....#
        \\#######.#.#.#.#######
        \\...........##........
        \\#.#.#.#...##....#..#.
        \\#.#....##.#...#..####
        \\.....###....#...#####
        \\..#.#..####...#..#.#.
        \\###.#.####..#.#.#....
        \\........####.#.#.#.#.
        \\#######...##.###.####
        \\#.....#..#####.###..#
        \\#.###.#.#.##.###..#.#
        \\#.###.#..#....#...##.
        \\#.###.#.#.#.#...#...#
        \\#.....#.......#...##.
        \\#######.##..#.#.#.###
    ;
    const a = std.testing.allocator;
    var g = try generateWithMask(a, "Hi!", .m, 0, .auto);
    defer g.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var y: usize = 0;
    while (y < g.matrix.size) : (y += 1) {
        var x: usize = 0;
        while (x < g.matrix.size) : (x += 1) {
            try buf.append(a, if (g.matrix.get(x, y)) '#' else '.');
        }
        if (y + 1 < g.matrix.size) try buf.append(a, '\n');
    }
    try std.testing.expectEqualStrings(expected, buf.items);
}

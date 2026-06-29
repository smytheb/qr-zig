//! Optimal mixed-mode segmentation. Splits the input into a sequence of
//! segments — each numeric, alphanumeric, or byte — that minimizes the total
//! encoded bit count for a given version (the character-count indicator width
//! depends on the version, so the optimum can shift across version tiers).
//!
//! Uses a straightforward O(n^2) dynamic program: `dp[i]` is the minimum bits to
//! encode the first `i` characters as whole segments, relaxed over every split
//! point and mode. The constituent segment-cost functions are exact (including
//! the trailing partial group of numeric/alphanumeric runs), so the result is a
//! true optimum rather than a heuristic.

const std = @import("std");
const tables = @import("tables.zig");

pub const Mode = enum {
    numeric,
    alphanumeric,
    byte,

    pub fn indicator(self: Mode) u32 {
        return switch (self) {
            .numeric => 0b0001,
            .alphanumeric => 0b0010,
            .byte => 0b0100,
        };
    }
};

pub const Segment = struct {
    mode: Mode,
    start: usize,
    len: usize,
};

pub fn isNumeric(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Alphanumeric value of a character, or null if it is outside the set.
pub fn alphanumericValue(c: u8) ?u16 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        ' ' => 36,
        '$' => 37,
        '%' => 38,
        '*' => 39,
        '+' => 40,
        '-' => 41,
        '.' => 42,
        '/' => 43,
        ':' => 44,
        else => null,
    };
}

/// Character for an alphanumeric value 0..44, or null if out of range (the
/// inverse of `alphanumericValue`).
pub fn alphanumericChar(v: u32) ?u8 {
    const chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
    return if (v < chars.len) chars[v] else null;
}

/// Width in bits of the character-count indicator for (mode, version).
pub fn charCountBits(mode: Mode, version: u8) u6 {
    const tier: usize = if (version <= 9) 0 else if (version <= 26) 1 else 2;
    return switch (mode) {
        .numeric => ([_]u6{ 10, 12, 14 })[tier],
        .alphanumeric => ([_]u6{ 9, 11, 13 })[tier],
        .byte => ([_]u6{ 8, 16, 16 })[tier],
    };
}

/// Bits of mode-specific data for a segment of `len` characters (excludes the
/// mode indicator and character-count indicator).
pub fn dataBits(mode: Mode, len: usize) usize {
    return switch (mode) {
        .numeric => (len / 3) * 10 + switch (len % 3) {
            2 => @as(usize, 7),
            1 => @as(usize, 4),
            else => @as(usize, 0),
        },
        .alphanumeric => (len / 2) * 11 + if (len % 2 == 1) @as(usize, 6) else 0,
        .byte => len * 8,
    };
}

fn header(mode: Mode, version: u8) usize {
    return 4 + @as(usize, charCountBits(mode, version));
}

const Back = struct { from: usize, mode: Mode };

const sentinel: usize = std.math.maxInt(usize) / 2;

/// Run the DP, filling `dp[0..n]` with minimum bit costs. If `back` is non-null
/// it records the optimal split point and mode that produced each `dp[i]`.
fn runDp(text: []const u8, dp: []usize, back: ?[]Back, version: u8) void {
    const n = text.len;
    dp[0] = 0;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        dp[i] = sentinel;
        var can_num = true;
        var can_alnum = true;
        var j: usize = i;
        while (j > 0) {
            j -= 1;
            const c = text[j];
            if (!isNumeric(c)) can_num = false;
            if (alphanumericValue(c) == null) can_alnum = false;
            const len = i - j;

            // Byte mode can always represent the run.
            relax(dp, back, i, j, .byte, dp[j] + header(.byte, version) + dataBits(.byte, len));
            if (can_alnum)
                relax(dp, back, i, j, .alphanumeric, dp[j] + header(.alphanumeric, version) + dataBits(.alphanumeric, len));
            if (can_num)
                relax(dp, back, i, j, .numeric, dp[j] + header(.numeric, version) + dataBits(.numeric, len));
        }
    }
}

fn relax(dp: []usize, back: ?[]Back, i: usize, j: usize, mode: Mode, cost: usize) void {
    if (cost < dp[i]) {
        dp[i] = cost;
        if (back) |b| b[i] = .{ .from = j, .mode = mode };
    }
}

/// Minimum total encoded bits (indicators + counts + data) for `text` at
/// `version`, over all valid segmentations.
pub fn optimalBits(allocator: std.mem.Allocator, text: []const u8, version: u8) !usize {
    const dp = try allocator.alloc(usize, text.len + 1);
    defer allocator.free(dp);
    runDp(text, dp, null, version);
    return dp[text.len];
}

/// The optimal segmentation of `text` for `version`. Caller owns the slice.
pub fn optimalSegments(allocator: std.mem.Allocator, text: []const u8, version: u8) ![]Segment {
    const n = text.len;
    if (n == 0) {
        const segs = try allocator.alloc(Segment, 1);
        segs[0] = .{ .mode = .byte, .start = 0, .len = 0 };
        return segs;
    }

    const dp = try allocator.alloc(usize, n + 1);
    defer allocator.free(dp);
    const back = try allocator.alloc(Back, n + 1);
    defer allocator.free(back);
    runDp(text, dp, back, version);

    // Walk back pointers to recover segment boundaries (reversed).
    var list: std.ArrayList(Segment) = .empty;
    errdefer list.deinit(allocator);
    var i = n;
    while (i > 0) {
        const b = back[i];
        try list.append(allocator, .{ .mode = b.mode, .start = b.from, .len = i - b.from });
        i = b.from;
    }
    std.mem.reverse(Segment, list.items);
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectSegments(text: []const u8, version: u8, expected: []const Segment) !void {
    const segs = try optimalSegments(testing.allocator, text, version);
    defer testing.allocator.free(segs);
    try testing.expectEqualSlices(Segment, expected, segs);
}

test "alphanumericChar inverts alphanumericValue" {
    var c: u8 = 0;
    while (true) : (c += 1) {
        if (alphanumericValue(c)) |v| {
            try testing.expectEqual(@as(?u8, c), alphanumericChar(v));
        }
        if (c == 255) break;
    }
    try testing.expectEqual(@as(?u8, null), alphanumericChar(45)); // out of range
}

test "pure inputs become a single segment" {
    try expectSegments("12345", 1, &.{.{ .mode = .numeric, .start = 0, .len = 5 }});
    try expectSegments("HELLO", 1, &.{.{ .mode = .alphanumeric, .start = 0, .len = 5 }});
    try expectSegments("hello", 1, &.{.{ .mode = .byte, .start = 0, .len = 5 }});
}

test "long digit run inside a byte string splits out as numeric" {
    // "a" + 30 digits + "b": the digit run is far cheaper in numeric mode than
    // paying 8 bits/char, so the optimum is byte | numeric | byte.
    const text = "a012345678901234567890123456789b";
    try expectSegments(text, 1, &.{
        .{ .mode = .byte, .start = 0, .len = 1 },
        .{ .mode = .numeric, .start = 1, .len = 30 },
        .{ .mode = .byte, .start = 31, .len = 1 },
    });
}

test "short digit run stays in the surrounding byte segment" {
    // A 2-digit run is not worth a mode switch (header cost exceeds savings).
    const text = "abc12def";
    try expectSegments(text, 1, &.{.{ .mode = .byte, .start = 0, .len = 8 }});
}

/// Reference: exhaustively try assigning each character to a mode it supports,
/// collapse equal-mode runs, and take the minimum bit count. Exponential, so
/// only for tiny strings — used to prove the DP is truly optimal.
fn bruteForceBits(text: []const u8, version: u8) usize {
    var best: usize = sentinel;
    const n = text.len;
    var assign: usize = 0;
    const combos = std.math.pow(usize, 3, n);
    while (assign < combos) : (assign += 1) {
        var bits: usize = 0;
        var ok = true;
        var k: usize = 0;
        var code = assign;
        var run_mode: ?Mode = null;
        var run_len: usize = 0;
        while (k < n) : (k += 1) {
            const m: Mode = switch (code % 3) {
                0 => .numeric,
                1 => .alphanumeric,
                else => .byte,
            };
            code /= 3;
            const valid = switch (m) {
                .numeric => isNumeric(text[k]),
                .alphanumeric => alphanumericValue(text[k]) != null,
                .byte => true,
            };
            if (!valid) {
                ok = false;
                break;
            }
            if (run_mode) |rm| {
                if (rm == m) {
                    run_len += 1;
                } else {
                    bits += header(rm, version) + dataBits(rm, run_len);
                    run_mode = m;
                    run_len = 1;
                }
            } else {
                run_mode = m;
                run_len = 1;
            }
        }
        if (ok and run_mode != null) {
            bits += header(run_mode.?, version) + dataBits(run_mode.?, run_len);
            best = @min(best, bits);
        }
    }
    return best;
}

test "DP matches brute force on small mixed strings" {
    const cases = [_][]const u8{ "A1b2", "12ab34", "ZZ99zz", "a1B2c3", "555X" };
    for (cases) |text| {
        const dp_bits = try optimalBits(testing.allocator, text, 1);
        try testing.expectEqual(bruteForceBits(text, 1), dp_bits);
    }
}

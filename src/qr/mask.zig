//! Data masking: the eight QR mask patterns, the four penalty rules, and
//! application of a mask to the data (non-reserved) modules of a matrix.
//!
//! Masking XORs a geometric pattern into the data region to avoid problematic
//! layouts (large blank areas, finder-like runs). Applying the same mask twice
//! restores the original, which the selection loop relies on.

const std = @import("std");
const Matrix = @import("matrix.zig").Matrix;

// Penalty constants from the QR specification.
const n1 = 3; // runs of 5+ same-color modules
const n2 = 3; // 2x2 same-color blocks
const n3 = 40; // finder-like patterns
const n4 = 10; // dark/light imbalance

/// Whether mask `pattern` flips the module at (row, col).
pub fn condition(pattern: u3, row: usize, col: usize) bool {
    const i = row;
    const j = col;
    return switch (pattern) {
        0 => (i + j) % 2 == 0,
        1 => i % 2 == 0,
        2 => j % 3 == 0,
        3 => (i + j) % 3 == 0,
        4 => (i / 2 + j / 3) % 2 == 0,
        5 => (i * j) % 2 + (i * j) % 3 == 0,
        6 => ((i * j) % 2 + (i * j) % 3) % 2 == 0,
        7 => ((i + j) % 2 + (i * j) % 3) % 2 == 0,
    };
}

/// XOR mask `pattern` into all data (non-reserved) modules.
pub fn applyMask(m: *Matrix, pattern: u3) void {
    var y: usize = 0;
    while (y < m.size) : (y += 1) {
        var x: usize = 0;
        while (x < m.size) : (x += 1) {
            if (!m.isReserved(x, y) and condition(pattern, y, x)) m.flip(x, y);
        }
    }
}

/// Total penalty score (lower is better) used to choose a mask.
pub fn penalty(m: *const Matrix) usize {
    return rule1(m) + rule2(m) + rule3(m) + rule4(m);
}

// Rule 1: five or more same-color modules in a row/column.
fn rule1(m: *const Matrix) usize {
    var total: usize = 0;
    const size = m.size;

    // Rows.
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var run: usize = 1;
        var x: usize = 1;
        while (x < size) : (x += 1) {
            if (m.get(x, y) == m.get(x - 1, y)) {
                run += 1;
            } else {
                if (run >= 5) total += n1 + (run - 5);
                run = 1;
            }
        }
        if (run >= 5) total += n1 + (run - 5);
    }

    // Columns.
    var x: usize = 0;
    while (x < size) : (x += 1) {
        var run: usize = 1;
        var yy: usize = 1;
        while (yy < size) : (yy += 1) {
            if (m.get(x, yy) == m.get(x, yy - 1)) {
                run += 1;
            } else {
                if (run >= 5) total += n1 + (run - 5);
                run = 1;
            }
        }
        if (run >= 5) total += n1 + (run - 5);
    }
    return total;
}

// Rule 2: every 2x2 block of one color.
fn rule2(m: *const Matrix) usize {
    var total: usize = 0;
    var y: usize = 0;
    while (y + 1 < m.size) : (y += 1) {
        var x: usize = 0;
        while (x + 1 < m.size) : (x += 1) {
            const v = m.get(x, y);
            if (m.get(x + 1, y) == v and m.get(x, y + 1) == v and m.get(x + 1, y + 1) == v) {
                total += n2;
            }
        }
    }
    return total;
}

// Rule 3: the 1:1:3:1:1 finder-like pattern with four light modules on one
// side, in any row or column.
fn rule3(m: *const Matrix) usize {
    const pattern_a = [11]bool{ true, false, true, true, true, false, true, false, false, false, false };
    const pattern_b = [11]bool{ false, false, false, false, true, false, true, true, true, false, true };
    var total: usize = 0;
    const size = m.size;

    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x + 11 <= size) : (x += 1) {
            if (matchRow(m, x, y, pattern_a) or matchRow(m, x, y, pattern_b)) total += n3;
        }
    }
    var x: usize = 0;
    while (x < size) : (x += 1) {
        var yy: usize = 0;
        while (yy + 11 <= size) : (yy += 1) {
            if (matchCol(m, x, yy, pattern_a) or matchCol(m, x, yy, pattern_b)) total += n3;
        }
    }
    return total;
}

fn matchRow(m: *const Matrix, x0: usize, y: usize, pat: [11]bool) bool {
    for (pat, 0..) |p, k| {
        if (m.get(x0 + k, y) != p) return false;
    }
    return true;
}

fn matchCol(m: *const Matrix, x: usize, y0: usize, pat: [11]bool) bool {
    for (pat, 0..) |p, k| {
        if (m.get(x, y0 + k) != p) return false;
    }
    return true;
}

// Rule 4: proportion of dark modules away from 50%.
fn rule4(m: *const Matrix) usize {
    var dark: i64 = 0;
    for (m.modules) |v| {
        if (v) dark += 1;
    }
    const total: i64 = @intCast(m.modules.len);
    // Smallest k such that the dark ratio lies within (50 ± 5(k+1))%.
    const k = @divTrunc(@as(i64, @intCast(@abs(dark * 20 - total * 10))) + total - 1, total) - 1;
    return @as(usize, @intCast(k)) * n4;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mask condition matches the spec formulas" {
    try std.testing.expect(condition(0, 0, 0)); // (0+0)%2==0
    try std.testing.expect(!condition(0, 0, 1));
    try std.testing.expect(condition(1, 2, 5)); // row 2 even
    try std.testing.expect(!condition(1, 3, 0));
    try std.testing.expect(condition(2, 0, 6)); // col 6 % 3 == 0
}

test "applying a mask twice is the identity" {
    const a = std.testing.allocator;
    var m = try Matrix.init(a, 1);
    defer m.deinit();
    // Some arbitrary unreserved data pattern.
    var y: usize = 10;
    while (y < 15) : (y += 1) {
        var x: usize = 10;
        while (x < 15) : (x += 1) m.modules[y * m.size + x] = (x + y) % 3 == 0;
    }
    var snapshot: [21 * 21]bool = undefined;
    @memcpy(snapshot[0..m.modules.len], m.modules);

    applyMask(&m, 5);
    applyMask(&m, 5);
    try std.testing.expectEqualSlices(bool, snapshot[0..m.modules.len], m.modules);
}

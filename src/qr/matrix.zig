//! The QR module matrix: function patterns (finders, separators, timing,
//! alignment, dark module), reserved format/version areas, and the zigzag
//! placement of the interleaved data+EC bitstream.
//!
//! This phase builds the *unmasked* matrix. Data masking and format/version
//! information are applied in a later phase.

const std = @import("std");
const tables = @import("tables.zig");

/// Maximum number of alignment-pattern coordinates per axis (version 40 has 7).
const max_align_coords = 7;

/// Compute the alignment-pattern center coordinates for `version` into `buf`,
/// returning the populated slice (empty for version 1). Uses the standard
/// even-spacing rule (with version 32's documented special case). Patterns are
/// placed at every (row, col) pair of these, minus the three that collide with
/// the finder patterns.
fn alignmentCenters(version: u8, buf: *[max_align_coords]usize) []const usize {
    if (version == 1) return buf[0..0];
    const size = 17 + 4 * @as(usize, version);
    const num_align: usize = version / 7 + 2;
    const step: usize = if (version == 32)
        26
    else
        ((@as(usize, version) * 4 + num_align * 2 + 1) / (num_align * 2 - 2)) * 2;

    // The high coordinates are evenly spaced by `step` from the far edge; the
    // first coordinate is pinned to 6, so the first gap absorbs any slack.
    buf[0] = 6;
    var pos: usize = size - 7;
    var i: usize = num_align - 1;
    while (i >= 1) : (i -= 1) {
        buf[i] = pos;
        if (i > 1) pos -= step;
    }
    return buf[0..num_align];
}

pub const Matrix = struct {
    size: usize,
    version: u8,
    /// `true` == dark module. Row-major, length `size * size`.
    modules: []bool,
    /// `true` == function/reserved module (not available for data).
    reserved: []bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, version: u8) !Matrix {
        std.debug.assert(version >= tables.min_version and version <= tables.max_version);
        const size = 17 + 4 * @as(usize, version);
        const modules = try allocator.alloc(bool, size * size);
        errdefer allocator.free(modules);
        const reserved = try allocator.alloc(bool, size * size);
        @memset(modules, false);
        @memset(reserved, false);
        return .{
            .size = size,
            .version = version,
            .modules = modules,
            .reserved = reserved,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Matrix) void {
        self.allocator.free(self.modules);
        self.allocator.free(self.reserved);
        self.* = undefined;
    }

    fn idx(self: *const Matrix, x: usize, y: usize) usize {
        return y * self.size + x;
    }

    pub fn get(self: *const Matrix, x: usize, y: usize) bool {
        return self.modules[self.idx(x, y)];
    }

    pub fn isReserved(self: *const Matrix, x: usize, y: usize) bool {
        return self.reserved[self.idx(x, y)];
    }

    /// Set a function module to `dark` and mark it reserved.
    fn setFunction(self: *Matrix, x: usize, y: usize, dark: bool) void {
        const i = self.idx(x, y);
        self.modules[i] = dark;
        self.reserved[i] = true;
    }

    /// Mark a module reserved without changing its value (for format/version
    /// areas filled in a later phase, and to claim overlaps idempotently).
    fn reserve(self: *Matrix, x: usize, y: usize) void {
        self.reserved[self.idx(x, y)] = true;
    }

    /// Toggle a module's dark/light value (used by data masking).
    pub fn flip(self: *Matrix, x: usize, y: usize) void {
        const i = self.idx(x, y);
        self.modules[i] = !self.modules[i];
    }

    /// Write an absolute value into a (reserved) function module — used to draw
    /// format and version information after masking.
    pub fn setReserved(self: *Matrix, x: usize, y: usize, dark: bool) void {
        const i = self.idx(x, y);
        self.modules[i] = dark;
        self.reserved[i] = true;
    }

    /// Set a module's dark/light value without touching its reserved flag — used
    /// when loading a scanned matrix into a pre-built function-pattern layout.
    pub fn setModule(self: *Matrix, x: usize, y: usize, dark: bool) void {
        self.modules[self.idx(x, y)] = dark;
    }

    // -- function patterns ---------------------------------------------------

    fn placeFinder(self: *Matrix, x0: usize, y0: usize) void {
        var dy: usize = 0;
        while (dy < 7) : (dy += 1) {
            var dx: usize = 0;
            while (dx < 7) : (dx += 1) {
                const border = dx == 0 or dx == 6 or dy == 0 or dy == 6;
                const core = dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4;
                self.setFunction(x0 + dx, y0 + dy, border or core);
            }
        }
    }

    fn placeFinders(self: *Matrix) void {
        self.placeFinder(0, 0); // top-left
        self.placeFinder(self.size - 7, 0); // top-right
        self.placeFinder(0, self.size - 7); // bottom-left
    }

    fn placeSeparators(self: *Matrix) void {
        const n = self.size;
        // Top-left: row 7 (cols 0-7) and col 7 (rows 0-7).
        var i: usize = 0;
        while (i <= 7) : (i += 1) {
            self.setFunction(i, 7, false);
            self.setFunction(7, i, false);
        }
        // Top-right: row 7 (cols n-8..n-1) and col n-8 (rows 0-7).
        i = 0;
        while (i <= 7) : (i += 1) {
            self.setFunction(n - 8 + i, 7, false);
            self.setFunction(n - 8, i, false);
        }
        // Bottom-left: row n-8 (cols 0-7) and col 7 (rows n-8..n-1).
        i = 0;
        while (i <= 7) : (i += 1) {
            self.setFunction(i, n - 8, false);
            self.setFunction(7, n - 8 + i, false);
        }
    }

    fn placeTiming(self: *Matrix) void {
        var i: usize = 8;
        while (i < self.size - 8) : (i += 1) {
            const dark = i % 2 == 0;
            self.setFunction(i, 6, dark); // horizontal, row 6
            self.setFunction(6, i, dark); // vertical, col 6
        }
    }

    fn placeAlignment(self: *Matrix) void {
        var buf: [max_align_coords]usize = undefined;
        const centers = alignmentCenters(self.version, &buf);
        if (centers.len == 0) return;
        const first = centers[0];
        const last = centers[centers.len - 1];
        for (centers) |r| {
            for (centers) |c| {
                // Skip the three centers that overlap finder patterns.
                if ((r == first and c == first) or
                    (r == first and c == last) or
                    (r == last and c == first)) continue;
                self.placeAlignmentAt(c, r);
            }
        }
    }

    fn placeAlignmentAt(self: *Matrix, cx: usize, cy: usize) void {
        var dy: isize = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: isize = -2;
            while (dx <= 2) : (dx += 1) {
                const ring = @abs(dx) == 2 or @abs(dy) == 2;
                const center = dx == 0 and dy == 0;
                const x: usize = @intCast(@as(isize, @intCast(cx)) + dx);
                const y: usize = @intCast(@as(isize, @intCast(cy)) + dy);
                self.setFunction(x, y, ring or center);
            }
        }
    }

    fn placeDarkModule(self: *Matrix) void {
        // Always-dark module at (col 8, row 4*version + 9).
        self.setFunction(8, 4 * @as(usize, self.version) + 9, true);
    }

    fn reserveFormat(self: *Matrix) void {
        const n = self.size;
        var i: usize = 0;
        while (i <= 8) : (i += 1) {
            self.reserve(i, 8); // row 8, cols 0-8
            self.reserve(8, i); // col 8, rows 0-8
        }
        i = 0;
        while (i < 8) : (i += 1) {
            self.reserve(n - 8 + i, 8); // row 8, cols n-8..n-1
            self.reserve(8, n - 8 + i); // col 8, rows n-8..n-1
        }
    }

    fn reserveVersion(self: *Matrix) void {
        if (self.version < 7) return;
        const n = self.size;
        var r: usize = 0;
        while (r < 6) : (r += 1) {
            var c: usize = n - 11;
            while (c < n - 8) : (c += 1) {
                self.reserve(c, r); // top-right 6x3 block
                self.reserve(r, c); // bottom-left 3x6 block (transposed)
            }
        }
    }

    // -- data placement ------------------------------------------------------

    fn dataBit(bytes: []const u8, k: usize) bool {
        const byte_index = k / 8;
        if (byte_index >= bytes.len) return false; // remainder bits are 0
        const shift: u3 = @intCast(7 - (k % 8));
        return (bytes[byte_index] >> shift) & 1 == 1;
    }

    /// Walk the matrix in the standard upward/downward two-column zigzag from
    /// the bottom-right, writing data bits into every non-reserved module.
    fn placeData(self: *Matrix, bytes: []const u8) void {
        var bit: usize = 0;
        var upward = true;
        var col: isize = @intCast(self.size - 1);
        while (col > 0) : (col -= 2) {
            if (col == 6) col -= 1; // skip the vertical timing column
            var k: usize = 0;
            while (k < self.size) : (k += 1) {
                const row = if (upward) self.size - 1 - k else k;
                var pair: usize = 0;
                while (pair < 2) : (pair += 1) {
                    const x: usize = @intCast(col - @as(isize, @intCast(pair)));
                    if (!self.isReserved(x, row)) {
                        self.modules[self.idx(x, row)] = dataBit(bytes, bit);
                        bit += 1;
                    }
                }
            }
            upward = !upward;
        }
    }

    /// Number of modules available for data (non-reserved). Should equal
    /// `total_codewords * 8 + remainder_bits`.
    pub fn dataModuleCount(self: *const Matrix) usize {
        var count: usize = 0;
        for (self.reserved) |r| {
            if (!r) count += 1;
        }
        return count;
    }
};

/// Build a matrix with only the function patterns and reserved areas placed (no
/// data). The decoder uses this to recover the reserved-module map for a version
/// before loading scanned module values.
pub fn buildFunctionMatrix(allocator: std.mem.Allocator, version: u8) !Matrix {
    var m = try Matrix.init(allocator, version);
    errdefer m.deinit();
    m.placeFinders();
    m.placeSeparators();
    m.placeTiming();
    m.placeAlignment();
    m.placeDarkModule();
    m.reserveFormat();
    m.reserveVersion();
    return m;
}

/// Build the unmasked matrix for `version` from the interleaved codeword stream.
pub fn build(allocator: std.mem.Allocator, version: u8, interleaved: []const u8) !Matrix {
    var m = try buildFunctionMatrix(allocator, version);
    errdefer m.deinit();
    m.placeData(interleaved);
    return m;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Remainder bits appended after the codeword stream, per version (1-40).
const remainder_bits = [40]u8{
    0, 7, 7, 7, 7, 7, 0, 0, 0, 0,
    0, 0, 0, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 3, 3, 3,
    3, 3, 3, 3, 0, 0, 0, 0, 0, 0,
};

test "matrix size matches version" {
    const a = std.testing.allocator;
    var m1 = try Matrix.init(a, 1);
    defer m1.deinit();
    try std.testing.expectEqual(@as(usize, 21), m1.size);

    var m10 = try Matrix.init(a, 10);
    defer m10.deinit();
    try std.testing.expectEqual(@as(usize, 57), m10.size);
}

test "finder and timing patterns are placed correctly" {
    const a = std.testing.allocator;
    var m = try Matrix.init(a, 1);
    defer m.deinit();
    m.placeFinders();
    m.placeSeparators();
    m.placeTiming();

    // Finder corners are dark; the white ring is light.
    try std.testing.expect(m.get(0, 0));
    try std.testing.expect(!m.get(1, 1));
    try std.testing.expect(m.get(3, 3)); // center of the 3x3 core
    // Timing pattern alternates starting dark at index 8.
    try std.testing.expect(m.get(8, 6));
    try std.testing.expect(!m.get(9, 6));
}

test "non-reserved module count equals codeword bits plus remainder" {
    const a = std.testing.allocator;
    var v: u8 = 1;
    while (v <= tables.max_version) : (v += 1) {
        var m = try Matrix.init(a, v);
        defer m.deinit();
        m.placeFinders();
        m.placeSeparators();
        m.placeTiming();
        m.placeAlignment();
        m.placeDarkModule();
        m.reserveFormat();
        m.reserveVersion();

        const expected = @as(usize, tables.total_codewords[v - 1]) * 8 + remainder_bits[v - 1];
        try std.testing.expectEqual(expected, m.dataModuleCount());
    }
}

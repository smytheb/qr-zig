//! Minimal MSB-first bit writer used to assemble the QR data bitstream.
//!
//! Bits are packed into bytes most-significant-bit first, which is the order QR
//! codes use for mode indicators, character counts, and data. Backed by an
//! unmanaged `std.ArrayList(u8)` (0.15+ idiom: allocator passed per call).

const std = @import("std");

pub const BitWriter = struct {
    data: std.ArrayList(u8),
    nbits: usize,

    pub const empty: BitWriter = .{ .data = .empty, .nbits = 0 };

    pub fn deinit(self: *BitWriter, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    /// Append the low `n` bits of `value`, most-significant first. `n` may be 0.
    pub fn writeBits(
        self: *BitWriter,
        allocator: std.mem.Allocator,
        value: u32,
        n: u6,
    ) !void {
        var i: u6 = n;
        while (i > 0) : (i -= 1) {
            const bit: u1 = @intCast((value >> @as(u5, @intCast(i - 1))) & 1);
            const byte_index = self.nbits / 8;
            const bit_index = self.nbits % 8; // 0 == MSB of the byte
            if (bit_index == 0) try self.data.append(allocator, 0);
            if (bit == 1) {
                const shift: u3 = @intCast(7 - bit_index);
                self.data.items[byte_index] |= @as(u8, 1) << shift;
            }
            self.nbits += 1;
        }
    }

    /// Pad with zero bits until the stream is byte-aligned.
    pub fn padToByte(self: *BitWriter, allocator: std.mem.Allocator) !void {
        while (self.nbits % 8 != 0) try self.writeBits(allocator, 0, 1);
    }

    /// Number of whole bytes written so far.
    pub fn byteLen(self: *const BitWriter) usize {
        return self.data.items.len;
    }
};

/// MSB-first bit reader — the inverse of `BitWriter`. Reads fixed-width fields
/// out of a packed byte slice, tracking a bit cursor.
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // bit cursor

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Number of unread bits.
    pub fn remaining(self: *const BitReader) usize {
        return self.data.len * 8 - self.pos;
    }

    /// Read the next `n` bits (most-significant first) into a `u32`. `n` must be
    /// <= 24 and there must be at least `n` bits remaining.
    pub fn readBits(self: *BitReader, n: u6) u32 {
        std.debug.assert(n <= 24);
        std.debug.assert(self.pos + n <= self.data.len * 8);
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const byte_index = self.pos / 8;
            const bit_index = self.pos % 8; // 0 == MSB of the byte
            const shift: u3 = @intCast(7 - bit_index);
            const bit: u1 = @intCast((self.data[byte_index] >> shift) & 1);
            value = (value << 1) | bit;
            self.pos += 1;
        }
        return value;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writes MSB-first across byte boundaries" {
    const a = std.testing.allocator;
    var bw: BitWriter = .empty;
    defer bw.deinit(a);

    try bw.writeBits(a, 0b0100, 4); // mode-style nibble
    try bw.writeBits(a, 0b00000011, 8); // count = 3
    // 12 bits so far: 0100 0000 0011 -> bytes 0x40, 0x3_
    try bw.writeBits(a, 0b1111, 4); // fill the second byte
    try std.testing.expectEqual(@as(usize, 16), bw.nbits);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x40, 0x3F }, bw.data.items);
}

test "padToByte rounds up with zeros" {
    const a = std.testing.allocator;
    var bw: BitWriter = .empty;
    defer bw.deinit(a);

    try bw.writeBits(a, 0b101, 3);
    try bw.padToByte(a);
    try std.testing.expectEqual(@as(usize, 1), bw.byteLen());
    try std.testing.expectEqual(@as(u8, 0b10100000), bw.data.items[0]);
}

test "BitReader reads back what BitWriter wrote" {
    const a = std.testing.allocator;
    var bw: BitWriter = .empty;
    defer bw.deinit(a);
    try bw.writeBits(a, 0b0100, 4); // mode nibble
    try bw.writeBits(a, 13, 8); // an 8-bit count
    try bw.writeBits(a, 0b10101010101, 11); // an alphanumeric pair
    try bw.writeBits(a, 7, 4);

    // 27 bits written occupy 4 whole bytes (32 bits); the reader is byte-based.
    var br = BitReader.init(bw.data.items);
    try std.testing.expectEqual(@as(usize, 32), br.remaining());
    try std.testing.expectEqual(@as(u32, 0b0100), br.readBits(4));
    try std.testing.expectEqual(@as(u32, 13), br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0b10101010101), br.readBits(11));
    try std.testing.expectEqual(@as(u32, 7), br.readBits(4));
    try std.testing.expectEqual(@as(usize, 5), br.remaining()); // trailing pad bits
}

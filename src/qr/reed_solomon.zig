//! Reed-Solomon error-correction coding over GF(256) for QR codes.
//!
//! Given a block of data codewords, this produces `ec_count` error-correction
//! codewords such that the concatenation `data ++ ec`, viewed as a polynomial,
//! is divisible by the RS generator polynomial of degree `ec_count`. QR uses
//! systematic encoding: the original data bytes are preserved verbatim and the
//! EC bytes are appended.
//!
//! The generator polynomial is built at comptime (comptime table idiom from the
//! wiki) as the product (x - alpha^0)(x - alpha^1)...(x - alpha^{n-1}).

const std = @import("std");
const gf = @import("galois.zig");
const tables = @import("tables.zig");

/// Error-correction generator polynomial of the given degree, coefficients in
/// high-to-low order (index 0 is the leading x^degree term, always == 1).
pub fn generatorPoly(comptime degree: usize) [degree + 1]u8 {
    @setEvalBranchQuota(100_000);

    // Build low-first (index 0 == constant term), then reverse to high-first.
    var low = [_]u8{0} ** (degree + 1);
    low[0] = 1; // start from the polynomial "1"
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        // Multiply the current polynomial by (x + alpha^i). In GF(256) addition
        // is XOR, so (x - alpha^i) == (x + alpha^i).
        const root = gf.expOf(i);
        var k: usize = i + 1;
        while (k > 0) : (k -= 1) {
            low[k] = gf.mul(low[k], root) ^ low[k - 1];
        }
        low[0] = gf.mul(low[0], root);
    }

    var high: [degree + 1]u8 = undefined;
    var j: usize = 0;
    while (j <= degree) : (j += 1) high[j] = low[degree - j];
    return high;
}

/// Compute `ec_count` error-correction codewords for `data` into `out`.
///
/// Uses the classic LFSR remainder computation: `out` is the remainder of
/// `data * x^ec_count` divided by the generator polynomial.
pub fn encode(comptime ec_count: usize, data: []const u8, out: *[ec_count]u8) void {
    const gen = comptime generatorPoly(ec_count);
    var rem = [_]u8{0} ** ec_count;

    for (data) |d| {
        const factor = d ^ rem[0];
        // Shift the remainder register up by one position.
        var k: usize = 0;
        while (k + 1 < ec_count) : (k += 1) rem[k] = rem[k + 1];
        rem[ec_count - 1] = 0;
        if (factor != 0) {
            // rem ^= factor * gen[1..]  (gen[0] == 1 is the term shifted out).
            var j: usize = 0;
            while (j < ec_count) : (j += 1) {
                rem[j] ^= gf.mul(gen[j + 1], factor);
            }
        }
    }
    out.* = rem;
}

/// Convenience wrapper returning the EC codewords by value.
pub fn encodeAlloc(comptime ec_count: usize, data: []const u8) [ec_count]u8 {
    var out: [ec_count]u8 = undefined;
    encode(ec_count, data, &out);
    return out;
}

/// Largest EC-codewords-per-block value across all supported versions; bounds
/// the fixed scratch buffers used by the runtime routines below.
const max_ec_per_block = 30;

/// Runtime equivalent of `generatorPoly`. Writes `degree + 1` coefficients
/// (high-first, leading 1) into `out`.
pub fn generatorPolyRuntime(degree: usize, out: []u8) void {
    std.debug.assert(out.len == degree + 1);
    @memset(out, 0);
    out[0] = 1; // low-first "1" while building
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        const root = gf.expOf(i);
        var k: usize = i + 1;
        while (k > 0) : (k -= 1) out[k] = gf.mul(out[k], root) ^ out[k - 1];
        out[0] = gf.mul(out[0], root);
    }
    std.mem.reverse(u8, out); // low-first -> high-first
}

/// Runtime equivalent of `encode` for an EC count known only at runtime
/// (`ec_count` comes from the spec tables). `out.len` must equal `ec_count`.
pub fn encodeRuntime(ec_count: usize, data: []const u8, out: []u8) void {
    std.debug.assert(out.len == ec_count);
    std.debug.assert(ec_count <= max_ec_per_block);

    var gen_buf: [max_ec_per_block + 1]u8 = undefined;
    const gen = gen_buf[0 .. ec_count + 1];
    generatorPolyRuntime(ec_count, gen);

    @memset(out, 0);
    for (data) |d| {
        const factor = d ^ out[0];
        var k: usize = 0;
        while (k + 1 < ec_count) : (k += 1) out[k] = out[k + 1];
        out[ec_count - 1] = 0;
        if (factor != 0) {
            var j: usize = 0;
            while (j < ec_count) : (j += 1) out[j] ^= gf.mul(gen[j + 1], factor);
        }
    }
}

/// Split `data` into the version/level's EC blocks, append each block's EC
/// codewords, and interleave into the final codeword sequence the matrix
/// placement consumes: all blocks' data interleaved column-wise, then all
/// blocks' EC interleaved column-wise.
///
/// Caller owns the returned slice (freed with `allocator`).
pub fn interleaveCodewords(
    allocator: std.mem.Allocator,
    data: []const u8,
    version: u8,
    level: tables.EcLevel,
) ![]u8 {
    const s = tables.blockStructure(version, level);
    const ec_count: usize = s.ec_per_block;
    const num_blocks = s.totalBlocks();
    std.debug.assert(data.len == s.dataCodewords());

    const ec_all = try allocator.alloc(u8, num_blocks * ec_count);
    defer allocator.free(ec_all);

    // Per-block EC codewords.
    {
        var offset: usize = 0;
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            const dlen: usize = if (b < s.g1_blocks) s.g1_data else s.g2_data;
            encodeRuntime(ec_count, data[offset .. offset + dlen], ec_all[b * ec_count .. (b + 1) * ec_count]);
            offset += dlen;
        }
    }

    const out = try allocator.alloc(u8, data.len + num_blocks * ec_count);
    var pos: usize = 0;

    // Interleave data codewords column by column across blocks.
    const max_data = @max(s.g1_data, s.g2_data);
    var col: usize = 0;
    while (col < max_data) : (col += 1) {
        var offset: usize = 0;
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            const dlen: usize = if (b < s.g1_blocks) s.g1_data else s.g2_data;
            if (col < dlen) {
                out[pos] = data[offset + col];
                pos += 1;
            }
            offset += dlen;
        }
    }

    // Interleave EC codewords (every block has the same EC count).
    var ec_col: usize = 0;
    while (ec_col < ec_count) : (ec_col += 1) {
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            out[pos] = ec_all[b * ec_count + ec_col];
            pos += 1;
        }
    }

    std.debug.assert(pos == out.len);
    return out;
}

// ===========================================================================
// Decoding (error correction)
// ===========================================================================
//
// The inverse of `encode`: given a received block `data ++ ec` that may contain
// symbol errors, recover the original codewords. This is classic syndrome
// decoding over GF(256) — the same field as encoding, so all arithmetic reuses
// `galois.zig`:
//
//   1. syndromes        S[j] = R(alpha^j); all-zero => no errors
//   2. error locator    Berlekamp-Massey over the syndromes -> lambda(x)
//   3. error locations   Chien search: roots of lambda give the bad positions
//   4. error values      Forney: e = X * omega(X^-1) / lambda'(X^-1)
//
// QR's RS generator has its first root at alpha^0 (see `generatorPoly`, which
// multiplies in (x + alpha^i) from i = 0). With that first-root index the Forney
// magnitude carries a leading X = alpha^p factor. Every buffer is bounded by
// `max_ec_per_block` and the GF(256) block limit of 255 codewords, so the
// routine needs no allocation.

/// A Reed-Solomon block over GF(256) can hold at most 255 codewords.
const max_block_len = 255;

pub const DecodeError = error{
    /// The block holds more errors than the EC codewords can correct.
    Uncorrectable,
};

/// Evaluate a high-first polynomial (index 0 == highest-degree term) at `x`.
fn polyEvalHigh(coeffs: []const u8, x: u8) u8 {
    var r: u8 = 0;
    for (coeffs) |c| r = gf.mul(r, x) ^ c;
    return r;
}

/// Evaluate a low-first polynomial (index i == coefficient of x^i) at `x`.
fn polyEvalLow(coeffs: []const u8, x: u8) u8 {
    var r: u8 = 0;
    var i: usize = coeffs.len;
    while (i > 0) {
        i -= 1;
        r = gf.mul(r, x) ^ coeffs[i];
    }
    return r;
}

/// `x` raised to `e` in GF(256). `x` must be nonzero for `e > 0`.
fn powGf(x: u8, e: usize) u8 {
    if (e == 0) return 1;
    if (x == 0) return 0;
    return gf.exp_table[(@as(usize, gf.log_table[x]) * e) % 255];
}

/// Correct a single Reed-Solomon block in place. `block` is the systematic
/// codeword `data ++ ec` (with `block[0]` the highest-order coefficient) and
/// `ec_count` is the number of trailing EC codewords. Returns the number of
/// symbol errors corrected (0 if the block was already consistent). Fails with
/// `Uncorrectable` when the block holds more than `ec_count / 2` errors or the
/// locator is otherwise inconsistent.
pub fn decodeBlock(block: []u8, ec_count: usize) DecodeError!usize {
    std.debug.assert(ec_count <= max_ec_per_block);
    std.debug.assert(block.len <= max_block_len);

    // -- syndromes: S[j] = block(alpha^j) for j in 0..ec_count ---------------
    var syn: [max_ec_per_block]u8 = undefined;
    var has_error = false;
    for (0..ec_count) |j| {
        syn[j] = polyEvalHigh(block, gf.expOf(j));
        if (syn[j] != 0) has_error = true;
    }
    if (!has_error) return 0;

    // -- Berlekamp-Massey: build the error-locator polynomial `lambda` -------
    // Polynomials here are low-first (index i == coefficient of x^i).
    var lambda = [_]u8{0} ** (max_ec_per_block + 1);
    var prev = [_]u8{0} ** (max_ec_per_block + 1);
    lambda[0] = 1;
    prev[0] = 1;
    var num_errors: usize = 0; // current locator degree
    var shift: usize = 1; // x^shift offset applied to `prev`
    var last_disc: u8 = 1; // last nonzero discrepancy
    for (0..ec_count) |n| {
        // discrepancy = S[n] + sum_{i=1..L} lambda[i] * S[n-i]
        var disc = syn[n];
        for (1..num_errors + 1) |i| disc ^= gf.mul(lambda[i], syn[n - i]);

        if (disc == 0) {
            shift += 1;
        } else {
            const coef = gf.div(disc, last_disc);
            const lambda_before = lambda;
            var i: usize = 0;
            while (i + shift <= max_ec_per_block) : (i += 1) {
                lambda[i + shift] ^= gf.mul(coef, prev[i]);
            }
            if (2 * num_errors <= n) {
                num_errors = n + 1 - num_errors;
                prev = lambda_before;
                last_disc = disc;
                shift = 1;
            } else {
                shift += 1;
            }
        }
    }

    if (2 * num_errors > ec_count) return error.Uncorrectable;

    // -- Chien search: error at power p where lambda(alpha^-p) == 0 ----------
    var positions: [max_ec_per_block]usize = undefined;
    var found: usize = 0;
    for (0..block.len) |p| {
        const x_inv = gf.expOf((255 - (p % 255)) % 255); // alpha^-p
        if (polyEvalLow(lambda[0 .. num_errors + 1], x_inv) == 0) {
            if (found >= num_errors) return error.Uncorrectable;
            positions[found] = p;
            found += 1;
        }
    }
    if (found != num_errors) return error.Uncorrectable; // locator didn't split

    // -- omega(x) = (S(x) * lambda(x)) mod x^ec_count ------------------------
    var omega = [_]u8{0} ** max_ec_per_block;
    for (0..ec_count) |i| {
        var acc: u8 = 0;
        for (0..i + 1) |k| acc ^= gf.mul(lambda[k], syn[i - k]);
        omega[i] = acc;
    }

    // -- Forney: magnitude e = X * omega(X^-1) / lambda'(X^-1) ---------------
    // X = alpha^p is the error locator; the leading X factor comes from QR's
    // generator starting at root alpha^0 (first syndrome S_0 = R(alpha^0)).
    for (positions[0..found]) |p| {
        const x = gf.expOf(p % 255); // alpha^p
        const x_inv = gf.expOf((255 - (p % 255)) % 255); // alpha^-p
        const numer = polyEvalLow(omega[0..ec_count], x_inv);
        // Formal derivative keeps only odd-index terms (even ones vanish in GF(2)).
        var denom: u8 = 0;
        var i: usize = 1;
        while (i <= num_errors) : (i += 2) denom ^= gf.mul(lambda[i], powGf(x_inv, i - 1));
        if (denom == 0) return error.Uncorrectable;
        block[block.len - 1 - p] ^= gf.mul(x, gf.div(numer, denom));
    }

    // -- verify: a corrected codeword must have all-zero syndromes -----------
    for (0..ec_count) |j| {
        if (polyEvalHigh(block, gf.expOf(j)) != 0) return error.Uncorrectable;
    }
    return found;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "generator polynomial small cases (high-first, leading coeff 1)" {
    // (x + alpha^0) = x + 1  -> {1, 1}
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1 }, &generatorPoly(1));
    // degree 2 generator: x^2 + alpha^25 x + alpha^1 = x^2 + 3x + 2 -> {1, 3, 2}
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 2 }, &generatorPoly(2));
    // The leading coefficient is always 1.
    try std.testing.expectEqual(@as(u8, 1), generatorPoly(10)[0]);
    try std.testing.expectEqual(@as(u8, 1), generatorPoly(30)[0]);
}

/// Independent polynomial long division (high-first) used to verify that the
/// encoded codeword is divisible by the generator — a different algorithm than
/// `encode`, so agreement is strong evidence of correctness.
fn remainderByLongDivision(
    comptime ec_count: usize,
    codeword: []const u8,
    out: *[ec_count]u8,
) void {
    const gen = generatorPoly(ec_count);
    var buf: [256]u8 = undefined;
    std.debug.assert(codeword.len <= buf.len);
    @memcpy(buf[0..codeword.len], codeword);

    var i: usize = 0;
    while (i + ec_count < codeword.len) : (i += 1) {
        const coef = buf[i];
        if (coef == 0) continue;
        var j: usize = 0;
        while (j <= ec_count) : (j += 1) {
            buf[i + j] ^= gf.mul(gen[j], coef);
        }
    }
    @memcpy(out, buf[codeword.len - ec_count ..][0..ec_count]);
}

test "runtime RS matches the comptime implementation" {
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17 };
    inline for (.{ 7, 10, 13, 18, 26 }) |n| {
        const expected = encodeAlloc(n, &data);
        var got: [n]u8 = undefined;
        encodeRuntime(n, &data, &got);
        try std.testing.expectEqualSlices(u8, &expected, &got);
    }
}

test "interleave yields the full codeword count for a two-group version" {
    const a = std.testing.allocator;
    const s = tables.blockStructure(5, .q); // v5-Q has two block groups
    const data = try a.alloc(u8, s.dataCodewords());
    defer a.free(data);
    for (data, 0..) |*d, i| d.* = @intCast(i % 256);

    const inter = try interleaveCodewords(a, data, 5, .q);
    defer a.free(inter);
    try std.testing.expectEqual(@as(usize, tables.total_codewords[4]), inter.len);
}

/// Build a valid systematic codeword (`data ++ ec`) for `ec_count` EC bytes.
fn buildCodeword(comptime ec_count: usize, data: []const u8, out: []u8) void {
    std.debug.assert(out.len == data.len + ec_count);
    @memcpy(out[0..data.len], data);
    var ec: [ec_count]u8 = undefined;
    encodeRuntime(ec_count, data, &ec);
    @memcpy(out[data.len..], &ec);
}

test "decodeBlock leaves a clean codeword untouched" {
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17 };
    inline for (.{ 7, 10, 13, 18, 26 }) |ec| {
        var block: [data.len + ec]u8 = undefined;
        buildCodeword(ec, &data, &block);
        const original = block;
        try std.testing.expectEqual(@as(usize, 0), try decodeBlock(&block, ec));
        try std.testing.expectEqualSlices(u8, &original, &block); // unchanged
    }
}

test "decodeBlock corrects up to ec/2 errors and reports the count" {
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17 };
    inline for (.{ 7, 10, 13, 18, 26 }) |ec| {
        var clean: [data.len + ec]u8 = undefined;
        buildCodeword(ec, &data, &clean);

        const t = ec / 2;
        var ne: usize = 1;
        while (ne <= t) : (ne += 1) {
            var block = clean;
            // Corrupt `ne` distinct positions (spread by 7) with nonzero deltas;
            // positions cover both the data and EC regions of the block.
            for (0..ne) |i| {
                const pos = (i * 7 + 1) % block.len;
                block[pos] ^= @as(u8, @truncate(i * 31 + 1)); // nonzero in range
            }
            const corrected = try decodeBlock(&block, ec);
            try std.testing.expectEqual(ne, corrected);
            try std.testing.expectEqualSlices(u8, &clean, &block); // fully recovered
        }
    }
}

test "decodeBlock never silently restores the original beyond capacity" {
    // With more than ec/2 errors the decoder must either report Uncorrectable or
    // converge on some *other* codeword — it must never hand back the original
    // (that would be an undetected miscorrection of an over-capacity block).
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17 };
    inline for (.{ 10, 18, 26 }) |ec| {
        var clean: [data.len + ec]u8 = undefined;
        buildCodeword(ec, &data, &clean);

        var block = clean;
        const ne = ec / 2 + 1; // one past the correction limit
        for (0..ne) |i| {
            const pos = (i * 7 + 1) % block.len;
            block[pos] ^= @as(u8, @truncate(i * 31 + 1));
        }
        if (decodeBlock(&block, ec)) |_| {
            try std.testing.expect(!std.mem.eql(u8, &clean, &block));
        } else |err| {
            try std.testing.expectEqual(DecodeError.Uncorrectable, err);
        }
    }
}

test "decodeBlock corrects a single error at every position" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const ec = 16;
    var clean: [data.len + ec]u8 = undefined;
    buildCodeword(ec, &data, &clean);

    for (0..clean.len) |pos| {
        var block = clean;
        block[pos] ^= 0xA5; // a single nonzero error
        try std.testing.expectEqual(@as(usize, 1), try decodeBlock(&block, ec));
        try std.testing.expectEqualSlices(u8, &clean, &block);
    }
}

test "encoded codeword is divisible by the generator" {
    const cases = [_][]const u8{
        &[_]u8{ 0x12, 0x34 },
        &[_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17 },
        &[_]u8{ 0, 0, 0, 1 },
        &[_]u8{255} ** 20,
    };
    inline for (.{ 7, 10, 13, 17 }) |ec_count| {
        for (cases) |data| {
            const ec = encodeAlloc(ec_count, data);

            // The full codeword = data ++ ec must have zero remainder.
            var codeword: [256]u8 = undefined;
            @memcpy(codeword[0..data.len], data);
            @memcpy(codeword[data.len..][0..ec_count], &ec);

            var rem: [ec_count]u8 = undefined;
            remainderByLongDivision(ec_count, codeword[0 .. data.len + ec_count], &rem);
            try std.testing.expectEqualSlices(u8, &[_]u8{0} ** ec_count, &rem);
        }
    }
}

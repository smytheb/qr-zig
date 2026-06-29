//! Terminal renderer using Unicode half-block characters: two vertical modules
//! per character cell, so the code comes out roughly square and scannable.
//!
//! By default it emits an ANSI black-on-white color pair so the result scans
//! regardless of the terminal's theme (dark modules render black, light modules
//! and the quiet zone render white). `.invert = true` produces the photographic
//! negative (white modules on a dark quiet zone) for dark-themed displays.
//!
//! A QR side length is always odd, so `size + 2*quiet` is odd and the half-block
//! pairing cannot align both vertical edges to full cells. We add one row of
//! quiet padding on top so the *bottom* edge lands on a full cell (crisp), while
//! the blank top/bottom margins stay symmetric.

const std = @import("std");
const Matrix = @import("../qr/matrix.zig").Matrix;

pub const Options = struct {
    quiet: usize = 4,
    color: bool = true,
    invert: bool = false,
};

const upper_half = "\u{2580}"; // ▀
const lower_half = "\u{2584}"; // ▄
const full_block = "\u{2588}"; // █
const space = " ";

const set_black_on_white = "\x1b[30;47m";
const reset = "\x1b[0m";

/// Dark/light for a logical base-grid coordinate (origin at the top-left of the
/// quiet zone). `lrow` may be negative to denote the top padding row.
fn cellDark(m: *const Matrix, opts: Options, lrow: isize, lcol: usize) bool {
    if (lrow < 0) return opts.invert; // top padding row == quiet
    const row: usize = @intCast(lrow);
    const in_quiet = row < opts.quiet or lcol < opts.quiet or
        row >= opts.quiet + m.size or lcol >= opts.quiet + m.size;
    if (in_quiet) return opts.invert;
    return m.get(lcol - opts.quiet, row - opts.quiet) != opts.invert;
}

pub fn render(writer: *std.Io.Writer, m: *const Matrix, opts: Options) !void {
    const base = m.size + 2 * opts.quiet;
    const top_pad: usize = base % 2; // 1 when base is odd, else 0
    const full = base + top_pad;
    const pad: isize = @intCast(top_pad);

    var grid_row: usize = 0;
    while (grid_row < full) : (grid_row += 2) {
        if (opts.color) try writer.writeAll(set_black_on_white);
        var col: usize = 0;
        while (col < base) : (col += 1) {
            const top = cellDark(m, opts, @as(isize, @intCast(grid_row)) - pad, col);
            const bottom = cellDark(m, opts, @as(isize, @intCast(grid_row + 1)) - pad, col);
            // With fg=black, bg=white: the glyph's "on" half is drawn black.
            const glyph = if (top and bottom)
                full_block
            else if (top)
                upper_half
            else if (bottom)
                lower_half
            else
                space;
            try writer.writeAll(glyph);
        }
        if (opts.color) try writer.writeAll(reset);
        try writer.writeByte('\n');
    }
}

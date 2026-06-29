//! Plain ASCII renderer: one character per module, with a configurable quiet
//! zone. Useful for piping/debugging and for diffing against reference encoders.

const std = @import("std");
const Matrix = @import("../qr/matrix.zig").Matrix;

pub const Options = struct {
    /// Quiet-zone width in modules on every side.
    quiet: usize = 4,
    /// Character drawn for dark modules.
    dark: u8 = '#',
    /// Character drawn for light modules.
    light: u8 = ' ',
};

/// Render `m` to `writer` as rows of characters terminated by '\n'.
pub fn render(writer: *std.Io.Writer, m: *const Matrix, opts: Options) !void {
    const full = m.size + 2 * opts.quiet;
    var row: usize = 0;
    while (row < full) : (row += 1) {
        var col: usize = 0;
        while (col < full) : (col += 1) {
            const in_quiet = row < opts.quiet or col < opts.quiet or
                row >= opts.quiet + m.size or col >= opts.quiet + m.size;
            const dark = !in_quiet and m.get(col - opts.quiet, row - opts.quiet);
            try writer.writeByte(if (dark) opts.dark else opts.light);
        }
        try writer.writeByte('\n');
    }
}

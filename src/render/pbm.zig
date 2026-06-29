//! Netpbm PBM (P1, ASCII bitmap) renderer. In PBM a `1` sample is black, so dark
//! modules map to `1` and light modules / the quiet zone map to `0`. Each module
//! is expanded to `scale x scale` pixels.

const std = @import("std");
const Matrix = @import("../qr/matrix.zig").Matrix;

pub const Options = struct {
    quiet: usize = 4,
    scale: usize = 1,
};

fn moduleDark(m: *const Matrix, quiet: usize, mx: usize, my: usize) bool {
    const in_quiet = mx < quiet or my < quiet or mx >= quiet + m.size or my >= quiet + m.size;
    if (in_quiet) return false;
    return m.get(mx - quiet, my - quiet);
}

pub fn render(writer: *std.Io.Writer, m: *const Matrix, opts: Options) !void {
    const modules = m.size + 2 * opts.quiet;
    const n = modules * opts.scale;

    try writer.print("P1\n{d} {d}\n", .{ n, n });

    var ry: usize = 0;
    while (ry < n) : (ry += 1) {
        const my = ry / opts.scale;
        var rx: usize = 0;
        while (rx < n) : (rx += 1) {
            const mx = rx / opts.scale;
            try writer.writeByte(if (moduleDark(m, opts.quiet, mx, my)) '1' else '0');
        }
        try writer.writeByte('\n');
    }
}

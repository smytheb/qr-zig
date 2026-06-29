//! SVG renderer: a white background plus one black `<rect>` per horizontal run
//! of dark modules (runs are merged to keep the file small). Crisp at any size.

const std = @import("std");
const Matrix = @import("../qr/matrix.zig").Matrix;

pub const Options = struct {
    quiet: usize = 4,
    /// Pixel size of one module in the rendered `width`/`height`. The internal
    /// coordinate system stays in module units via `viewBox`.
    scale: usize = 8,
};

pub fn render(writer: *std.Io.Writer, m: *const Matrix, opts: Options) !void {
    const n = m.size + 2 * opts.quiet;
    const px = n * opts.scale;

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" " ++
            "viewBox=\"0 0 {d} {d}\" shape-rendering=\"crispEdges\">\n",
        .{ px, px, n, n },
    );
    try writer.print("<rect width=\"{d}\" height=\"{d}\" fill=\"#ffffff\"/>\n", .{ n, n });

    var y: usize = 0;
    while (y < m.size) : (y += 1) {
        var x: usize = 0;
        while (x < m.size) {
            if (!m.get(x, y)) {
                x += 1;
                continue;
            }
            const start = x;
            while (x < m.size and m.get(x, y)) x += 1;
            try writer.print(
                "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"1\" fill=\"#000000\"/>\n",
                .{ start + opts.quiet, y + opts.quiet, x - start },
            );
        }
    }

    try writer.writeAll("</svg>\n");
}

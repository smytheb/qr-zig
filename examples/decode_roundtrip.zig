//! Encode text, render it, then decode it back — the full round trip through
//! the `qr` library.
//!
//!   zig build examples
//!
//! Imports the published `qr` module just like a downstream project would.

const std = @import("std");
const qr = @import("qr");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const text = "Hello, Zig!";

    // 1. Encode into a masked QR matrix.
    var code = try qr.generate(allocator, text, .m, .auto);
    defer code.deinit();

    // 2. Render it to an in-memory ASCII grid ('#' = dark, ' ' = light).
    var grid: std.Io.Writer.Allocating = .init(allocator);
    defer grid.deinit();
    try qr.render.ascii.render(&grid.writer, &code.matrix, .{ .quiet = 2 });

    // 3. Parse the rendering back into a matrix (format auto-detected) and
    //    decode it, recovering the original text via Reed-Solomon correction.
    var parsed = try qr.matrix_input.parse(allocator, grid.written());
    defer parsed.deinit();
    const decoded = try qr.decode.decodeMatrix(allocator, &parsed);

    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    try out.print("encoded:  {s}\n", .{text});
    try out.print("decoded:  {s}  (v{d}, level {s}, mask {d})\n", .{
        decoded.text, decoded.version, @tagName(decoded.level), decoded.mask,
    });
    try out.flush();
}

//! Encode text into a QR code and render it as SVG to stdout.
//!
//!   zig build examples          # builds and runs every example
//!
//! This file imports the published `qr` module exactly as a downstream project
//! would (`@import("qr")`), so it doubles as a consumer smoke test.

const std = @import("std");
const qr = @import("qr");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    // Encode into a masked QR matrix: error-correction level M, ECI auto
    // (UTF-8 is declared automatically for non-ASCII input).
    var code = try qr.generate(allocator, "https://ziglang.org", .m, .auto);
    // `deinit` frees the matrix; with this arena it is a no-op, but a consumer
    // using a general-purpose allocator needs it.
    defer code.deinit();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    // Every renderer takes `(writer, &matrix, options)`.
    try qr.render.svg.render(out, &code.matrix, .{ .quiet = 4, .scale = 8 });
    try out.flush();
}

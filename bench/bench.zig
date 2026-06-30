//! Micro-benchmarks for the `qr` library: encode and decode throughput.
//!
//!   zig build bench        # forces ReleaseFast for meaningful numbers
//!
//! Each measurement loops over a fixed payload, reusing a single arena that is
//! reset (retaining capacity) every iteration so the allocator is not the
//! bottleneck and memory stays bounded. Encode is text -> masked matrix;
//! decode is the realistic `qr decode` path: parse a rendered symbol back into
//! a matrix, then recover the text (with Reed-Solomon correction).

const std = @import("std");
const qr = @import("qr");

const payloads = [_][]const u8{
    "HELLO", // alphanumeric, tiniest symbol
    "https://ziglang.org/learn/overview/", // byte mode, a typical URL
};

const encode_iters: usize = 50_000;
const decode_iters: usize = 20_000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Long-lived allocations (rendered symbols we decode from) live here.
    const keep = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;

    // Hot-loop scratch: reset every iteration so allocation cost is amortized.
    var work = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer work.deinit();
    const scratch = work.allocator();

    try out.print("qr micro-benchmark — ReleaseFast, single-threaded\n", .{});
    try out.print("encode = text -> matrix; decode = rendered symbol -> text (RS-corrected)\n\n", .{});
    try out.print("{s:<38}{s:>6}{s:>5}{s:>16}{s:>16}\n", .{ "payload", "bytes", "ver", "encode/code", "decode/code" });

    for (payloads) |p| {
        // Capture the version and a rendered symbol to decode from.
        var g0 = try qr.generate(keep, p, .m, .auto);
        const version = g0.version;
        var grid: std.Io.Writer.Allocating = .init(keep);
        try qr.render.ascii.render(&grid.writer, &g0.matrix, .{ .quiet = 2 });
        const rendering = grid.written();
        g0.deinit();

        const enc_ns = try benchEncode(io, scratch, &work, p);
        const dec_ns = try benchDecode(io, scratch, &work, rendering);

        try out.print("{s:<38}{d:>6}{s:>4}{d:<1}{d:>13.2} µs{d:>13.2} µs\n", .{
            p, p.len, "v", version, perOp(enc_ns, encode_iters), perOp(dec_ns, decode_iters),
        });
    }

    try out.flush();
}

fn benchEncode(io: std.Io, scratch: std.mem.Allocator, work: *std.heap.ArenaAllocator, payload: []const u8) !u64 {
    // Warm up (page faults, branch predictors) before timing.
    _ = work.reset(.retain_capacity);
    std.mem.doNotOptimizeAway(try qr.generate(scratch, payload, .m, .auto));

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var i: usize = 0;
    while (i < encode_iters) : (i += 1) {
        _ = work.reset(.retain_capacity);
        std.mem.doNotOptimizeAway(try qr.generate(scratch, payload, .m, .auto));
    }
    return elapsedNs(io, start);
}

fn benchDecode(io: std.Io, scratch: std.mem.Allocator, work: *std.heap.ArenaAllocator, rendering: []const u8) !u64 {
    _ = work.reset(.retain_capacity);
    {
        var m = try qr.matrix_input.parse(scratch, rendering);
        std.mem.doNotOptimizeAway(try qr.decode.decodeMatrix(scratch, &m));
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var i: usize = 0;
    while (i < decode_iters) : (i += 1) {
        _ = work.reset(.retain_capacity);
        var m = try qr.matrix_input.parse(scratch, rendering);
        std.mem.doNotOptimizeAway(try qr.decode.decodeMatrix(scratch, &m));
    }
    return elapsedNs(io, start);
}

/// Nanoseconds elapsed on the monotonic (`awake`) clock since `start`.
fn elapsedNs(io: std.Io, start: std.Io.Clock.Timestamp) u64 {
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return @intCast(start.durationTo(end).raw.nanoseconds);
}

/// Nanoseconds total -> microseconds per operation.
fn perOp(total_ns: u64, iters: usize) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters)) / 1000.0;
}

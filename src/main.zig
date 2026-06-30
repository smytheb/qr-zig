//! `qr` — a lightweight, dependency-free QR code generator for the terminal.

const std = @import("std");
const qr = @import("qr");
const render = qr.render;
const decode = qr.decode;
const matrix_input = qr.matrix_input;

const Format = enum { terminal, ascii, svg, pbm, png };

const usage =
    \\qr — generate QR codes on the command line
    \\
    \\USAGE:
    \\    qr <command> [options]
    \\
    \\COMMANDS:
    \\    gen [text]      Generate a QR code (reads stdin if text is omitted or "-")
    \\    decode [file]   Decode a QR code (ascii/pbm/png, auto-detected; reads stdin if omitted)
    \\    info            Print supported version capacities
    \\    help            Show this help
    \\    version         Show version
    \\
    \\GEN OPTIONS:
    \\    --ec L|M|Q|H        Error-correction level (default M)
    \\    --mask N            Force mask 0-7 (default: auto-select)
    \\    --format F          terminal | ascii | svg | pbm | png (default terminal)
    \\    -o, --out FILE      Write to FILE instead of stdout
    \\    --quiet N           Quiet-zone width in modules (default 4)
    \\    --scale N           Pixel/cell size per module for svg/png/pbm (default 8/8/1)
    \\    --invert            Photo-negative (terminal/ascii) for dark displays
    \\    --utf8              Declare ECI 26 (UTF-8)
    \\    --eci N             Declare an explicit ECI assignment number
    \\    --no-eci            Never declare ECI (default: auto for non-ASCII input)
    \\
    \\OUTPUT FORMATS:
    \\    terminal   Unicode half-blocks; scannable in any terminal theme.
    \\    svg, pbm, png  Scannable image files (use shell redirection or -o).
    \\    ascii      One '#'/space per module — for piping/debugging. Not
    \\               reliably scannable (text cells aren't square).
    \\
    \\DECODE OPTIONS:
    \\    -v, --verbose   Also print version/level/mask/eci to stderr
    \\    (decode reads ascii / pbm / png, auto-detected from the input)
    \\
    \\EXAMPLES:
    \\    qr gen "https://ziglang.org"
    \\    echo -n "https://ziglang.org" | qr gen
    \\    qr gen "hi" --format svg -o code.svg
    \\    qr gen "hi" --format ascii | qr decode
    \\
;

const version_string = "qr 0.2.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len >= 2) args[1] else "help";

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h"))
    {
        try out.writeAll(usage);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try out.writeAll(version_string ++ "\n");
    } else if (std.mem.eql(u8, command, "info")) {
        try printInfo(out);
    } else if (std.mem.eql(u8, command, "gen")) {
        runGen(io, arena, out, args[2..]) catch |err| {
            out.flush() catch {};
            reportError(io, err); // prints a message and exits(1)
        };
    } else if (std.mem.eql(u8, command, "decode")) {
        runDecode(io, arena, out, args[2..]) catch |err| {
            out.flush() catch {};
            reportError(io, err);
        };
    } else if (std.mem.eql(u8, command, "segments")) {
        runSegments(arena, out, args[2..]) catch |err| {
            out.flush() catch {};
            reportError(io, err);
        };
    } else {
        try out.print("unknown command: {s}\n\n", .{command});
        try out.writeAll(usage);
    }

    try out.flush();
}

/// Print a user-facing message for a gen/decode failure and exit non-zero,
/// without dumping Zig's error-return trace.
fn reportError(io: std.Io, err: anyerror) noreturn {
    const msg = switch (err) {
        error.MissingText => "error: no input (pass an argument or pipe via stdin)\n",
        error.BadArg => "error: invalid argument (see `qr help`)\n",
        error.DataTooLong => std.fmt.comptimePrint(
            "error: input too long for supported versions (max v{d})\n",
            .{qr.tables.max_version},
        ),
        error.FileNotFound, error.AccessDenied => "error: cannot open file\n",
        error.BadInput => "error: input is not a recognizable QR code (ascii/pbm/png)\n",
        error.BadFormat => "error: could not read the format information (symbol too damaged?)\n",
        error.Uncorrectable => "error: too many errors to decode (symbol too damaged)\n",
        error.MalformedData => "error: decoded data is malformed\n",
        else => "error: operation failed\n",
    };
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &err_buf);
    err_writer.interface.writeAll(msg) catch {};
    err_writer.interface.flush() catch {};
    std.process.exit(1);
}

const Options = struct {
    level: qr.EcLevel = .m,
    forced_mask: ?u3 = null,
    format: Format = .terminal,
    quiet: usize = 4,
    scale: ?usize = null,
    invert: bool = false,
    output: ?[]const u8 = null,
    text: ?[]const u8 = null,
    eci: qr.Eci = .auto,
};

fn runGen(io: std.Io, allocator: std.mem.Allocator, out: *std.Io.Writer, gen_args: []const [:0]const u8) !void {
    var opts: Options = .{};

    var i: usize = 0;
    while (i < gen_args.len) : (i += 1) {
        const arg = gen_args[i];
        if (std.mem.eql(u8, arg, "--ec")) {
            opts.level = try parseEcArg(gen_args, &i);
        } else if (std.mem.eql(u8, arg, "--mask")) {
            const n = std.fmt.parseInt(u8, try nextArg(gen_args, &i), 10) catch return error.BadArg;
            if (n > 7) return error.BadArg;
            opts.forced_mask = @intCast(n);
        } else if (std.mem.eql(u8, arg, "--format")) {
            opts.format = std.meta.stringToEnum(Format, try nextArg(gen_args, &i)) orelse return error.BadArg;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            opts.output = try nextArg(gen_args, &i);
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = std.fmt.parseInt(usize, try nextArg(gen_args, &i), 10) catch return error.BadArg;
        } else if (std.mem.eql(u8, arg, "--scale")) {
            opts.scale = std.fmt.parseInt(usize, try nextArg(gen_args, &i), 10) catch return error.BadArg;
        } else if (std.mem.eql(u8, arg, "--invert")) {
            opts.invert = true;
        } else if (std.mem.eql(u8, arg, "--utf8")) {
            opts.eci = .{ .value = qr.encode.eci_utf8 };
        } else if (std.mem.eql(u8, arg, "--eci")) {
            opts.eci = .{ .value = std.fmt.parseInt(u32, try nextArg(gen_args, &i), 10) catch return error.BadArg };
        } else if (std.mem.eql(u8, arg, "--no-eci")) {
            opts.eci = .none;
        } else if (std.mem.startsWith(u8, arg, "--") and arg.len > 1) {
            return error.BadArg;
        } else {
            opts.text = arg;
        }
    }

    const text = try resolveText(io, allocator, opts.text);
    if (text.len == 0) return error.MissingText;

    var g = if (opts.forced_mask) |fm|
        try qr.generateWithMask(allocator, text, opts.level, fm, opts.eci)
    else
        try qr.generate(allocator, text, opts.level, opts.eci);
    defer g.deinit();

    if (opts.output) |path| {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var file_buf: [8192]u8 = undefined;
        var file_writer = file.writer(io, &file_buf);
        try renderMatrix(allocator, &file_writer.interface, &g.matrix, opts);
        try file_writer.interface.flush();
    } else {
        try renderMatrix(allocator, out, &g.matrix, opts);
    }
}

/// Advance `i` to the next argument and return it, or error if missing.
fn nextArg(args: []const [:0]const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.BadArg;
    return args[i.*];
}

/// Parse the value of an `--ec` flag (the argument after `i`) into an EC level.
fn parseEcArg(args: []const [:0]const u8, i: *usize) !qr.EcLevel {
    return qr.tables.EcLevel.fromChar((try nextArg(args, i))[0]) orelse error.BadArg;
}

/// Read all of stdin into an allocator-owned buffer (max 1 MiB).
fn readAllStdin(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}

/// Use the positional argument, or read stdin when it is absent or "-".
fn resolveText(io: std.Io, allocator: std.mem.Allocator, arg: ?[]const u8) ![]const u8 {
    if (arg) |a| {
        if (!std.mem.eql(u8, a, "-")) return a;
    } else if (try std.Io.File.stdin().isTty(io)) {
        // Avoid blocking on an interactive terminal with no piped input.
        return error.MissingText;
    }
    return std.mem.trimEnd(u8, try readAllStdin(io, allocator), " \t\r\n");
}

/// Decode a QR code from an ascii rendering read from `arg` (a file path), or
/// from stdin when `arg` is absent or "-".
fn runDecode(io: std.Io, allocator: std.mem.Allocator, out: *std.Io.Writer, args: []const [:0]const u8) !void {
    var input: ?[]const u8 = null;
    var verbose = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--") and arg.len > 1) {
            return error.BadArg;
        } else {
            input = arg; // file path, or "-" for stdin
        }
    }

    const data = try resolveDecodeInput(io, allocator, input);
    var m = try matrix_input.parse(allocator, data);
    defer m.deinit();
    const dec = try decode.decodeMatrix(allocator, &m);

    try out.writeAll(dec.text);
    try out.writeByte('\n');
    if (verbose) try printDecodeInfo(io, dec);
}

/// Read a file (path != "-") or stdin into a buffer for decoding.
fn resolveDecodeInput(io: std.Io, allocator: std.mem.Allocator, arg: ?[]const u8) ![]const u8 {
    if (arg) |a| {
        if (!std.mem.eql(u8, a, "-")) {
            var file = try std.Io.Dir.cwd().openFile(io, a, .{});
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            var fr = file.reader(io, &buf);
            return fr.interface.allocRemaining(allocator, .limited(1 << 20));
        }
    } else if (try std.Io.File.stdin().isTty(io)) {
        return error.MissingText;
    }
    return readAllStdin(io, allocator);
}

/// Print decoded metadata to stderr, keeping stdout to just the payload.
fn printDecodeInfo(io: std.Io, dec: decode.Decoded) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    const e = &w.interface;
    try e.print("version {d}, level {s}, mask {d}", .{ dec.version, @tagName(dec.level), dec.mask });
    if (dec.eci) |n| try e.print(", eci {d}", .{n});
    try e.writeByte('\n');
    try e.flush();
}

fn renderMatrix(allocator: std.mem.Allocator, w: *std.Io.Writer, m: *const qr.Matrix, opts: Options) !void {
    switch (opts.format) {
        .terminal => try render.terminal.render(w, m, .{ .quiet = opts.quiet, .invert = opts.invert }),
        .ascii => try render.ascii.render(w, m, .{
            .quiet = opts.quiet,
            .dark = if (opts.invert) ' ' else '#',
            .light = if (opts.invert) '#' else ' ',
        }),
        .svg => try render.svg.render(w, m, .{ .quiet = opts.quiet, .scale = opts.scale orelse 8 }),
        .pbm => try render.pbm.render(w, m, .{ .quiet = opts.quiet, .scale = opts.scale orelse 1 }),
        .png => try render.png.render(allocator, w, m, .{ .quiet = opts.quiet, .scale = opts.scale orelse 8 }),
    }
}

/// Debug helper: print the chosen version and the optimal mixed-mode
/// segmentation as `<mode> <start> <len>` lines. Used by the validation harness.
fn runSegments(allocator: std.mem.Allocator, out: *std.Io.Writer, gen_args: []const [:0]const u8) !void {
    var text: ?[]const u8 = null;
    var level: qr.EcLevel = .m;
    var i: usize = 0;
    while (i < gen_args.len) : (i += 1) {
        if (std.mem.eql(u8, gen_args[i], "--ec")) {
            level = try parseEcArg(gen_args, &i);
        } else {
            text = gen_args[i];
        }
    }
    const t = text orelse return error.MissingText;
    const version = try qr.encode.chooseVersion(allocator, t, level, .auto);
    const segments = try qr.segment.optimalSegments(allocator, t, version);
    defer allocator.free(segments);

    try out.print("version {d}\n", .{version});
    for (segments) |s| {
        try out.print("{s} {d} {d}\n", .{ @tagName(s.mode), s.start, s.len });
    }
}

fn printInfo(out: *std.Io.Writer) !void {
    try out.writeAll("Supported versions (data codewords / capacity in bytes per EC level)\n\n");
    try out.writeAll("ver  size      L     M     Q     H\n");
    var v: u8 = qr.tables.min_version;
    while (v <= qr.tables.max_version) : (v += 1) {
        const size = 17 + 4 * @as(usize, v);
        try out.print("{d:>3}  {d:>2}x{d:<2}", .{ v, size, size });
        for ([_]qr.EcLevel{ .l, .m, .q, .h }) |level| {
            const cap = qr.tables.blockStructure(v, level).dataCodewords();
            // Usable bytes = capacity minus mode(4) + count(8/16) header, /8.
            const header_bits: usize = 4 + qr.tables.byteModeCharCountBits(v);
            const bytes = (cap * 8 - header_bits) / 8;
            try out.print("  {d:>4}", .{bytes});
        }
        try out.writeByte('\n');
    }
}

// The library suite (qr/render/decode inline tests) runs via the separate
// `lib_tests` artifact rooted at src/root.zig; this file carries only the CLI's
// own integration tests.
test "renderers produce well-formed output for a known matrix" {
    const a = std.testing.allocator;
    var g = try qr.generateWithMask(a, "Hi!", .m, 0, .auto);
    defer g.deinit();

    var buf: [1 << 16]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        try render.ascii.render(&w, &g.matrix, .{ .quiet = 0, .dark = '#', .light = '.' });
        try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "#######.......#######\n"));
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try render.pbm.render(&w, &g.matrix, .{ .quiet = 1, .scale = 2 });
        try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "P1\n46 46\n"));
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try render.svg.render(&w, &g.matrix, .{ .quiet = 4, .scale = 8 });
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "viewBox=\"0 0 29 29\"") != null);
        try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "</svg>\n"));
    }
    {
        var w = std.Io.Writer.fixed(&buf);
        try render.terminal.render(&w, &g.matrix, .{ .quiet = 0, .color = false });
        try std.testing.expectEqual(@as(usize, 11), std.mem.count(u8, w.buffered(), "\n"));
    }
}

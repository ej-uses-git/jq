const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Writer = Io.Writer;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse fatal("-o requires an argument", .{});
        } else if (input_path != null) {
            fatal("unrecognized additional argument", .{});
        } else {
            input_path = arg;
        }
    }

    if (input_path == null) fatal("missing required positional argument: input", .{});

    const input = Dir.cwd().readFileAlloc(io, input_path.?, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}': {t}",
        .{ input_path.?, err },
    );

    var out_file: File = if (out_path) |path| Dir.cwd().createFile(io, path, .{}) catch |err| fatal(
        "failed to create '{s}': {t}",
        .{ path, err },
    ) else .stdout();
    defer if (out_path != null) out_file.close(io);
    var writer_buf: [1024]u8 = undefined;
    var out_writer = out_file.writer(io, &writer_buf);
    const w = &out_writer.interface;

    output(w, input) catch fatal("failed to write output: {t}", .{out_writer.err.?});
}

fn output(w: *Writer, input: []const u8) !void {
    for (input) |byte| {
        try w.print("0{o},", .{byte});
    }
    try w.flush();
}

fn usage() void {
    std.debug.print(
        \\Usage: {s} [-o file] <input>
        \\
        \\Write a file's bytes in a format that can be `#include`ed directly into
        \\a `char[]` block.
        \\
        \\Options:
        \\  -o <file>    Write output to file (default: stdout)
    , .{});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const std = @import("std");
pub const png = @import("png.zig");

pub const CliArgs = struct {
    png_path: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    show_help: bool = false,

    pub const ParseError = error{
        MissingValue,
        UnknownFlag,
        MissingRequiredArguments,
    };

    pub fn parse(args: []const []const u8) ParseError!CliArgs {
        var result = CliArgs{};
        var i: usize = 0;

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                result.show_help = true;
                return result;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--png")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                result.png_path = args[i];
            } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                result.json_path = args[i];
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                result.output_path = args[i];
            } else {
                return error.UnknownFlag;
            }
        }

        if (result.png_path == null or result.json_path == null) {
            return error.MissingRequiredArguments;
        }

        return result;
    }
};

pub fn printUsage(io: std.Io, program_name: []const u8) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\zurag - GBA Sprite & Asset converter for Zamgba
        \\
        \\Usage:
        \\  {s} --png <input.png> --json <input.json> [--output <output.zig>]
        \\  {s} -h | --help
        \\
        \\Options:
        \\  -p, --png <path>      Path to the input Indexed-color PNG sprite sheet (exported from Aseprite)
        \\  -j, --json <path>     Path to the input Aseprite JSON frame metadata
        \\  -o, --output <path>   Optional path to output generated Zig file (default: stdout)
        \\  -h, --help            Display this help message and exit
        \\
        \\Note:
        \\  Options can be specified in any order.
        \\
    , .{ program_name, program_name }) catch return;
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const program_name = if (args.len > 0) args[0] else "zurag";
    const cli_slice = if (args.len > 1) args[1..] else &[_][]const u8{};

    const parsed_args = CliArgs.parse(cli_slice) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                std.debug.print("Error: unknown command-line option.\n\n", .{});
            },
            error.MissingValue => {
                std.debug.print("Error: option requires a value.\n\n", .{});
            },
            error.MissingRequiredArguments => {
                std.debug.print("Error: missing required options (--png and --json must be specified).\n\n", .{});
            },
        }
        printUsage(init.io, program_name);
        std.process.exit(1);
    };

    if (parsed_args.show_help) {
        printUsage(init.io, program_name);
        std.process.exit(0);
    }

    const input_png_path = parsed_args.png_path.?;
    const input_json_path = parsed_args.json_path.?;
    const output_zig_path = parsed_args.output_path;

    _ = input_json_path;
    _ = output_zig_path;

    // Step 1: Open and validate input.png
    const png_data = std.Io.Dir.readFileAlloc(.cwd(), init.io, input_png_path, allocator, .unlimited) catch |err| {
        std.debug.print("Error: unable to read input image '{s}': {s}\n", .{ input_png_path, @errorName(err) });
        std.process.exit(1);
    };

    const header = png.parseHeader(png_data) catch |err| {
        switch (err) {
            error.NotIndexedColor => {
                std.debug.print("Error: '{s}' is not an indexed-color PNG.\nHint: in Aseprite, export using Sprite -> Color Mode -> Indexed.\n", .{input_png_path});
            },
            error.InvalidPngSignature, error.InvalidIhdrChunk, error.TruncatedHeader => {
                std.debug.print("Error: '{s}' is not a valid PNG file.\n", .{input_png_path});
            },
            error.UnsupportedBitDepth => {
                std.debug.print("Error: '{s}' has an unsupported bit depth.\n", .{input_png_path});
            },
        }
        std.process.exit(1);
    };

    std.debug.print("Validated indexed PNG: {s} ({}x{}, {}-bit indexed)\n", .{ input_png_path, header.width, header.height, header.bit_depth });
}

test "CliArgs parse in standard order" {
    const raw_args = [_][]const u8{ "--png", "test.png", "--json", "test.json", "--output", "out.zig" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("test.png", parsed.png_path.?);
    try std.testing.expectEqualStrings("test.json", parsed.json_path.?);
    try std.testing.expectEqualStrings("out.zig", parsed.output_path.?);
    try std.testing.expect(!parsed.show_help);
}

test "CliArgs parse without optional --output" {
    const raw_args = [_][]const u8{ "--png", "test.png", "--json", "test.json" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("test.png", parsed.png_path.?);
    try std.testing.expectEqualStrings("test.json", parsed.json_path.?);
    try std.testing.expect(parsed.output_path == null);
}

test "CliArgs parse in reordered order with short flags" {
    const raw_args = [_][]const u8{ "-o", "gen.zig", "-j", "data.json", "-p", "sprite.png" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("sprite.png", parsed.png_path.?);
    try std.testing.expectEqualStrings("data.json", parsed.json_path.?);
    try std.testing.expectEqualStrings("gen.zig", parsed.output_path.?);
}

test "CliArgs parse help flag" {
    const raw_args_long = [_][]const u8{"--help"};
    const parsed_long = try CliArgs.parse(&raw_args_long);
    try std.testing.expect(parsed_long.show_help);

    const raw_args_short = [_][]const u8{"-h"};
    const parsed_short = try CliArgs.parse(&raw_args_short);
    try std.testing.expect(parsed_short.show_help);
}

test "CliArgs parse missing value and missing args" {
    const missing_val = [_][]const u8{ "--png", "test.png", "--json" };
    try std.testing.expectError(error.MissingValue, CliArgs.parse(&missing_val));

    const incomplete = [_][]const u8{ "--png", "test.png" };
    try std.testing.expectError(error.MissingRequiredArguments, CliArgs.parse(&incomplete));

    const unknown = [_][]const u8{ "--invalid", "foo" };
    try std.testing.expectError(error.UnknownFlag, CliArgs.parse(&unknown));
}

test {
    _ = png;
}

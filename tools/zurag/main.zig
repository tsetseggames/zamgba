const std = @import("std");
const png = @import("png.zig");
const tile = @import("tile.zig");
pub const metadata = @import("metadata.zig");

pub const BppMode = enum {
    bpp4,
    bpp4x16,
    bpp8,
    auto,

    pub fn fromString(str: []const u8) ?BppMode {
        if (std.mem.eql(u8, str, "4")) return .bpp4;
        if (std.mem.eql(u8, str, "4x16")) return .bpp4x16;
        if (std.mem.eql(u8, str, "8")) return .bpp8;
        if (std.mem.eql(u8, str, "auto")) return .auto;
        return null;
    }
};

const CliArgs = struct {
    png_path: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    bpp: BppMode = .auto,
    palette_only: bool = false,
    color_adjust: bool = false,
    show_help: bool = false,

    const ParseError = error{
        MissingValue,
        UnknownFlag,
        InvalidBppMode,
        MissingRequiredArguments,
    };

    fn parse(args: []const []const u8) ParseError!CliArgs {
        var result = CliArgs{};
        var i: usize = 0;

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                result.show_help = true;
                return result;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--color-adjust")) {
                result.color_adjust = true;
            } else if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--palette-only")) {
                result.palette_only = true;
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
            } else if (std.mem.eql(u8, arg, "--bpp")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                const mode = BppMode.fromString(args[i]) orelse return error.InvalidBppMode;
                result.bpp = mode;
            } else {
                return error.UnknownFlag;
            }
        }

        if (result.png_path == null) {
            return error.MissingRequiredArguments;
        }

        if (!result.palette_only and result.json_path == null) {
            return error.MissingRequiredArguments;
        }

        return result;
    }
};

fn printUsage(io: std.Io, program_name: []const u8) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\zurag - GBA Sprite & Asset converter for Zamgba
        \\
        \\Usage:
        \\  {s} --png <input.png> [--json <input.json>] [--output <output.zig>] [options]
        \\  {s} -h | --help
        \\
        \\Options:
        \\  -p, --png <path>        Path to input Indexed-color PNG sprite sheet (Required)
        \\  -j, --json <path>       Path to input Aseprite JSON frame metadata (Required unless --palette-only)
        \\  -o, --output <path>     Optional path to output generated Zig file (default: stdout)
        \\      --bpp <mode>        Bits-per-pixel mode: 4, 4x16, 8, auto (default: auto)
        \\  -c, --color-adjust      Enable full-range rounded RGB to GBA BGR555 scaling
        \\  -P, --palette-only      Extract palette data only (skips tiles, --json not required)
        \\  -h, --help              Display this help message and exit
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
            error.InvalidBppMode => {
                std.debug.print("Error: invalid --bpp mode. Expected '4', '4x16', '8', or 'auto'.\n\n", .{});
            },
            error.MissingRequiredArguments => {
                std.debug.print("Error: missing required options (--png is always required, --json is required unless --palette-only is set).\n\n", .{});
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
    const input_json_path = parsed_args.json_path;
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

    std.debug.print("Validated indexed PNG: {s} ({}x{}, {}-bit indexed, bpp: {s}, palette_only: {})\n", .{
        input_png_path,
        header.width,
        header.height,
        header.bit_depth,
        @tagName(parsed_args.bpp),
        parsed_args.palette_only,
    });

    if (!parsed_args.palette_only) {
        var img = png.decompressIndexedPixels(allocator, png_data) catch |err| {
            std.debug.print("Error: failed to decompress image data '{s}': {s}\n", .{ input_png_path, @errorName(err) });
            std.process.exit(1);
        };
        defer img.deinit();

        if (img.aux_chunks.has_trns) {
            std.debug.print("Warning: '{s}' contains a tRNS chunk which is ignored. GBA hardware enforces palette index 0 as transparent.\n", .{input_png_path});
        }
        if (img.aux_chunks.has_bkgd) {
            std.debug.print("Warning: '{s}' contains a bKGD chunk which is ignored.\n", .{input_png_path});
        }
    }
}

test "CliArgs parse in standard order with all options" {
    const raw_args = [_][]const u8{ "--png", "test.png", "--json", "test.json", "--output", "out.zig", "--bpp", "4" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("test.png", parsed.png_path.?);
    try std.testing.expectEqualStrings("test.json", parsed.json_path.?);
    try std.testing.expectEqualStrings("out.zig", parsed.output_path.?);
    try std.testing.expectEqual(BppMode.bpp4, parsed.bpp);
    try std.testing.expect(!parsed.palette_only);
    try std.testing.expect(!parsed.show_help);
}

test "CliArgs parse --color-adjust flag" {
    const raw_args_long = [_][]const u8{ "--png", "test.png", "--json", "test.json", "--color-adjust" };
    const parsed_long = try CliArgs.parse(&raw_args_long);
    try std.testing.expect(parsed_long.color_adjust);

    const raw_args_short = [_][]const u8{ "-p", "test.png", "-j", "test.json", "-c" };
    const parsed_short = try CliArgs.parse(&raw_args_short);
    try std.testing.expect(parsed_short.color_adjust);

    const raw_args_default = [_][]const u8{ "--png", "test.png", "--json", "test.json" };
    const parsed_default = try CliArgs.parse(&raw_args_default);
    try std.testing.expect(!parsed_default.color_adjust);
}

test "CliArgs default values" {
    const raw_args = [_][]const u8{ "--png", "test.png", "--json", "test.json" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("test.png", parsed.png_path.?);
    try std.testing.expectEqualStrings("test.json", parsed.json_path.?);
    try std.testing.expect(parsed.output_path == null);
    try std.testing.expectEqual(BppMode.auto, parsed.bpp);
    try std.testing.expect(!parsed.palette_only);
    try std.testing.expect(!parsed.show_help);
}

test "CliArgs parse --bpp modes" {
    const modes = [_]struct { str: []const u8, expected: BppMode }{
        .{ .str = "4", .expected = .bpp4 },
        .{ .str = "4x16", .expected = .bpp4x16 },
        .{ .str = "8", .expected = .bpp8 },
        .{ .str = "auto", .expected = .auto },
    };

    for (modes) |m| {
        const raw_args = [_][]const u8{ "--png", "test.png", "--json", "test.json", "--bpp", m.str };
        const parsed = try CliArgs.parse(&raw_args);
        try std.testing.expectEqual(m.expected, parsed.bpp);
    }
}

test "CliArgs reject invalid --bpp value" {
    const raw_args = [_][]const u8{ "--png", "test.png", "--json", "test.json", "--bpp", "16" };
    try std.testing.expectError(error.InvalidBppMode, CliArgs.parse(&raw_args));
}

test "CliArgs parse --palette-only without --json" {
    const raw_args = [_][]const u8{ "--png", "palette.png", "--palette-only", "--bpp", "4x16", "-o", "pal.zig" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("palette.png", parsed.png_path.?);
    try std.testing.expect(parsed.json_path == null);
    try std.testing.expectEqualStrings("pal.zig", parsed.output_path.?);
    try std.testing.expectEqual(BppMode.bpp4x16, parsed.bpp);
    try std.testing.expect(parsed.palette_only);
}

test "CliArgs parse reordered with short flags" {
    const raw_args = [_][]const u8{ "-P", "-o", "pal.zig", "-p", "sheet.png" };
    const parsed = try CliArgs.parse(&raw_args);
    try std.testing.expectEqualStrings("sheet.png", parsed.png_path.?);
    try std.testing.expect(parsed.palette_only);
    try std.testing.expectEqualStrings("pal.zig", parsed.output_path.?);
}

test "CliArgs parse help flag" {
    const raw_args_long = [_][]const u8{"--help"};
    const parsed_long = try CliArgs.parse(&raw_args_long);
    try std.testing.expect(parsed_long.show_help);

    const raw_args_short = [_][]const u8{"-h"};
    const parsed_short = try CliArgs.parse(&raw_args_short);
    try std.testing.expect(parsed_short.show_help);
}

test "CliArgs parse error conditions" {
    // Missing required png
    const no_png = [_][]const u8{ "--json", "test.json" };
    try std.testing.expectError(error.MissingRequiredArguments, CliArgs.parse(&no_png));

    // Missing required json when not palette-only
    const no_json = [_][]const u8{ "--png", "test.png" };
    try std.testing.expectError(error.MissingRequiredArguments, CliArgs.parse(&no_json));

    // Missing value
    const missing_val = [_][]const u8{ "--png", "test.png", "--bpp" };
    try std.testing.expectError(error.MissingValue, CliArgs.parse(&missing_val));

    // Unknown flag
    const unknown = [_][]const u8{ "--png", "test.png", "--json", "test.json", "--unknown" };
    try std.testing.expectError(error.UnknownFlag, CliArgs.parse(&unknown));
}

test {
    _ = png;
    _ = tile;
    _ = metadata;
    _ = @import("algo/paeth.zig");
    _ = @import("algo/unfilter.zig");
}

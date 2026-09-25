const std = @import("std");
const png = @import("png.zig");
const tile = @import("tile.zig");
pub const metadata = @import("metadata.zig");
pub const codegen = @import("codegen.zig");

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

pub const Subcommand = enum {
    sprite,
    tilemap,

    pub fn fromString(str: []const u8) ?Subcommand {
        if (std.mem.eql(u8, str, "sprite")) return .sprite;
        if (std.mem.eql(u8, str, "tilemap")) return .tilemap;
        return null;
    }
};

pub const SpriteFormat = enum {
    aseprite,

    pub fn fromString(str: []const u8) ?SpriteFormat {
        if (std.mem.eql(u8, str, "aseprite")) return .aseprite;
        return null;
    }
};

pub const TilemapFormat = enum {
    ldtk,

    pub fn fromString(str: []const u8) ?TilemapFormat {
        if (std.mem.eql(u8, str, "ldtk")) return .ldtk;
        return null;
    }
};

pub const SpriteCliArgs = struct {
    png_path: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    format: SpriteFormat = .aseprite,
    output_path: ?[]const u8 = null,
    bpp: BppMode = .auto,
    palette_only: bool = false,
    no_palette: bool = false,
    color_adjust: bool = false,
    show_help: bool = false,
};

pub const TilemapCliArgs = struct {
    input_path: ?[]const u8 = null,
    format: TilemapFormat = .ldtk,
    output_path: ?[]const u8 = null,
    bpp: BppMode = .bpp4,
    show_help: bool = false,
};

pub const ParsedCli = union(enum) {
    sprite: SpriteCliArgs,
    tilemap: TilemapCliArgs,
    global_help: void,
};

pub const CliArgs = struct {
    png_path: ?[]const u8 = null,
    json_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    bpp: BppMode = .auto,
    palette_only: bool = false,
    no_palette: bool = false,
    color_adjust: bool = false,
    show_help: bool = false,

    pub const ParseError = error{
        MissingValue,
        UnknownFlag,
        UnknownSubcommand,
        MissingSubcommand,
        InvalidFormat,
        InvalidBppMode,
        MissingRequiredArguments,
        ConflictingPaletteOptions,
        Unimplemented,
    };

    pub fn parseCli(args: []const []const u8) ParseError!ParsedCli {
        _ = args;
        return error.Unimplemented;
    }

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
            } else if (std.mem.eql(u8, arg, "-N") or std.mem.eql(u8, arg, "--no-palette")) {
                result.no_palette = true;
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

        if (result.palette_only and result.no_palette) {
            return error.ConflictingPaletteOptions;
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
        \\  -N, --no-palette        Omit embedded palette in generated sprite (for external master palettes)
        \\  -h, --help              Display this help message and exit
        \\
        \\Note:
        \\  Options can be specified in any order.
        \\
    , .{ program_name, program_name }) catch return;
    std.Io.File.writeStreamingAll(.stdout(), io, msg) catch {};
}

fn writeOutputFile(io: std.Io, out_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(out_path)) |dir_path| {
        if (dir_path.len > 0) {
            std.Io.Dir.createDirPath(.cwd(), io, dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_path, .data = data });
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
            error.ConflictingPaletteOptions => {
                std.debug.print("Error: --palette-only (-P) and --no-palette (-N) cannot be used together.\n\n", .{});
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

    // Step 1: Open and validate input.png
    const png_data = std.Io.Dir.readFileAlloc(.cwd(), init.io, input_png_path, allocator, .unlimited) catch |err| {
        std.debug.print("Error: unable to read input image '{s}': {s}\n", .{ input_png_path, @errorName(err) });
        std.process.exit(1);
    };

    _ = png.parseHeader(png_data) catch |err| {
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

    if (!parsed_args.palette_only) {
        var img = png.decompressIndexedPixels(allocator, png_data) catch |err| {
            std.debug.print("Error: failed to decompress image data '{s}': {s}\n", .{ input_png_path, @errorName(err) });
            std.process.exit(1);
        };
        defer img.deinit();

        // Step 2: Open and validate input.json
        const json_data = std.Io.Dir.readFileAlloc(.cwd(), init.io, input_json_path.?, allocator, .unlimited) catch |err| {
            std.debug.print("Error: unable to read input JSON '{s}': {s}\n", .{ input_json_path.?, @errorName(err) });
            std.process.exit(1);
        };

        var meta = metadata.parseMetadata(allocator, json_data, .auto) catch |err| {
            std.debug.print("Error: failed to parse JSON metadata '{s}': {s}\n", .{ input_json_path.?, @errorName(err) });
            std.process.exit(1);
        };
        defer meta.deinit();

        // Step 3: Generate Zig Source Code
        const zig_source = codegen.generateZigSource(allocator, png_data, json_data, .{
            .bpp = parsed_args.bpp,
            .color_adjust = parsed_args.color_adjust,
            .palette_only = parsed_args.palette_only,
            .no_palette = parsed_args.no_palette,
        }) catch |err| {
            std.debug.print("Error: code generation failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(zig_source);

        // Step 4: Output to file or stdout
        if (output_zig_path) |out_path| {
            writeOutputFile(init.io, out_path, zig_source) catch |err| {
                std.debug.print("Error: unable to write output file '{s}': {s}\n", .{ out_path, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            std.Io.File.writeStreamingAll(.stdout(), init.io, zig_source) catch {};
        }
    } else {
        // Palette only mode code generation
        const zig_source = codegen.generateZigSource(allocator, png_data, null, .{
            .bpp = parsed_args.bpp,
            .color_adjust = parsed_args.color_adjust,
            .palette_only = true,
            .no_palette = false,
        }) catch |err| {
            std.debug.print("Error: palette code generation failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer allocator.free(zig_source);

        if (output_zig_path) |out_path| {
            writeOutputFile(init.io, out_path, zig_source) catch |err| {
                std.debug.print("Error: unable to write output file '{s}': {s}\n", .{ out_path, @errorName(err) });
                std.process.exit(1);
            };
        } else {
            std.Io.File.writeStreamingAll(.stdout(), init.io, zig_source) catch {};
        }
    }
}

test "CLI001: parseCli sprite default format and standard arguments" {
    const raw_args = [_][]const u8{ "sprite", "--png", "test.png", "--json", "test.json", "--output", "out.zig", "--bpp", "4" };
    const parsed = try CliArgs.parseCli(&raw_args);
    try std.testing.expectEqual(ParsedCli.sprite, std.meta.activeTag(parsed));
    try std.testing.expectEqualStrings("test.png", parsed.sprite.png_path.?);
    try std.testing.expectEqualStrings("test.json", parsed.sprite.json_path.?);
    try std.testing.expectEqual(SpriteFormat.aseprite, parsed.sprite.format);
    try std.testing.expectEqualStrings("out.zig", parsed.sprite.output_path.?);
    try std.testing.expectEqual(BppMode.bpp4, parsed.sprite.bpp);
    try std.testing.expect(!parsed.sprite.palette_only);
    try std.testing.expect(!parsed.sprite.show_help);
}

test "CLI002: parseCli sprite explicit --format aseprite flag" {
    const raw_args = [_][]const u8{ "sprite", "-p", "test.png", "-j", "test.json", "--format", "aseprite" };
    const parsed = try CliArgs.parseCli(&raw_args);
    try std.testing.expectEqual(ParsedCli.sprite, std.meta.activeTag(parsed));
    try std.testing.expectEqual(SpriteFormat.aseprite, parsed.sprite.format);
}

test "CLI003: parseCli sprite reject invalid --format" {
    const raw_args = [_][]const u8{ "sprite", "-p", "test.png", "-j", "test.json", "--format", "unknown_fmt" };
    try std.testing.expectError(error.InvalidFormat, CliArgs.parseCli(&raw_args));
}

test "CLI004: parseCli sprite palette-only and optional flags" {
    const raw_args = [_][]const u8{ "sprite", "-p", "palette.png", "-P", "--bpp", "4x16", "-o", "pal.zig", "-c" };
    const parsed = try CliArgs.parseCli(&raw_args);
    try std.testing.expectEqual(ParsedCli.sprite, std.meta.activeTag(parsed));
    try std.testing.expectEqualStrings("palette.png", parsed.sprite.png_path.?);
    try std.testing.expect(parsed.sprite.json_path == null);
    try std.testing.expect(parsed.sprite.palette_only);
    try std.testing.expect(parsed.sprite.color_adjust);
    try std.testing.expectEqual(BppMode.bpp4x16, parsed.sprite.bpp);
    try std.testing.expectEqualStrings("pal.zig", parsed.sprite.output_path.?);
}

test "CLI005: parseCli sprite reject conflicting palette options" {
    const conflicting_args = [_][]const u8{ "sprite", "-p", "hero.png", "-j", "hero.json", "-P", "-N" };
    try std.testing.expectError(error.ConflictingPaletteOptions, CliArgs.parseCli(&conflicting_args));
}

test "CLI006: parseCli tilemap default format (ldtk) and flags" {
    const raw_args = [_][]const u8{ "tilemap", "--input", "level.ldtk", "--output", "level.zig", "--bpp", "4" };
    const parsed = try CliArgs.parseCli(&raw_args);
    try std.testing.expectEqual(ParsedCli.tilemap, std.meta.activeTag(parsed));
    try std.testing.expectEqualStrings("level.ldtk", parsed.tilemap.input_path.?);
    try std.testing.expectEqual(TilemapFormat.ldtk, parsed.tilemap.format);
    try std.testing.expectEqualStrings("level.zig", parsed.tilemap.output_path.?);
    try std.testing.expectEqual(BppMode.bpp4, parsed.tilemap.bpp);
}

test "CLI007: parseCli tilemap explicit --format ldtk" {
    const raw_args = [_][]const u8{ "tilemap", "-i", "level.ldtk", "--format", "ldtk" };
    const parsed = try CliArgs.parseCli(&raw_args);
    try std.testing.expectEqual(ParsedCli.tilemap, std.meta.activeTag(parsed));
    try std.testing.expectEqual(TilemapFormat.ldtk, parsed.tilemap.format);
}

test "CLI008: parseCli tilemap reject invalid --format" {
    const raw_args = [_][]const u8{ "tilemap", "-i", "level.ldtk", "--format", "tiled" };
    try std.testing.expectError(error.InvalidFormat, CliArgs.parseCli(&raw_args));
}

test "CLI009: parseCli reject missing or unknown subcommand" {
    const no_subcmd = [_][]const u8{ "--png", "test.png" };
    try std.testing.expectError(error.UnknownSubcommand, CliArgs.parseCli(&no_subcmd));

    const unknown_subcmd = [_][]const u8{ "audio", "bgm.mid" };
    try std.testing.expectError(error.UnknownSubcommand, CliArgs.parseCli(&unknown_subcmd));
}

test "CLI010: parseCli top-level and subcommand help flags" {
    const global_help = [_][]const u8{"--help"};
    const parsed_global = try CliArgs.parseCli(&global_help);
    try std.testing.expectEqual(ParsedCli.global_help, std.meta.activeTag(parsed_global));

    const sprite_help = [_][]const u8{ "sprite", "--help" };
    const parsed_sprite = try CliArgs.parseCli(&sprite_help);
    try std.testing.expectEqual(ParsedCli.sprite, std.meta.activeTag(parsed_sprite));
    try std.testing.expect(parsed_sprite.sprite.show_help);

    const tilemap_help = [_][]const u8{ "tilemap", "-h" };
    const parsed_tilemap = try CliArgs.parseCli(&tilemap_help);
    try std.testing.expectEqual(ParsedCli.tilemap, std.meta.activeTag(parsed_tilemap));
    try std.testing.expect(parsed_tilemap.tilemap.show_help);
}

test {
    _ = png;
    _ = tile;
    _ = metadata;
    _ = codegen;
    _ = @import("algo/paeth.zig");
    _ = @import("algo/unfilter.zig");
}

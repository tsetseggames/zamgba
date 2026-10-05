const std = @import("std");
pub const types = @import("tilemap/types.zig");
pub const ldtk = @import("tilemap/ldtk.zig");

// Re-export common tilemap types
pub const Limits = types.Limits;
pub const TilemapFormat = types.TilemapFormat;
pub const TilemapError = types.TilemapError;
pub const ParsedTileEntry = types.ParsedTileEntry;
pub const ParsedEntity = types.ParsedEntity;
pub const LayerType = types.LayerType;
pub const ParsedLayer = types.ParsedLayer;
pub const ParsedLevel = types.ParsedLevel;
pub const TilemapMetadata = types.TilemapMetadata;

/// Automatically detects tilemap metadata format (or uses requested format) and parses into TilemapMetadata.
pub fn parseMetadata(
    allocator: std.mem.Allocator,
    json_content: []const u8,
    format: TilemapFormat,
) TilemapError!TilemapMetadata {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch {
        return TilemapError.InvalidJson;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return TilemapError.InvalidJson;
    }

    const root = parsed.value.object;

    switch (format) {
        .ldtk => return ldtk.parseLdtkJson(allocator, root),
        .auto => {
            if (ldtk.detectLdtk(root)) {
                return ldtk.parseLdtkJson(allocator, root);
            }
            return TilemapError.UnsupportedJsonFormat;
        },
    }
}

// ====================================================================
// Unit Tests for Tilemap Metadata Dispatcher (TDD Red Phase)
// ====================================================================

test "TLM001: parseMetadata auto-detection and explicit dispatch" {
    const test_assets = @import("test_palettes");

    // Auto-detection
    var res_auto = try parseMetadata(std.testing.allocator, test_assets.ldtk_t01_intgrid, .auto);
    defer res_auto.deinit();
    try std.testing.expectEqual(@as(usize, 1), res_auto.levels.len);
    try std.testing.expectEqual(@as(u32, 256), res_auto.levels[0].px_wid);

    // Explicit dispatch
    var res_ldtk = try parseMetadata(std.testing.allocator, test_assets.ldtk_t01_intgrid, .ldtk);
    defer res_ldtk.deinit();
    try std.testing.expectEqual(@as(usize, 1), res_ldtk.levels.len);
    try std.testing.expectEqual(@as(u32, 256), res_ldtk.levels[0].px_wid);
}

test "TLM002: parseMetadata reject invalid and unsupported JSON" {
    // Invalid JSON
    try std.testing.expectError(error.InvalidJson, parseMetadata(std.testing.allocator, "{ not json }", .auto));

    // Unsupported format in auto mode
    const foreign_json =
        \\{
        \\  "some_unknown_engine": true
        \\}
    ;
    try std.testing.expectError(error.UnsupportedJsonFormat, parseMetadata(std.testing.allocator, foreign_json, .auto));
}

test {
    _ = ldtk;
}

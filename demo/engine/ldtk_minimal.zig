const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const t01_map = @import("t01_map");

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "LDTKMINIMAL",
    "ALDT",
    "00",
    0,
);

const Game = struct {
    bg_layer: engine.TileMapLayer,
    input: engine.input.InputState = .{},
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,

    pub fn init() !Game {
        engine.log.info("LDtk Minimal Demo: Starting init", .{});

        // Configure single 256x256 (32x32 tiles) Mode 0 Background layer
        // Loads auto-split 16x16 tiles from T01 LDtk level with automated VRAM allocation
        var vram_mgr = engine.BgVramManager.init();
        const bg = try engine.TileMapLayer.init(&vram_mgr, &t01_map.Level_0_IntGrid_data, .{
            .bg_id = .bg0,
            .priority = 0,
        });

        engine.log.info("LDtk Minimal Demo: Init finished successfully", .{});

        return .{
            .bg_layer = bg,
        };
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // Allow panning the camera with D-Pad to inspect the level
        const pan_speed: i32 = 2;
        if (self.input.isPressed(.Left)) self.scroll_x -= pan_speed;
        if (self.input.isPressed(.Right)) self.scroll_x += pan_speed;
        if (self.input.isPressed(.Up)) self.scroll_y -= pan_speed;
        if (self.input.isPressed(.Down)) self.scroll_y += pan_speed;

        // Viewport bounds: 256x256 level displayed on 240x160 GBA screen
        if (self.scroll_x < 0) self.scroll_x = 0;
        if (self.scroll_x > (256 - 240)) self.scroll_x = 256 - 240;
        if (self.scroll_y < 0) self.scroll_y = 0;
        if (self.scroll_y > (256 - 160)) self.scroll_y = 256 - 160;

        self.bg_layer.setScroll(self.scroll_x, self.scroll_y);
    }
};

export fn main() noreturn {
    engine.initHardware();
    var game = Game.init() catch |err| {
        engine.log.fatal("Game.init failed: {s}", .{@errorName(err)});
        while (true) {}
    };
    engine.run(&game);
}

const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const t01_map = @import("t01_map");
const large_dirt_map = @import("large_dirt_map");

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "LEVELRELOAD",
    "ALRL",
    "00",
    0,
);

const Game = struct {
    vram_mgr: engine.BgVramManager,
    bg_layer: engine.TileMapLayer,
    current_level: u1 = 0,
    input: engine.input.InputState = .{},
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,

    pub fn init() !Game {
        engine.log.info("Level Reload Demo: Starting init", .{});

        var mgr = engine.BgVramManager.init();
        var initial_layer = try engine.TileMapLayer.init(&mgr, &t01_map.Level_0_IntGrid_data, .{
            .bg_id = .bg0,
            .priority = 0,
        });

        // Set sky blue backdrop for outdoor platform level (Level 0)
        if (hal.specs.is_gba_target) {
            hal.MemorySections.PALRAM[0] = 0x7688;
        }

        // Scroll down to display the floating platforms and ground (y = 96)
        const init_y: i32 = 96;
        initial_layer.setScroll(0, init_y);

        engine.log.info("Level Reload Demo: Initial level loaded (T01 256x256 Outdoor Platforms)", .{});

        return .{
            .vram_mgr = mgr,
            .bg_layer = initial_layer,
            .current_level = 0,
            .scroll_x = 0,
            .scroll_y = init_y,
        };
    }

    fn reloadLevel(self: *@This(), level_idx: u1) !void {
        engine.log.info("Level Reload Demo: Reloading to level {d}", .{level_idx});

        // 1. Enter forced blank to prevent visual tearing and glitches
        engine.setForcedBlank(true);

        // 2. Reset VRAM manager state and erase 64 KB BG VRAM
        self.vram_mgr.reset();

        // 3. Switch to target level data:
        // Level 0: 256x256 outdoor floating platform level (T01) with sky blue backdrop
        // Level 1: 512x512 dense underground cavern level (Large Dirt Map) filled with stone walls
        self.current_level = level_idx;
        const target_data = if (self.current_level == 0)
            &t01_map.Level_0_IntGrid_data
        else
            &large_dirt_map.Level_0_Background_data;

        // 4. Re-allocate CBB & SBB and load new tileset/entries
        self.bg_layer = try engine.TileMapLayer.init(&self.vram_mgr, target_data, .{
            .bg_id = .bg0,
            .priority = 0,
        });

        // 5. Configure level-specific backdrop and initial viewport scroll
        if (self.current_level == 0) {
            if (hal.specs.is_gba_target) {
                hal.MemorySections.PALRAM[0] = 0x7688; // Sky blue
            }
            self.scroll_x = 0;
            self.scroll_y = 96; // Position camera at the visible platforms
        } else {
            self.scroll_x = 0;
            self.scroll_y = 0; // Dense stone wall fills screen at (0, 0)
        }
        self.bg_layer.setScroll(self.scroll_x, self.scroll_y);

        // 6. Resume screen rendering
        engine.setForcedBlank(false);

        engine.log.info("Level Reload Demo: Level {d} reloaded successfully", .{level_idx});
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // Press A or Start to switch between Level 0 and Level 1
        if (self.input.isJustPressed(.A) or self.input.isJustPressed(.Start)) {
            const next_level: u1 = if (self.current_level == 0) 1 else 0;
            self.reloadLevel(next_level) catch |err| {
                engine.log.fatal("Level reload failed: {s}", .{@errorName(err)});
            };
            return;
        }

        // Panning controls with D-Pad
        const pan_speed: i32 = 2;
        if (self.input.isPressed(.Left)) self.scroll_x -= pan_speed;
        if (self.input.isPressed(.Right)) self.scroll_x += pan_speed;
        if (self.input.isPressed(.Up)) self.scroll_y -= pan_speed;
        if (self.input.isPressed(.Down)) self.scroll_y += pan_speed;

        // Viewport bounds depending on map size
        const max_w: i32 = if (self.current_level == 0) 256 else 512;
        const max_h: i32 = if (self.current_level == 0) 256 else 512;

        if (self.scroll_x < 0) self.scroll_x = 0;
        if (self.scroll_x > (max_w - 240)) self.scroll_x = max_w - 240;
        if (self.scroll_y < 0) self.scroll_y = 0;
        if (self.scroll_y > (max_h - 160)) self.scroll_y = max_h - 160;

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

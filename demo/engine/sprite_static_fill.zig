const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;

const Fixed24_8 = engine.physics.Fixed24_8;
const Color = engine.Color;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "STATFILL",
    "ASTF",
    "00",
    0,
);

const COLOR_CYCLE = [_]Color{
    Color.RED,
    Color.GREEN,
    Color.BLUE,
    Color.YELLOW,
    Color.CYAN,
    Color.MAGENTA,
    Color.WHITE,
};

const Game = struct {
    player: engine.StaticSprite,
    platform: engine.StaticSprite,
    pillar: engine.StaticSprite,
    gem: engine.StaticSprite,
    input: engine.input.InputState = .{},
    color_index: usize = 0,

    pub fn init() Game {
        // Initialize sprites with non-overlapping tile indices and distinct palette banks
        var self = Game{
            // Player: 16x16 square (4 tiles) at tile index 0, palette bank 0
            .player = engine.StaticSprite.init(Fixed24_8.fromInt(112), Fixed24_8.fromInt(72), 16, 16, .{
                .tile_index = 0,
                .palette_bank = 0,
            }) catch unreachable,
            // Horizontal platform: 32x8 wide rectangle (4 tiles) at tile index 4, palette bank 1
            .platform = engine.StaticSprite.init(Fixed24_8.fromInt(40), Fixed24_8.fromInt(120), 32, 8, .{
                .tile_index = 4,
                .palette_bank = 1,
            }) catch unreachable,
            // Vertical pillar: 8x32 tall rectangle (4 tiles) at tile index 8, palette bank 2
            .pillar = engine.StaticSprite.init(Fixed24_8.fromInt(190), Fixed24_8.fromInt(30), 8, 32, .{
                .tile_index = 8,
                .palette_bank = 2,
            }) catch unreachable,
            // Small marker gem: 8x8 square (1 tile) at tile index 12, palette bank 3
            .gem = engine.StaticSprite.init(Fixed24_8.fromInt(50), Fixed24_8.fromInt(40), 8, 8, .{
                .tile_index = 12,
                .palette_bank = 3,
            }) catch unreachable,
        };

        // Procedurally populate tile graphics in VRAM and palette entries in PALRAM
        self.player.fillSolidColor(COLOR_CYCLE[0]) catch {};
        self.platform.fillSolidColor(Color.GREEN) catch {};
        self.pillar.fillSolidColor(Color.BLUE) catch {};
        self.gem.fillSolidColor(Color.YELLOW) catch {};

        return self;
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Move player with D-Pad
        const speed: i32 = 2;
        var x = self.player.sprite.aabb.x.toInt();
        var y = self.player.sprite.aabb.y.toInt();

        if (self.input.isPressed(.Left)) x -= speed;
        if (self.input.isPressed(.Right)) x += speed;
        if (self.input.isPressed(.Up)) y -= speed;
        if (self.input.isPressed(.Down)) y += speed;

        // Clamp within screen boundaries
        const max_x: i32 = hal.Screen.WIDTH_PIXELS - @as(i32, @intCast(self.player.sprite.aabb.width));
        const max_y: i32 = hal.Screen.HEIGHT_PIXELS - @as(i32, @intCast(self.player.sprite.aabb.height));
        if (x < 0) x = 0;
        if (x > max_x) x = max_x;
        if (y < 0) y = 0;
        if (y > max_y) y = max_y;

        self.player.sprite.aabb.x = Fixed24_8.fromInt(x);
        self.player.sprite.aabb.y = Fixed24_8.fromInt(y);

        // 2. Press A to cycle player color dynamically via fillSolidColor()
        if (self.input.isJustPressed(.A)) {
            self.color_index = (self.color_index + 1) % COLOR_CYCLE.len;
            self.player.fillSolidColor(COLOR_CYCLE[self.color_index]) catch {};
        }

        // 3. Draw all procedural sprites
        engine.drawSprite(&self.player);
        engine.drawSprite(&self.platform);
        engine.drawSprite(&self.pillar);
        engine.drawSprite(&self.gem);
    }
};

export fn main() noreturn {
    engine.initHardware();
    var game = Game.init();
    engine.run(&game);
}

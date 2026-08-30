const builtin = @import("builtin");
const hal = @import("zamgba-hal");

pub const Sprite = @import("sprite.zig").Sprite;
pub const BppMode = @import("sprite.zig").BppMode;
pub const AnimationDirection = @import("sprite.zig").AnimationDirection;
pub const AnimationTag = @import("sprite.zig").AnimationTag;
pub const SpriteSheet = @import("sprite.zig").SpriteSheet;
pub const Color = @import("color.zig").Color;

pub const Engine = struct {
    shadow_oam: [128]hal.oam.ObjAttr,
    sprite_count: usize,

    pub fn init() Engine {
        if (builtin.target.os.tag == .freestanding) {
            hal.display.setMode0();
            hal.display.enableSpriteLayer();
            hal.display.setSpriteMapping(.linear_1d);
            hal.display.writeRegister();
        }

        var eng = Engine{
            .shadow_oam = undefined,
            .sprite_count = 0,
        };
        for (&eng.shadow_oam) |*obj| {
            obj.* = .{
                .attr0 = 160, // Pushed offscreen
                .attr1 = 0,
                .attr2 = 0,
                .fill = 0,
            };
        }
        return eng;
    }

    /// Should be called at the end of the game loop to complete the frame.
    /// 1. Waits for the display to finish drawing the current frame (VBlank).
    /// 2. Commits the staged frame graphics (OAM shadow) to GBA hardware.
    /// 3. Resets the frame-level state (like sprite slot allocators) so the next frame starts fresh.
    pub fn nextFrame(self: *Engine) void {
        // Wait for VBlank
        hal.waitForVBlank();

        // Flush shadow memory to hardware
        const hw_oam = @as([*]volatile hal.oam.ObjAttr, @ptrCast(@alignCast(hal.MemorySections.OAM)));
        for (self.shadow_oam, 0..) |obj, i| {
            hw_oam[i] = obj;
        }

        // Reset the sprite count so the next frame draws from slot 0
        self.sprite_count = 0;
    }

    /// Registers a high-level sprite to be rendered in the current frame.
    /// This dynamically maps the high-level sprite into the next available OAM slot.
    pub fn drawSprite(self: *Engine, spr: *const Sprite) void {
        if (self.sprite_count >= 128) return; // GBA hardware limit
        self.shadow_oam[self.sprite_count] = spr.toOamAttr();
        self.sprite_count += 1;
    }

    /// Starts the game loop. Automatically detects if you are passing:
    /// 1. A static namespace/type (e.g., `@This()` representing a Zig file-struct).
    /// 2. An instantiated struct pointer (e.g., `&game` containing state fields).
    /// Enforces at compile-time that a public `tick` function/method is defined.
    pub fn run(self: *Engine, context: anytype) noreturn {
        const T = @TypeOf(context);
        if (T == type) {
            // Static namespace/file context
            const has_tick = @hasDecl(context, "tick");
            if (!has_tick) {
                @compileError("Context type must define a public 'tick(eng: *Engine) void' function.");
            }
            while (true) {
                context.tick(self);
                self.nextFrame();
            }
        } else {
            // Instantiated object context
            const PtrInfo = @typeInfo(T);
            if (PtrInfo != .pointer) {
                @compileError("Engine.run must be passed a pointer for struct instances (e.g., &game).");
            }
            const ChildType = PtrInfo.pointer.child;
            const has_tick = @hasDecl(ChildType, "tick");
            if (!has_tick) {
                @compileError("Instance type must define a public 'tick(eng: *Engine) void' method.");
            }
            while (true) {
                context.tick(self);
                self.nextFrame();
            }
        }
    }
};

pub const gfx2d = @import("gfx2d/gfx2d.zig");
pub const input = @import("input.zig");
pub const physics = @import("physics/physics.zig");

test {
    _ = physics;
}

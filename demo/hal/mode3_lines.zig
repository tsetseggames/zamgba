const gba = @import("zamgba");
const hal = gba.hal;
const oam = gba.hal.oam;
const gfx2d = gba.engine.gfx2d;

// The gameHeader is required at the beginning of GBA rom
// with correct game name, game code, maker code and version.
// It can't be initialized within main(), because GBA BIOS relies on
// the header to locate main().
//
// In devkitARM, this step not done in build time, but done by
// gbafix. This approach is learnt from ZigGBA. It allows we build
// everything in code, intead of requiring an additional gbafix.
//
// Note that the ``export`` keyword and `linksection(".gba.header")``
// attribute are both required. The linker
// script name, ``.gba.header``, is a convention used in zamgba to
// locate header at linking time.
//
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "FIRST",
    "AFSE",
    "00",
    0,
);

// Make sure the main() function is tagged with `export' keyword.
// It makes the function visible in symbol table of ELF file.
// It's required to allow the assembly code in zamgba library locate
// the address of main() function as entry point.
export fn main() noreturn {
    // The example https://www.coranac.com/tonc/text/first.htm

    hal.display.setMode3();
    hal.display.enableBgLayer(.bg2);
    hal.display.writeRegister();

    var ctx = hal.context.Mode3Context.init();

    gfx2d.drawLine(gfx2d.Point2.init(10, 10), gfx2d.Point2.init(230, 150), 0x001F, &ctx);
    gfx2d.drawLine(gfx2d.Point2.init(230, 10), gfx2d.Point2.init(10, 150), 0x03E0, &ctx);
    gfx2d.drawLine(gfx2d.Point2.init(120, 10), gfx2d.Point2.init(120, 150), 0x7C00, &ctx);

    // The loop is required to match the ``noreturn`` return value.
    // Zamgba does not handle program exit gracefully because GBA
    // does not provide concept of graceful exit due to a lack of
    // operating system. Make sure the while (true) {} always exist.
    while (true) {}
}

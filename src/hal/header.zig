// Nameing convention comes from
// https://fabiensanglard.net/another_world_polygons_GBA/gbatech.html
// https://docs.huihoo.com/media/uclgba//gba-howto/ar01s03.html
//  https://iitd-plos.github.io/col718/ref/arm-instructionset.pdf
pub const Header = extern struct {
    romEntryPoint: u32 align(1), // 32bit ARM branch code, e.g. b rom_start
    nintendoLogo: [156]u8 align(1), // compressed bitmap, required
    gameTitle: [12]u8 align(1), // uppercase ascii, max 12 characters
    gameCode: [4]u8 align(1), // uppercase ascii, 4 characters
    makerCode: [2]u8 align(1), // uppercase ascii, 2 characters
    fixedValue: u8 align(1), // must be 0x96, required
    mainUnitCode: u8 align(1), // 0x00 for current GBA models
    deviceType: u8 align(1), // usually 0x00 (bit7=DACS/debug related)
    reservedArea: [7]u8 align(1), // zero filled
    softwareVersion: u8 align(1), // usually 0x00
    complementCheck: u8 align(1), // header checksum, required
    reservedArea2: u16 align(1), // zero filled, fields below are for multiboots
    ramEntryPoint: u32 align(1), // 32bit ARM branch code, e.g. b ram_start
    bootMode: u8 align(1), // 0x00 - BIOS overwrites this value
    slaveIDNumber: u8 align(1), // 0x00 - BIOS overwrites this value
    notUsed: [26]u8 align(1), // seems to be unused
    joyBusEntryPoint: u32 align(1), // 32bit ARM branch opcode, e.g. b joy_start
};

// Explain the contents:
//
// ### romEntryPoint
//
// The GBA rom starts from Address 0x00000000. The first content is
// the Header. The first word in the header. Header.romEntryPoint, it
// set to code 0xEA00002E. Both rust-gba and ZigGBA use it, as well as
// ``https://github.com/devkitPro/gba-tools/blob/master/src/gbafix.c``.
// It means ARM instruction, 'B 0x2E'. It means jumping to adress 0x2E
// to execute code.
//
// The 0x2E offset means next instruction goes to current
// PC + 0x2E word + 2 word prefetch. It should be (0x2E + 2) * 4 = 192 bytes.
// It points to Header.ramEntryPoint.
//
// Then, Header.ramEntryPoint was filled as 0xEA000008. It goes to next
// (0x08 + 2) * 4 = 40 bytes. This is from rust-gba but seems incorrect.
// rust-gba defines a header with multiboot, while ZigGBA and gbafix
// do not define it. I fix it to 0xEA000007, based on formula of
//  (offset + 2) * 4 = 36 bytes.
//
//
// The fixgba tool from devkitPro does a job to insert manufactoring
// data (game code, maker code, etc.) and re-compute the checksum.

pub const headerTemplate = Header{
    .romEntryPoint = 0xEA00002E,
    .nintendoLogo = .{
        0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21, 0x3D, 0x84, 0x82, 0x0A, 0x84, 0xE4, 0x09, 0xAD,
        0x11, 0x24, 0x8B, 0x98, 0xC0, 0x81, 0x7F, 0x21, 0xA3, 0x52, 0xBE, 0x19, 0x93, 0x09, 0xCE, 0x20,
        0x10, 0x46, 0x4A, 0x4A, 0xF8, 0x27, 0x31, 0xEC, 0x58, 0xC7, 0xE8, 0x33, 0x82, 0xE3, 0xCE, 0xBF,
        0x85, 0xF4, 0xDF, 0x94, 0xCE, 0x4B, 0x09, 0xC1, 0x94, 0x56, 0x8A, 0xC0, 0x13, 0x72, 0xA7, 0xFC,
        0x9F, 0x84, 0x4D, 0x73, 0xA3, 0xCA, 0x9A, 0x61, 0x58, 0x97, 0xA3, 0x27, 0xFC, 0x03, 0x98, 0x76,
        0x23, 0x1D, 0xC7, 0x61, 0x03, 0x04, 0xAE, 0x56, 0xBF, 0x38, 0x84, 0x00, 0x40, 0xA7, 0x0E, 0xFD,
        0xFF, 0x52, 0xFE, 0x03, 0x6F, 0x95, 0x30, 0xF1, 0x97, 0xFB, 0xC0, 0x85, 0x60, 0xD6, 0x80, 0x25,
        0xA9, 0x63, 0xBE, 0x03, 0x01, 0x4E, 0x38, 0xE2, 0xF9, 0xA2, 0x34, 0xFF, 0xBB, 0x3E, 0x03, 0x44,
        0x78, 0x00, 0x90, 0xCB, 0x88, 0x11, 0x3A, 0x94, 0x65, 0xC0, 0x7C, 0x63, 0x87, 0xF0, 0x3C, 0xAF,
        0xD6, 0x25, 0xE4, 0x8B, 0x38, 0x0A, 0xAC, 0x72, 0x21, 0xD4, 0xF8, 0x07,
    },
    .gameTitle = @splat(0),
    .gameCode = @splat(0),
    .makerCode = @splat(0),
    .fixedValue = 0x96,
    .mainUnitCode = 0x0,
    .deviceType = 0x0,
    .reservedArea = @splat(0),
    .softwareVersion = 0x0,
    .complementCheck = 0x0,
    .reservedArea2 = 0x0,
    .ramEntryPoint = 0xEA000007,
    .bootMode = 0x0,
    .slaveIDNumber = 0x0,
    .notUsed = @splat(0),
    .joyBusEntryPoint = 0,
};

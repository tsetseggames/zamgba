const specs = @import("specs.zig");

/// OAM hardware definition
/// A single OAM entry is 64 bits (8 bytes):
/// attr0 (16-bit), attr1 (16-bit), attr2 (16-bit), affine (16-bit).
pub const ObjAttr = packed struct {
    attr0: u16,
    attr1: u16,
    attr2: u16,
    fill: u16, // padding / affine index
};

/// OAM Object Shapes (attr0 bits 14-15)
pub const Shape = struct {
    pub const SQUARE: u16 = 0;
    pub const HORIZONTAL: u16 = 1;
    pub const VERTICAL: u16 = 2;
    pub const FORBIDDEN: u16 = 3;
};

/// OAM Object Sizes (attr1 bits 14-15)
pub const Size = struct {
    pub const SIZE_0: u16 = 0; // Square: 8x8, Horizontal: 16x8, Vertical: 8x16
    pub const SIZE_1: u16 = 1; // Square: 16x16, Horizontal: 32x8, Vertical: 8x32
    pub const SIZE_2: u16 = 2; // Square: 32x32, Horizontal: 32x16, Vertical: 16x32
    pub const SIZE_3: u16 = 3; // Square: 64x64, Horizontal: 64x32, Vertical: 32x64
};

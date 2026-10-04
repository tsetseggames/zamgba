pub const png_rgb = @embedFile("palettes/1-test-rgb.png");
pub const png_pal256 = @embedFile("palettes/2-test-palette-256.png");
pub const png_pal32 = @embedFile("palettes/3-test-pallette-32.png");
pub const png_pal16 = @embedFile("palettes/4-test-palette-16.png");
pub const png_pal8 = @embedFile("palettes/5-test-palette-8.png");
pub const png_broom = @embedFile("tsetseg-ride-on-broom-64x64-0001.png");
pub const json_broom = @embedFile("tsetseg-ride-on-broom-64x64-0001.json");

// LDtk Test Level Assets
pub const ldtk_t01_intgrid = @embedFile("tileset/T01-intgrid-embed-tileset-256x256.ldtk");
pub const ldtk_t01_16x16 = @embedFile("tileset/T01-auto-split-16x16-tile-256x256.ldtk");
pub const ldtk_t02_tile_only = @embedFile("tileset/T02-tile-layer-only-256x256.ldtk");
pub const ldtk_t03_4bg = @embedFile("tileset/T03-multi-layer-4bg-256x256.ldtk");
pub const ldtk_t04_entities = @embedFile("tileset/T04-entities-spawn-256x256.ldtk");
pub const ldtk_t05_flips = @embedFile("tileset/T05-tile-flips-8x8-256x256.ldtk");

pub const ldtk_e01_5bg = @embedFile("tileset/E01-err-too-many-layers-5bg.ldtk");
pub const ldtk_e02_invalid_dim = @embedFile("tileset/E02-err-invalid-dim-not-8px.ldtk");
pub const ldtk_e03_large_x = @embedFile("tileset/E03-err-map-too-large-x-5000px.ldtk");
pub const ldtk_e03_large_y = @embedFile("tileset/E03-err-map-too-large-y-5000px.ldtk");
pub const ldtk_e04_intgrid_range = @embedFile("tileset/E04-err-intgrid-out-of-range.ldtk");
pub const ldtk_e05_alpha_warn = @embedFile("tileset/E05-warn-tile-alpha-blending.ldtk");

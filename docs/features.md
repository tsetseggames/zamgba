# Zamgba SDK Features Plan

The Zamgba SDK provides high-level APIs for 2D games on the Game Boy Advance. Its primary goal is to hide hardware details and provide a smooth, modern developer experience.

## Planned Features

1. **2D Graphics & Sprites (v0.1.0 - v0.3.0)**
   - [x] Sprite maps (Tile/Map modes) - *Mode 0 support*
   - [x] Picture mode (Bitmap modes) - *True color background via Mode 3, 4, 5*
   - [x] Architecture Planning (Tiered approach)
   - [x] High-level abstractions for palettes and object attributes (OAM)
   - [x] Single color/square sprites
   - [x] Engine-level streaming sprite loader & VBlank DMA manager - *(v0.2.0)*
   - [ ] Background TileMap engine (ScreenBlock management & packed 16-bit ScreenEntry) - *(v0.3.0)*
   - [ ] Camera support for scrolling backgrounds - *(v0.3.0)*

2. **Architecture Layers (New)**
   - **Tier 1 (HAL):** `zamgba.hal` - Hardware limits, memory, registers.
   - **Tier 2 (ENGINE):** `zamgba.engine` - High-level entities (Sprite, Camera, TileMap, Physics).

3. **Input (v0.1.0)**
   - [x] Respond to gamepad input

4. **Audio (v0.4.0 & v0.6.0)**
   - [ ] PSG (Programmable Sound Generator / Chiptune) support
   - [ ] Direct Sound (PCM / Direct Audio playback) support

5. **Save System (v0.5.0)**
   - [ ] High-level state persistence (Save state read/write API)
   - [ ] Hardware-dependent implementation (relies on external hardware/emulator capabilities like SRAM, Flash, or EEPROM)

6. **Physics & Collision (v0.7.0)**
   - [x] Built-in 2D box (AABB) collision engine (2D collision & detection API)
   - [x] Hardcoded collision detection (Early milestone)

7. **Tooling & Asset Conversion**
   - [x] PNG-sprite-to-code conversion tool (`zurag`)
   - [x] Color palettes conversion tool (`zurag`)
   - [ ] Chiptune-to-code conversion tool
   - [ ] Wav file to code conversion tool

8. **Advanced Game Capabilities (v1.0.0 & v2.0.0)**
   - [ ] 2D platformer game framework capabilities
   - [ ] Pseudo-3D game rendering support

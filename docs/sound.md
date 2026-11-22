# Zamgba Audio System Architecture & Design

This document details the audio technical selection, hardware constitution, asset toolchain (`duu`), and implementation roadmap for the Zamgba SDK.

---

## 1. GBA Audio Hardware Architecture Overview

The Game Boy Advance provides a hybrid dual-audio subsystem combining legacy Game Boy hardware synthesis with modern 8-bit digital PCM playback.

```
                    ┌───────────────────────────────────────────────────────┐
                    │               GBA Audio Subsystem Hardware            │
                    └───────────┬───────────────────────────────┬───────────┘
                                │                               │
                ┌───────────────▼──────────────┐ ┌──────────────▼──────────────┐
                │     DMG PSG (Chiptune)       │ │   DirectSound A & B (PCM)   │
                ├──────────────────────────────┤ ├──────────────────────────────┤
                │ • CH1: Square wave + Sweep   │ │ • Dual 8-bit DAC channels    │
                │ • CH2: Square wave           │ │ • Driven by Timer0/1 & DMA1/2│
                │ • CH3: 32-sample Wave RAM    │ │ • Plays real sampled audio   │
                │ • CH4: Pseudo-random Noise   │ │ • Requires no CPU mixing for │
                │ • CPU Overhead: 0% (Hardware)│ │   single pre-rendered stream │
                └──────────────────────────────┘ └──────────────────────────────┘
                                │                               │
                                └───────────────┬───────────────┘
                                                │ Hardware Master Volume & Mixer
                                                ▼
                                    [ Stereo Headphone / Speaker ]
```

### A. Programmable Sound Generator (PSG / DMG 4-Channel)
* **MMIO Space**: `0x04000060` - `0x04000088` (`SOUND1CNT_L` through `SOUNDBIAS`).
* **Channels**:
  * **CH1**: Pulse/Square wave with frequency sweep and volume envelope.
  * **CH2**: Pulse/Square wave with volume envelope.
  * **CH3**: Custom 4-bit 32-sample wave pattern RAM.
  * **CH4**: White noise / periodic noise generator.
* **Characteristics**: Runs purely in dedicated analog/digital hardware with **0% CPU consumption**. Ideal for retro chiptune BGM and concurrent sound effects (SFX).

### B. DirectSound A & B (Digital Audio / PCM)
* **MMIO Space**: `REG_FIFO_A` (`0x040000A0`), `REG_FIFO_B` (`0x040000A4`), `REG_SOUNDCNT_H` (`0x04000082`).
* **Mechanism**: Dual 8-bit signed PCM channels. DirectSound pairs a 32-byte hardware FIFO with a hardware Timer (e.g. Timer 0 at 16kHz) and DMA (DMA 1 / DMA 2). When the FIFO reaches half-empty (16 bytes remaining), DMA automatically refills it from memory with zero CPU cycle interruption.

---

## 2. Design Principles & Authoring Tool Selection

Zamgba adheres to three core design pillars for audio:
1. **Zero External Dependencies**: Pure Zig compiler and build toolchain.
2. **Identical Cross-Platform Authoring**: 100% native GUI and CLI workflows across **Windows, macOS, and Linux**.
3. **Hardware-Aligned Pragmatism**: Gradual, zero-friction layering that enables rich game audio without mandatory complex DSP mixing.

### Selected Upstream Authoring Tools

```
┌─────────────────────────────────────────────────────────────────────────┐
│              Cross-Platform Upstream Tools (Win / macOS / Linux)         │
├─────────────────────────────────────────────────────────────────────────┤
│ • Primary Retro Tracker  : Furnace Tracker (BGM & Chiptune/PSG SFX)      │
│ • Module Tracker         : MilkyTracker / Renoise (Standard .xm)        │
│ • Sample Audio / SFX     : Jfxr / Audacity (WAV export)                 │
└─────────────────────────────────────────────────────────────────────────┘
```

* **Furnace Tracker** (Primary Recommendation):
  * Modern, fully open-source, native cross-platform (Win/Mac/Linux) Chiptune and Module Tracker.
  * Native emulation and parameter mapping for the **Nintendo Game Boy (DMG)** sound chip.
  * Can manage all BGM (via Subsongs) and SFX in a unified project, exporting `.xm`, `.wav`, or parameter sequences.
* **Audacity / Jfxr**:
  * Cross-platform standard tools for recording, synthesizing, and exporting single-channel `.wav` audio.

---

## 3. Asset Pipeline: Authoring -> Conversion -> Consumption

Asset transformation is handled by **`duu`** (*Mongolian for "song/sound"*, pronounced */tʊː/*), a zero-dependency CLI asset conversion tool built into Zamgba's host build graph (similar to `zurag` for graphics).

```mermaid
graph TD
    subgraph 1. Authoring (Upstream Editors)
        F1[Furnace Tracker] -->|Export .xm| BGM_SRC[.xm Module]
        F2[Furnace / Jfxr / Audacity] -->|Export .wav| SFX_SRC[.wav Audio]
    end

    subgraph 2. Conversion (Host Build Tool: duu)
        BGM_SRC --> D[duu Audio Converter CLI]
        SFX_SRC --> D
        D -->|Resample to 8-bit signed PCM & pack| ZIG_ASSET[Type-safe Zig Sound Data]
    end

    subgraph 3. Consumption (Zamgba Runtime)
        ZIG_ASSET --> ENG[zamgba.engine.audio]
        ENG -->|Direct register commands| PSG[zamgba.hal.psg]
        ENG -->|DMA double-buffered stream| DS[zamgba.hal.directsound]
    end
```

---

## 4. 3-Step Implementation Roadmap

```
Step 1: hal.psg (v0.6.0) ──► Step 2: hal.directsound (v0.7.0) ──► Step 3: Dynamic Mixer (Post-1.0.0)
```

### Step 1: Pure Hardware PSG Engine (`v0.6.0`)
* **Scope**: Implement `zamgba.hal.psg` for DMG 4-channel sound registers and `duu chiptune` converter.
* **Capabilities**:
  * Instant, retro 8-bit SFX (jump, hit, explosion, coin).
  * 0% CPU overhead, no memory buffers, no math mixing required.
  * Fully unlocks fun, responsive audio feedback for games.

### Step 2: Single-Stream DirectSound DMA Player (`v0.7.0`)
* **Scope**: Implement `zamgba.hal.directsound` and `duu wav` converter.
* **Capabilities**:
  * Configure Timer 0/1 and DMA 1/2 double buffering.
  * Stream pre-rendered PCM BGM or voice clips directly from ROM with virtually zero CPU usage.
  * Combined playback: DirectSound plays rich background music, while hardware PSG handles concurrent game SFX.

### Step 3: Dynamic Multi-Channel Software Mixer (`Post-1.0.0`)
* **Scope**: Implement `zamgba.engine.audio.Mixer` in IWRAM (`linksection(".iwram")`).
* **Capabilities**:
  * 4 to 8 virtual PCM voice mixing with fixed-point cursor pitch-shifting and volume panning.
  * Real-time `.xm` pattern interpreter and concurrent multi-voice PCM sound effects.

---

## Appendix: Authoring Tool Survey & Furnace Selection Rationale

This appendix reviews popular retro and indie game audio tools evaluated for Zamgba, and explains why **Furnace Tracker** was selected as the first-choice authoring tool.

### 1. Market Survey of Retro & Game Audio Tools

| Tool | Primary Target / Output | Cross-Platform (Win / Mac / Linux) | Status & Evaluation for ZamGBA |
| :--- | :--- | :--- | :--- |
| **Furnace Tracker** | Multi-system Chiptune & PCM (`.xm`, `.wav`, register streams) | **Native on all 3 platforms** (SDL2/ImGui) | **Selected (Primary)**. Full DMG hardware emulation + PCM Tracker workflows. |
| **MilkyTracker** | FastTracker 2 Module (`.xm`) | **Native on all 3 platforms** | **Supported**. Great lightweight companion for pure `.xm` PCM music. |
| **OpenMPT** | Module Tracker (`.xm`, `.it`, `.mod`) | Windows only (requires Wine on macOS/Linux) | **Rejected**. Fails the strict cross-platform parity requirement. |
| **FamiStudio** | NES / Famicom 2A03 Music (`.dmf`, text) | **Native on all 3 platforms** | **Not selected**. Tied to NES hardware (fixed Triangle channel, distinct LFSR noise); lacks GBA DMG CH3 custom wave support & DirectSound PCM. |
| **DefleMask** | Multi-system Chiptune (`.dmf`) | Commercial, closed ecosystem | **Rejected**. Closed-source, proprietary format without open CLI pipelines. |
| **hUGETracker** | Game Boy DMG Music (`.uge`) | Native on all 3 platforms | **Specialized**. Excellent for GB/GBC PSG bytecode, but lacks PCM sample support for GBA DirectSound. |
| **Sappy / MP2K** | GBA SoundFont & MIDI (`.mid`, `.sf2`) | Legacy 32-bit Windows binaries | **Rejected**. Outdated, fragile tooling unsuitable for automated Zig build pipelines. |
| **Audacity / Jfxr** | Waveform editing / SFX (`.wav`) | Native on all 3 platforms / Web | **Selected (SFX Companion)**. Standard for recording, procedural 8-bit sound effects, and WAV mastering. |

### 2. Why ZamGBA Prioritizes Integration with Furnace Tracker

1. **Perfect Cross-Platform Parity**:
   Just as `zurag` integrates seamlessly with Aseprite and LDtk across Windows, macOS, and Linux, Furnace Tracker runs natively on all three desktop operating systems with an identical GUI, eliminating environment inconsistencies.
2. **Dual-Architecture Alignment with GBA Hardware**:
   * **DMG Mode**: When configured to `Nintendo Game Boy`, Furnace accurately models GBA's physical PSG sound registers (CH1–CH4), allowing developers to design authentic 8-bit sound effects and chiptunes.
   * **PCM/XM Mode**: Furnace simultaneously functions as a modern multi-track sample Tracker, outputting standard `.xm` modules and `.wav` streams for GBA DirectSound.
3. **Unified BGM & SFX Project Management**:
   Using Furnace's **Subsongs** feature, a game's entire audio landscape (all stage BGM tracks and dozens of interactive sound effects) can be organized, previewed, and maintained within a single master project file.
4. **Open & Active Ecosystem**:
   Furnace is actively maintained, fully open-source (GPL-2.0), and provides clean file export schemas that integrate smoothly into Zamgba's `duu` zero-dependency code generator.

/*
 * The linker script is originated from ZigGBA project but modified
 * during study. Credits goes to the references below:
 *
 * Original version: https://github.com/wendigojaeger/ZigGBA
 * Learned from https://github.com/ryankurte/rust-gba
 */

/*
 * Memory layout is based on tonc and other documetations. I mainly
 * learn from lokathor.
 *
 * 1. https://www.coranac.com/tonc/text/hardware.htm#sec-memory
 * 2. https://lokathor.github.io/gba-from-scratch/ex1.html
 * 3. https://mcyoung.xyz/2021/06/01/linker-script/
 * 4. https://github.com/devkitPro/devkitarm-crtls/blob/master/gba_cart.ld
 */
MEMORY {
    system  : ORIGIN = 0x00000000, LENGTH = 16K
    ewram   : ORIGIN = 0x02000000, LENGTH = 256K
    iwram   : ORIGIN = 0x03000000, LENGTH = 32K
    ioram   : ORIGIN = 0x04000000, LENGTH = 1K
    palram  : ORIGIN = 0x05000000, LENGTH = 1K
    vram    : ORIGIN = 0x06000000, LENGTH = 1K
    oam     : ORIGIN = 0x07000000, LENGTH = 1K
    pakrom  : ORIGIN = 0x08000000, LENGTH = 32M
    cartram : ORIGIN = 0x0E000000, LENGTH = 64K
}

OUTPUT_FORMAT("elf32-littlearm", "elf32-bigarm", "elf32-littlearm")
OUTPUT_ARCH(arm)

ENTRY(__text_start)

__text_start  = ORIGIN(pakrom);
__eheap_end   = ORIGIN(ewram) + LENGTH(ewram);
__iwram_start = ORIGIN(iwram);
__iwram_top   = ORIGIN(iwram) + LENGTH(iwram);
__sp_irq      = __iwram_top - 0x060;
__sp_usr      = __sp_irq - 0x0a0;
__irq_flags   = 0x03007ff8;

SECTIONS
{
    . = __text_start;

    .text : {
        KEEP(*(.gba.header));
        KEEP(*(.gba.start));
        KEEP(*(.gba.boot));
        . = ALIGN(4);
        KEEP(*(.gba.irq));
        KEEP(*(.gba.main));
        *(.text*)
        . = ALIGN(4);
    } > pakrom

    .rodata : {
        *(.rodata .rodata.*);
        . = ALIGN(4);
    } > pakrom

    .data : {
        _sidata = LOADADDR(.data);
        . = ALIGN(4);
        _sdata = .;
        *(.data .data.*);

        . = ALIGN(4);
        _edata = .;
    } > ewram AT>pakrom

    .bss : {
        . = ALIGN(4);
        _sbss = .;
        *(.bss .bss.*);
        . = ALIGN(4);
        _ebss = .;
    } > ewram

    /DISCARD/ :
    {
        *(.ARM.exidx .ARM.exidx.*);
    }
}

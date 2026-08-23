// This file includes code to be referenced by build scripts.
// It defines build target for ARM7.
const std = @import("std");

fn buildGBAThumbTarget(b: *std.Build) std.Build.ResolvedTarget {
    var query = std.Target.Query{
        .cpu_arch = std.Target.Cpu.Arch.thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
        .os_tag = .freestanding,
    };

    query.cpu_features_add.addFeature(@intFromEnum(std.Target.arm.Feature.thumb_mode));
    return std.Build.resolveTargetQuery(b, query);
}

pub const GBARomOptions = struct {
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    linker_script: ?std.Build.LazyPath = null,
};

fn defaultLinkerScript(b: *std.Build) std.Build.LazyPath {
    for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], "zamgba")) {
            return b.dependency("zamgba", .{}).path("src/hal/gba.ld");
        }
    }
    return b.path("src/hal/gba.ld");
}

pub fn addROM(b: *std.Build, options: GBARomOptions) *std.Build.Step.Compile {
    const gba_thumb_target = buildGBAThumbTarget(b);
    const rom = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = options.root_source_file,
            .optimize = options.optimize,
            .target = gba_thumb_target,
        }),
    });
    const linker_script = options.linker_script orelse defaultLinkerScript(b);
    rom.setLinkerScript(linker_script);

    // Keep the original ELF for linker debugging
    b.installArtifact(rom);

    // Create true rom image that can be recognized by mgba emulator.
    // Known issue: The built executable (in ELF format) can't be
    // executed by mgba emulator, unlike devkitARM. Root cause needs
    // more investigation.
    const objcopy_step = rom.addObjCopy(.{ .format = .bin });
    const install_bin_step = b.addInstallBinFile(
        objcopy_step.getOutput(),
        b.fmt("{s}.gba", .{options.name}),
    );

    install_bin_step.step.dependOn(&objcopy_step.step);
    b.default_step.dependOn(&install_bin_step.step);
    return rom;
}

pub fn addStaticLibrary(b: *std.Build, options: GBARomOptions) *std.Build.Step.Compile {
    const gba_thumb_target = buildGBAThumbTarget(b);
    const lib = b.addStaticLibrary(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = options.root_source_file,
            .optimize = options.optimize,
            .target = gba_thumb_target,
        }),
    });
    const linker_script = options.linker_script orelse defaultLinkerScript(b);
    lib.setLinkerScript(linker_script);
    return lib;
}

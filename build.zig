const std = @import("std");

// Pub is a must. User projects use it to reference to zamgba's build
// script.
pub const arm = @import("./src/build/arm.zig");

const LibName = "zamgba";

// ====================================================================
// The target definition and gba.ld are initialized from two projects:
//
// https://github.com/wendigojaeger/ZigGBA
// https://github.com/ryankurte/rust-gba
//
// It has been modified to fit the changes in zamgba.
//
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Hardware Abstraction Layer module
    const hal_module = b.addModule("zamgba-hal", .{
        .root_source_file = b.path("src/hal/hal.zig"),
    });

    // High-Level Framework (Tier 3)
    const engine_module = b.addModule("zamgba-engine", .{
        .root_source_file = b.path("src/engine/engine.zig"),
    });

    engine_module.addImport("zamgba-hal", hal_module);

    // 2D Drawing Algorithm module (platform-agnostic)

    // Define a module that can be referenced by client project.
    // It's also the interface for client project to consume zamgba.
    //
    // Note: the module name can change fast as zamgba is in an
    // early stage. To keep a stable @import("...") names in
    // client project, consider defining alias in root_module.addImport().
    //
    // see https://github.com/fuzhouch/consumezamgba for how to use it.
    const m = b.addModule(LibName, .{ .root_source_file = b.path("src/zamgba.zig") });

    // Root module exposes submodules to clients referencing "zamgba"
    m.addImport("zamgba-hal", hal_module);
    m.addImport("zamgba-engine", engine_module);

    // Step 2: Create demo executables
    var first = arm.addROM(b, .{
        .optimize = optimize,
        .name = "mode3_lines",
        .root_source_file = b.path("demo/hal/mode3_lines.zig"),
    });

    first.root_module.addImport(LibName, m);

    var second = arm.addROM(b, .{
        .optimize = optimize,
        .name = "sprite_hal",
        .root_source_file = b.path("demo/hal/sprite_hal.zig"),
    });

    second.root_module.addImport(LibName, m);

    var third = arm.addROM(b, .{
        .optimize = optimize,
        .name = "sprite_engine",
        .root_source_file = b.path("demo/engine/sprite_engine.zig"),
    });

    third.root_module.addImport(LibName, m);

    var fourth = arm.addROM(b, .{
        .optimize = optimize,
        .name = "sprite_instanced",
        .root_source_file = b.path("demo/engine/sprite_instanced.zig"),
    });

    fourth.root_module.addImport(LibName, m);

    var fifth = arm.addROM(b, .{
        .optimize = optimize,
        .name = "joypad_hal",
        .root_source_file = b.path("demo/hal/joypad_hal.zig"),
    });

    fifth.root_module.addImport(LibName, m);

    var sixth = arm.addROM(b, .{
        .optimize = optimize,
        .name = "joypad_instanced",
        .root_source_file = b.path("demo/engine/joypad_instanced.zig"),
    });

    sixth.root_module.addImport(LibName, m);

    var seventh = arm.addROM(b, .{
        .optimize = optimize,
        .name = "collision_demo",
        .root_source_file = b.path("demo/engine/collision_demo.zig"),
    });

    seventh.root_module.addImport(LibName, m);

    var eighth = arm.addROM(b, .{
        .optimize = optimize,
        .name = "pong",
        .root_source_file = b.path("demo/engine/pong.zig"),
    });

    eighth.root_module.addImport(LibName, m);

    // Unit tests are compiled and executed in host machine. Some
    // GBA-specific code, e.g., manipulation of registers, will not be
    // covered by unit tests.
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unittest.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    // Add submodules to unit tests so we can test them on desktop
    lib_unit_tests.root_module.addImport("zamgba-hal", hal_module);
    lib_unit_tests.root_module.addImport("zamgba-engine", engine_module);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const engine_test_module = b.createModule(.{
        .root_source_file = b.path("src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_test_module.addImport("zamgba-hal", hal_module);

    const engine_unit_tests = b.addTest(.{
        .root_module = engine_test_module,
    });
    const run_engine_unit_tests = b.addRunArtifact(engine_unit_tests);
    test_step.dependOn(&run_engine_unit_tests.step);

    // ====================================================================
    // Host Tool: zurag (Aseprite PNG+JSON to GBA converter)
    // ====================================================================
    const zurag_exe = b.addExecutable(.{
        .name = "zurag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zurag/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(zurag_exe);

    const zurag_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zurag/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zurag_unit_tests = b.addRunArtifact(zurag_unit_tests);
    test_step.dependOn(&run_zurag_unit_tests.step);
}

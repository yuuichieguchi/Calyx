const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run shim zig tests");

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/gvt.zig"),
        .target = target,
        .optimize = optimize,
        // gvt.zig allocates through std.heap.c_allocator. macOS links
        // libSystem implicitly, but Linux targets refuse to reference
        // libc symbols unless it is declared; the final musl link is
        // done by the consumer (rustc) against its own musl libc.
        .link_libc = true,
    });

    // `simd = false` keeps this a pure static build (no libc++, no
    // simdutf/highway fetches); the stream falls back to scalar UTF-8
    // decoding. Drop this if SIMD-accelerated decoding turns out to be
    // needed for feed throughput.
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    });
    lib_mod.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));

    const lib = b.addLibrary(.{
        .name = "gvt",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}

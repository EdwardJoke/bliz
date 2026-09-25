const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "bliz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run bliz");
    run_step.dependOn(&run.step);

    // --- test -----------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // --- verify ---------------------------------------------------------------
    // Records the demo fixture and asserts the one-line-one-row invariant the
    // repaint arithmetic depends on. `record --verify` exits non-zero when a row
    // is not exactly `cols` cells wide, which fails this step.
    const verify_step = b.step("verify", "Check the frame invariant on the demo fixture");

    const verify_record = b.addRunArtifact(exe);
    verify_record.step.dependOn(b.getInstallStep());
    verify_record.setCwd(b.path("demo/workspace"));
    verify_record.addArgs(&.{ "record", "--verify", "--out", "frames.json" });
    verify_step.dependOn(&verify_record.step);

    // The destination picker is a second prompt with its own layout arithmetic
    // (and its own collapse-reveal paths), so it gets the same gate rather than
    // being covered only by the skill prompt's recording.
    //
    // It also offers both scopes, and the global half resolves against `$HOME`.
    // Pointing that at `demo/home` is what keeps the recording reproducible:
    // otherwise the demo would list whatever agent directories the machine that
    // ran it happens to have, and the global tab would be empty on a clean one.
    const verify_pick = b.addRunArtifact(exe);
    verify_pick.step.dependOn(b.getInstallStep());
    verify_pick.setCwd(b.path("demo/workspace"));
    verify_pick.setEnvironmentVariable("HOME", b.pathFromRoot("demo/home"));
    verify_pick.addArgs(&.{ "record", "--pick", "--verify", "--out", "pick-frames.json" });
    verify_step.dependOn(&verify_pick.step);
}

const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("bhvn", "src/main.zig");
    exe.addCSourceFile("src/simple_font.c", &[_][]const u8{"-std=c99"});
    exe.addPackagePath("hsluv", "/home/lachlan/hsluvzig/hsluv.zig");

    exe.addIncludeDir("./src/");
    exe.addIncludeDir("/usr/include/");
    exe.linkLibC();
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("GL");

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

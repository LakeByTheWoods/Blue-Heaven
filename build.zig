const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("bhvn", "src/main.zig");

    exe.addIncludeDir("/usr/include/");
    exe.linkLibC();
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("GL");

    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
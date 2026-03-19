const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // wlr-layer-shell protocol
    const xml = b.path("protocols/wlr-layer-shell-unstable-v1.xml");

    const scan_hdr = b.addSystemCommand(&.{"wayland-scanner"});
    scan_hdr.addArg("client-header");
    scan_hdr.addFileArg(xml);
    const hdr = scan_hdr.addOutputFileArg("wlr-layer-shell-unstable-v1-client-protocol.h");

    const scan_src = b.addSystemCommand(&.{"wayland-scanner"});
    scan_src.addArg("private-code");
    scan_src.addFileArg(xml);
    const src = scan_src.addOutputFileArg("wlr-layer-shell-unstable-v1-client-protocol.c");

    // xdg-shell protocol (needed for xdg_popup_interface referenced by wlr-layer-shell)
    const xdg_xml = b.path("protocols/xdg-shell.xml");

    const xdg_scan_hdr = b.addSystemCommand(&.{"wayland-scanner"});
    xdg_scan_hdr.addArg("client-header");
    xdg_scan_hdr.addFileArg(xdg_xml);
    const xdg_hdr = xdg_scan_hdr.addOutputFileArg("xdg-shell-client-protocol.h");

    const xdg_scan_src = b.addSystemCommand(&.{"wayland-scanner"});
    xdg_scan_src.addArg("private-code");
    xdg_scan_src.addFileArg(xdg_xml);
    const xdg_src = xdg_scan_src.addOutputFileArg("xdg-shell-client-protocol.c");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addCSourceFile(.{ .file = src, .flags = &.{} });
    mod.addCSourceFile(.{ .file = xdg_src, .flags = &.{} });
    mod.addIncludePath(hdr.dirname());
    mod.addIncludePath(xdg_hdr.dirname());
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("EGL", .{});
    mod.linkSystemLibrary("GLESv2", .{});
    mod.linkSystemLibrary("wayland-egl", .{});

    const exe = b.addExecutable(.{
        .name = "ly-colormix-wallpaper",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the wallpaper daemon");
    run_step.dependOn(&run_cmd.step);
}

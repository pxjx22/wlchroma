const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const force_shader_failure = b.option(
        bool,
        "phase3a-force-shader-init-failure",
        "Force effect shader initialization to fail before any GL object is created",
    ) orelse false;
    const daemon_options = b.addOptions();
    daemon_options.addOption(
        bool,
        "phase3a_force_shader_init_failure",
        force_shader_failure,
    );

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

    // Raw-syscall shim shared by the daemon and the IPC test modules.
    const sys_mod = b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- wlchroma (wallpaper daemon) ---
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("sys", sys_mod);
    mod.addOptions("build_options", daemon_options);

    mod.addCSourceFile(.{ .file = src, .flags = &.{} });
    mod.addCSourceFile(.{ .file = xdg_src, .flags = &.{} });
    mod.addIncludePath(hdr.dirname());
    mod.addIncludePath(xdg_hdr.dirname());
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("EGL", .{});
    mod.linkSystemLibrary("GLESv2", .{});
    mod.linkSystemLibrary("wayland-egl", .{});

    const exe = b.addExecutable(.{
        .name = "wlchroma",
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

    // --- wlchroma-ctl (IPC client) ---
    const ctl_mod = b.createModule(.{
        .root_source_file = b.path("src/ctl/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctl_exe = b.addExecutable(.{
        .name = "wlchroma-ctl",
        .root_module = ctl_mod,
    });
    b.installArtifact(ctl_exe);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // IPC tests. The source-root shim keeps production-relative imports under
    // src/ and receives the same "sys" module as the executable.
    const ipc_dispatch_mod = b.createModule(.{
        .root_source_file = b.path("src/test_ipc_exports.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_dispatch_mod.addImport("sys", sys_mod);

    const ipc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ipc/protocol_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_test_mod.addImport("dispatch", ipc_dispatch_mod);
    const ipc_tests = b.addTest(.{
        .root_module = ipc_test_mod,
    });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    const ipc_test_step = b.step("test-ipc", "Run IPC hardening tests");
    ipc_test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_ipc_tests.step);

    const ipc_connection_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ipc/connection_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_connection_test_mod.addImport("ipc", ipc_dispatch_mod);
    const ipc_connection_tests = b.addTest(.{
        .root_module = ipc_connection_test_mod,
    });
    const run_ipc_connection_tests = b.addRunArtifact(ipc_connection_tests);
    test_step.dependOn(&run_ipc_connection_tests.step);
    ipc_test_step.dependOn(&run_ipc_connection_tests.step);

    const ipc_server_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ipc/server_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ipc_server_test_mod.addImport("ipc", ipc_dispatch_mod);
    const ipc_server_tests = b.addTest(.{
        .root_module = ipc_server_test_mod,
    });
    const run_ipc_server_tests = b.addRunArtifact(ipc_server_tests);
    test_step.dependOn(&run_ipc_server_tests.step);
    ipc_test_step.dependOn(&run_ipc_server_tests.step);

    const signal_fd_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ipc/signal_fd_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    signal_fd_test_mod.addImport("ipc", ipc_dispatch_mod);
    const signal_fd_tests = b.addTest(.{
        .root_module = signal_fd_test_mod,
    });
    const run_signal_fd_tests = b.addRunArtifact(signal_fd_tests);
    test_step.dependOn(&run_signal_fd_tests.step);
    ipc_test_step.dependOn(&run_signal_fd_tests.step);

    // Effect mutation tests. effect.zig reaches into ../config/, so the
    // module is rooted at src/ via test_exports.zig.
    const src_exports_mod = b.createModule(.{
        .root_source_file = b.path("src/test_exports.zig"),
        .target = target,
        .optimize = optimize,
    });
    src_exports_mod.addImport("sys", sys_mod);
    src_exports_mod.addOptions("build_options", daemon_options);

    const cpu_bench_sys_mod = b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const cpu_bench_src_mod = b.createModule(.{
        .root_source_file = b.path("src/test_exports.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cpu_bench_src_mod.addImport("sys", cpu_bench_sys_mod);
    cpu_bench_src_mod.addOptions("build_options", daemon_options);
    const cpu_bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/cpu_path.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cpu_bench_mod.addImport("wlchroma_src", cpu_bench_src_mod);
    cpu_bench_mod.addImport("sys", cpu_bench_sys_mod);
    const cpu_bench_exe = b.addExecutable(.{
        .name = "wlchroma-cpu-bench",
        .root_module = cpu_bench_mod,
    });
    const run_cpu_bench = b.addRunArtifact(cpu_bench_exe);
    const cpu_bench_step = b.step(
        "bench-cpu",
        "Benchmark ReleaseFast colormix and SHM expansion",
    );
    cpu_bench_step.dependOn(&run_cpu_bench.step);

    const phase2_test_step = b.step(
        "test-wayland-egl",
        "Run Wayland/EGL lifecycle safety tests",
    );

    const wayland_exports_mod = b.createModule(.{
        .root_source_file = b.path("src/test_wayland_exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wayland_exports_mod.addImport("sys", sys_mod);
    wayland_exports_mod.addOptions("build_options", daemon_options);
    wayland_exports_mod.addCSourceFile(.{ .file = src, .flags = &.{} });
    wayland_exports_mod.addCSourceFile(.{ .file = xdg_src, .flags = &.{} });
    wayland_exports_mod.addIncludePath(hdr.dirname());
    wayland_exports_mod.addIncludePath(xdg_hdr.dirname());
    wayland_exports_mod.linkSystemLibrary("wayland-client", .{});
    wayland_exports_mod.linkSystemLibrary("EGL", .{});
    wayland_exports_mod.linkSystemLibrary("GLESv2", .{});
    wayland_exports_mod.linkSystemLibrary("wayland-egl", .{});

    const output_registration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/output_registration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    output_registration_test_mod.addImport("wayland_test", wayland_exports_mod);
    const output_registration_tests = b.addTest(.{
        .root_module = output_registration_test_mod,
    });
    const run_output_registration_tests = b.addRunArtifact(output_registration_tests);
    phase2_test_step.dependOn(&run_output_registration_tests.step);
    test_step.dependOn(&run_output_registration_tests.step);

    const dimensions_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/dimensions_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dimensions_test_mod.addImport("wlchroma_src", src_exports_mod);
    const dimensions_tests = b.addTest(.{
        .root_module = dimensions_test_mod,
    });
    const run_dimensions_tests = b.addRunArtifact(dimensions_tests);
    phase2_test_step.dependOn(&run_dimensions_tests.step);
    test_step.dependOn(&run_dimensions_tests.step);

    const gpu_epoch_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/gpu_epoch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_epoch_test_mod.addImport("wlchroma_src", src_exports_mod);
    const gpu_epoch_tests = b.addTest(.{
        .root_module = gpu_epoch_test_mod,
    });
    const run_gpu_epoch_tests = b.addRunArtifact(gpu_epoch_tests);
    phase2_test_step.dependOn(&run_gpu_epoch_tests.step);
    test_step.dependOn(&run_gpu_epoch_tests.step);

    const gpu_upload_state_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/gpu_upload_state_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_upload_state_test_mod.addImport("wlchroma_src", src_exports_mod);
    const gpu_upload_state_tests = b.addTest(.{
        .root_module = gpu_upload_state_test_mod,
    });
    const run_gpu_upload_state_tests = b.addRunArtifact(gpu_upload_state_tests);
    phase2_test_step.dependOn(&run_gpu_upload_state_tests.step);
    test_step.dependOn(&run_gpu_upload_state_tests.step);

    const gpu_fallback_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/gpu_fallback_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_fallback_test_mod.addImport("wayland_test", wayland_exports_mod);
    const gpu_fallback_tests = b.addTest(.{
        .root_module = gpu_fallback_test_mod,
    });
    const run_gpu_fallback_tests = b.addRunArtifact(gpu_fallback_tests);
    phase2_test_step.dependOn(&run_gpu_fallback_tests.step);
    test_step.dependOn(&run_gpu_fallback_tests.step);

    const effect_shader_api_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/effect_shader_api_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    effect_shader_api_test_mod.addImport("wayland_test", wayland_exports_mod);
    const effect_shader_api_tests = b.addTest(.{
        .root_module = effect_shader_api_test_mod,
    });
    const run_effect_shader_api_tests = b.addRunArtifact(effect_shader_api_tests);
    phase2_test_step.dependOn(&run_effect_shader_api_tests.step);
    test_step.dependOn(&run_effect_shader_api_tests.step);

    const policy_test_sources = b.addWriteFiles();
    const normal_policy_source = policy_test_sources.addCopyFile(
        b.path("src/render/shader_init_policy.zig"),
        "normal/shader_init_policy.zig",
    );
    const forced_policy_source = policy_test_sources.addCopyFile(
        b.path("src/render/shader_init_policy.zig"),
        "forced/shader_init_policy.zig",
    );

    const normal_policy_mod = b.createModule(.{
        .root_source_file = normal_policy_source,
        .target = target,
        .optimize = optimize,
    });
    const normal_policy_options = b.addOptions();
    normal_policy_options.addOption(
        bool,
        "phase3a_force_shader_init_failure",
        false,
    );
    normal_policy_mod.addOptions("build_options", normal_policy_options);

    const forced_policy_mod = b.createModule(.{
        .root_source_file = forced_policy_source,
        .target = target,
        .optimize = optimize,
    });
    const forced_policy_options = b.addOptions();
    forced_policy_options.addOption(
        bool,
        "phase3a_force_shader_init_failure",
        true,
    );
    forced_policy_mod.addOptions("build_options", forced_policy_options);

    const shader_init_policy_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/shader_init_policy_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    shader_init_policy_test_mod.addImport("normal_policy", normal_policy_mod);
    shader_init_policy_test_mod.addImport("forced_policy", forced_policy_mod);
    const shader_init_policy_tests = b.addTest(.{
        .root_module = shader_init_policy_test_mod,
    });
    const run_shader_init_policy_tests = b.addRunArtifact(shader_init_policy_tests);
    phase2_test_step.dependOn(&run_shader_init_policy_tests.step);
    test_step.dependOn(&run_shader_init_policy_tests.step);

    const surface_detach_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wayland_egl/surface_detach_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    surface_detach_test_mod.addImport("wayland_test", wayland_exports_mod);
    const surface_detach_tests = b.addTest(.{ .root_module = surface_detach_test_mod });
    const run_surface_detach_tests = b.addRunArtifact(surface_detach_tests);
    phase2_test_step.dependOn(&run_surface_detach_tests.step);
    test_step.dependOn(&run_surface_detach_tests.step);

    const effect_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/effect_mutation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    effect_test_mod.addImport("wlchroma_src", src_exports_mod);
    const effect_tests = b.addTest(.{
        .root_module = effect_test_mod,
    });
    const run_effect_tests = b.addRunArtifact(effect_tests);
    test_step.dependOn(&run_effect_tests.step);

    // Color-fade pure-helper tests. color_fade.zig reaches into ../config/, so
    // the module is rooted at src/ via the same test_exports.zig shim.
    const color_fade_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/color_fade_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    color_fade_test_mod.addImport("wlchroma_src", src_exports_mod);
    const color_fade_tests = b.addTest(.{
        .root_module = color_fade_test_mod,
    });
    const run_color_fade_tests = b.addRunArtifact(color_fade_tests);
    test_step.dependOn(&run_color_fade_tests.step);
}

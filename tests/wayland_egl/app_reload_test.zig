const std = @import("std");
const wayland = @import("wayland_test");
const App = wayland.app.App;
const AppConfig = wayland.config.AppConfig;
const Effect = wayland.effect.Effect;
const LoadResult = wayland.config.LoadResult;
const NamedPalette = wayland.config.NamedPalette;
const Rgb = wayland.defaults.Rgb;
const SurfaceState = wayland.surface_state.SurfaceState;

const old_colors: [3]Rgb = .{
    .{ .r = 0x11, .g = 0x22, .b = 0x33 },
    .{ .r = 0x44, .g = 0x55, .b = 0x66 },
    .{ .r = 0x77, .g = 0x88, .b = 0x99 },
};

const new_colors: [3]Rgb = .{
    .{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
    .{ .r = 0xdd, .g = 0xee, .b = 0xff },
    .{ .r = 0x01, .g = 0x02, .b = 0x03 },
};

const FakeTimer = struct {
    calls: usize = 0,
    last_fd: ?std.posix.fd_t = null,
    last_interval: ?std.os.linux.itimerspec = null,
    fail: bool = false,

    pub fn set(self: *@This(), fd: std.posix.fd_t, value: *const std.os.linux.itimerspec) !void {
        self.calls += 1;
        self.last_fd = fd;
        self.last_interval = value.*;
        if (self.fail) return error.TimerFdSetTimeFailed;
    }
};

fn appConfig() AppConfig {
    return .{
        .fps = 15,
        .frame_interval_ns = 66_666_667,
        .effect_type = .colormix,
        .palette = old_colors,
        .speed = 1.25,
        .renderer_scale = 0.5,
        .upscale_filter = .nearest,
    };
}

fn namedPalette(name: []const u8, colors: [3]Rgb) NamedPalette {
    var palette = NamedPalette{
        .name = std.mem.zeroes([64:0]u8),
        .name_len = name.len,
        .colors = colors,
    };
    @memcpy(palette.name[0..name.len], name);
    return palette;
}

fn reloadFixture(allocator: std.mem.Allocator, surface: *SurfaceState) !App {
    const cfg = appConfig();
    const palettes = try allocator.alloc(NamedPalette, 1);
    palettes[0] = namedPalette("old", old_colors);

    var app: App = undefined;
    app.allocator = allocator;
    app.surfaces = .empty;
    try app.surfaces.append(allocator, surface);
    app.configured_effect_type = cfg.effect_type;
    app.effect = Effect.init(&cfg);
    app.animation = wayland.animation_state.AnimationState.init(cfg.speed);
    app.egl_ctx = null;
    app.effect_shader = null;
    app.gpu_upload_state = .{};
    app.blit_shader = null;
    app.timer_armed = true;
    app.frame_interval_ns = cfg.frame_interval_ns;
    app.renderer_scale = cfg.renderer_scale;
    app.upscale_filter = cfg.upscale_filter;
    app.tfd = 42;
    app.palettes = palettes;
    app.active_palette_name_buf = std.mem.zeroes([64]u8);
    @memcpy(app.active_palette_name_buf[0..3], "old");
    app.active_palette_name_len = 3;
    app.current_palette = old_colors;
    app.fade = .{
        .start = old_colors,
        .target = new_colors,
        .start_ns = 100,
        .dur_ns = 200,
    };
    return app;
}

fn reloadCandidate(allocator: std.mem.Allocator) !LoadResult {
    const palettes = try allocator.alloc(NamedPalette, 1);
    palettes[0] = namedPalette("new", new_colors);
    return .{
        .config = .{
            .fps = 30,
            .frame_interval_ns = 33_333_333,
            .effect_type = .colormix,
            .palette = new_colors,
            .speed = 2.0,
            .renderer_scale = 0.75,
            .upscale_filter = .linear,
        },
        .palettes = palettes,
    };
}

test "armed frame interval commits only after timer success" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{};

    try App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer);

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), timer.last_fd.?);
    try std.testing.expectEqual(@as(i64, 0), timer.last_interval.?.it_value.sec);
    try std.testing.expectEqual(@as(i64, 33_333_333), timer.last_interval.?.it_value.nsec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_interval.?.it_interval.sec);
    try std.testing.expectEqual(@as(i64, 33_333_333), timer.last_interval.?.it_interval.nsec);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
}

test "armed frame interval failure preserves stored interval" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{ .fail = true };

    try std.testing.expectError(
        error.TimerFdSetTimeFailed,
        App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer),
    );

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(u32, 66_666_667), app.frame_interval_ns);
}

test "disarmed frame interval updates storage without timer syscall" {
    var app: App = undefined;
    app.timer_armed = false;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{ .fail = true };

    try App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer);

    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
}

test "reload timer failure consumes candidate and preserves runtime snapshot" {
    const allocator = std.testing.allocator;
    var surface: SurfaceState = undefined;
    surface.renderer_scale = 0.5;
    surface.upscale_filter = .nearest;
    var app = try reloadFixture(allocator, &surface);
    defer app.surfaces.deinit(allocator);
    defer allocator.free(app.palettes);
    var candidate = try reloadCandidate(allocator);
    var timer = FakeTimer{ .fail = true };

    const interval_before = app.frame_interval_ns;
    const scale_before = app.renderer_scale;
    const filter_before = app.upscale_filter;
    const configured_effect_before = app.configured_effect_type;
    const effect_before = app.effect;
    const animation_before = app.animation;
    const upload_before = app.gpu_upload_state;
    const palette_before = app.current_palette;
    const fade_before = app.fade;
    const palettes_ptr_before = app.palettes.ptr;
    const active_name_before = app.active_palette_name_buf;
    const active_name_len_before = app.active_palette_name_len;

    try std.testing.expectError(
        error.TimerFdSetTimeFailed,
        App.TestAdapter.applyReloadSnapshot(&app, &candidate, FakeTimer, &timer),
    );

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(interval_before, app.frame_interval_ns);
    try std.testing.expectEqual(scale_before, app.renderer_scale);
    try std.testing.expectEqual(filter_before, app.upscale_filter);
    try std.testing.expectEqual(@as(f32, 0.5), surface.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.nearest, surface.upscale_filter);
    try std.testing.expectEqual(configured_effect_before, app.configured_effect_type);
    try std.testing.expect(std.meta.eql(effect_before, app.effect));
    try std.testing.expectEqualDeep(animation_before, app.animation);
    try std.testing.expectEqualDeep(upload_before, app.gpu_upload_state);
    try std.testing.expectEqual(palette_before, app.current_palette);
    try std.testing.expectEqualDeep(fade_before, app.fade);
    try std.testing.expectEqual(palettes_ptr_before, app.palettes.ptr);
    try std.testing.expectEqualSlices(u8, &active_name_before, &app.active_palette_name_buf);
    try std.testing.expectEqual(active_name_len_before, app.active_palette_name_len);
}

test "reload success transfers candidate palettes exactly once" {
    const allocator = std.testing.allocator;
    var surface: SurfaceState = undefined;
    surface.renderer_scale = 0.5;
    surface.upscale_filter = .nearest;
    var app = try reloadFixture(allocator, &surface);
    defer app.surfaces.deinit(allocator);
    var candidate = try reloadCandidate(allocator);
    const candidate_palettes_ptr = candidate.palettes.ptr;
    var timer = FakeTimer{};

    try App.TestAdapter.applyReloadSnapshot(&app, &candidate, FakeTimer, &timer);
    defer allocator.free(app.palettes);

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
    try std.testing.expectEqual(@as(f32, 0.75), app.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.linear, app.upscale_filter);
    try std.testing.expectEqual(@as(f32, 0.75), surface.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.linear, surface.upscale_filter);
    try std.testing.expectEqual(@as(f32, 2.0), app.animation.speed);
    try std.testing.expectEqual(new_colors, app.current_palette);
    try std.testing.expect(app.fade == null);
    try std.testing.expectEqual(candidate_palettes_ptr, app.palettes.ptr);
    try std.testing.expectEqualStrings("new", app.palettes[0].nameSlice());
    try std.testing.expectEqual(@as(usize, 0), app.active_palette_name_len);
}

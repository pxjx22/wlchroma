const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("wl.zig").c;
const Registry = @import("wayland/registry.zig").Registry;
const OutputInfo = @import("wayland/output.zig").OutputInfo;
const LockSurfaceState = @import("wayland/lock_surface_state.zig").LockSurfaceState;
const SessionLock = @import("wayland/session_lock.zig").SessionLock;
const ColormixRenderer = @import("render/colormix.zig").ColormixRenderer;
const Effect = @import("render/effect.zig").Effect;
const EglContext = @import("render/egl_context.zig").EglContext;
const shader_mod = @import("render/shader.zig");
const BlitShader = shader_mod.BlitShader;
const EffectShader = @import("render/effect_shader.zig").EffectShader;
const defaults = @import("config/defaults.zig");
const config_mod = @import("config/config.zig");
const AppConfig = config_mod.AppConfig;
const UpscaleFilter = config_mod.UpscaleFilter;
const pam = @import("auth/pam.zig");
const PasswordWidget = @import("render/password_widget.zig").PasswordWidget;
const AuthState = @import("render/password_widget.zig").AuthState;

/// Linux evdev key codes used in wl_keyboard key events.
/// wl_keyboard keycode = evdev code + 8.
const KEY_BACKSPACE: u32 = 14 + 8;
const KEY_ENTER: u32 = 28 + 8;
const KEY_ESC: u32 = 1 + 8;
const KEY_LEFTSHIFT: u32 = 42 + 8;
const KEY_RIGHTSHIFT: u32 = 54 + 8;

pub const InputState = struct {
    password_buf: [256]u8 = std.mem.zeroes([256]u8),
    password_len: usize = 0,
    shift_held: bool = false,
    auth_state: AuthState = .idle,
    /// Countdown in render ticks before resetting .failed → .idle (~2s at 15fps).
    fail_timer: u32 = 0,

    pub fn appendChar(self: *InputState, ch: u8) void {
        if (self.password_len < self.password_buf.len - 1) {
            self.password_buf[self.password_len] = ch;
            self.password_len += 1;
        }
    }

    pub fn popChar(self: *InputState) void {
        if (self.password_len > 0) {
            self.password_len -= 1;
            self.password_buf[self.password_len] = 0;
        }
    }

    pub fn clearPassword(self: *InputState) void {
        @memset(self.password_buf[0..self.password_len], 0);
        self.password_len = 0;
    }

    pub fn tickFailTimer(self: *InputState) void {
        if (self.auth_state == .failed) {
            if (self.fail_timer > 0) {
                self.fail_timer -= 1;
            } else {
                self.auth_state = .idle;
            }
        }
    }
};

const KeyEntry = struct { code: u32, ch: u8 };

/// Map evdev keycode (+ 8 offset from wl_keyboard) to printable ASCII.
/// Returns 0 if not a printable character.
fn keycodeToAscii(keycode: u32, shift: bool) u8 {
    // US layout mapping: evdev code + 8 (wl_keyboard keycode)
    const normal = [_]KeyEntry{
        .{ .code = 2 + 8, .ch = '1' },   .{ .code = 3 + 8, .ch = '2' },
        .{ .code = 4 + 8, .ch = '3' },   .{ .code = 5 + 8, .ch = '4' },
        .{ .code = 6 + 8, .ch = '5' },   .{ .code = 7 + 8, .ch = '6' },
        .{ .code = 8 + 8, .ch = '7' },   .{ .code = 9 + 8, .ch = '8' },
        .{ .code = 10 + 8, .ch = '9' },  .{ .code = 11 + 8, .ch = '0' },
        .{ .code = 12 + 8, .ch = '-' },  .{ .code = 13 + 8, .ch = '=' },
        .{ .code = 16 + 8, .ch = 'q' },  .{ .code = 17 + 8, .ch = 'w' },
        .{ .code = 18 + 8, .ch = 'e' },  .{ .code = 19 + 8, .ch = 'r' },
        .{ .code = 20 + 8, .ch = 't' },  .{ .code = 21 + 8, .ch = 'y' },
        .{ .code = 22 + 8, .ch = 'u' },  .{ .code = 23 + 8, .ch = 'i' },
        .{ .code = 24 + 8, .ch = 'o' },  .{ .code = 25 + 8, .ch = 'p' },
        .{ .code = 26 + 8, .ch = '[' },  .{ .code = 27 + 8, .ch = ']' },
        .{ .code = 30 + 8, .ch = 'a' },  .{ .code = 31 + 8, .ch = 's' },
        .{ .code = 32 + 8, .ch = 'd' },  .{ .code = 33 + 8, .ch = 'f' },
        .{ .code = 34 + 8, .ch = 'g' },  .{ .code = 35 + 8, .ch = 'h' },
        .{ .code = 36 + 8, .ch = 'j' },  .{ .code = 37 + 8, .ch = 'k' },
        .{ .code = 38 + 8, .ch = 'l' },  .{ .code = 39 + 8, .ch = ';' },
        .{ .code = 40 + 8, .ch = '\'' }, .{ .code = 43 + 8, .ch = '\\' },
        .{ .code = 44 + 8, .ch = 'z' },  .{ .code = 45 + 8, .ch = 'x' },
        .{ .code = 46 + 8, .ch = 'c' },  .{ .code = 47 + 8, .ch = 'v' },
        .{ .code = 48 + 8, .ch = 'b' },  .{ .code = 49 + 8, .ch = 'n' },
        .{ .code = 50 + 8, .ch = 'm' },  .{ .code = 51 + 8, .ch = ',' },
        .{ .code = 52 + 8, .ch = '.' },  .{ .code = 53 + 8, .ch = '/' },
        .{ .code = 57 + 8, .ch = ' ' },
    };
    const shifted = [_]KeyEntry{
        .{ .code = 2 + 8, .ch = '!' },   .{ .code = 3 + 8, .ch = '@' },
        .{ .code = 4 + 8, .ch = '#' },   .{ .code = 5 + 8, .ch = '$' },
        .{ .code = 6 + 8, .ch = '%' },   .{ .code = 7 + 8, .ch = '^' },
        .{ .code = 8 + 8, .ch = '&' },   .{ .code = 9 + 8, .ch = '*' },
        .{ .code = 10 + 8, .ch = '(' },  .{ .code = 11 + 8, .ch = ')' },
        .{ .code = 12 + 8, .ch = '_' },  .{ .code = 13 + 8, .ch = '+' },
        .{ .code = 16 + 8, .ch = 'Q' },  .{ .code = 17 + 8, .ch = 'W' },
        .{ .code = 18 + 8, .ch = 'E' },  .{ .code = 19 + 8, .ch = 'R' },
        .{ .code = 20 + 8, .ch = 'T' },  .{ .code = 21 + 8, .ch = 'Y' },
        .{ .code = 22 + 8, .ch = 'U' },  .{ .code = 23 + 8, .ch = 'I' },
        .{ .code = 24 + 8, .ch = 'O' },  .{ .code = 25 + 8, .ch = 'P' },
        .{ .code = 26 + 8, .ch = '{' },  .{ .code = 27 + 8, .ch = '}' },
        .{ .code = 30 + 8, .ch = 'A' },  .{ .code = 31 + 8, .ch = 'S' },
        .{ .code = 32 + 8, .ch = 'D' },  .{ .code = 33 + 8, .ch = 'F' },
        .{ .code = 34 + 8, .ch = 'G' },  .{ .code = 35 + 8, .ch = 'H' },
        .{ .code = 36 + 8, .ch = 'J' },  .{ .code = 37 + 8, .ch = 'K' },
        .{ .code = 38 + 8, .ch = 'L' },  .{ .code = 39 + 8, .ch = ':' },
        .{ .code = 40 + 8, .ch = '"' },  .{ .code = 43 + 8, .ch = '|' },
        .{ .code = 44 + 8, .ch = 'Z' },  .{ .code = 45 + 8, .ch = 'X' },
        .{ .code = 46 + 8, .ch = 'C' },  .{ .code = 47 + 8, .ch = 'V' },
        .{ .code = 48 + 8, .ch = 'B' },  .{ .code = 49 + 8, .ch = 'N' },
        .{ .code = 50 + 8, .ch = 'M' },  .{ .code = 51 + 8, .ch = '<' },
        .{ .code = 52 + 8, .ch = '>' },  .{ .code = 53 + 8, .ch = '?' },
        .{ .code = 57 + 8, .ch = ' ' },
    };

    const table = if (shift) &shifted else &normal;
    for (table) |entry| {
        if (entry.code == keycode) return entry.ch;
    }
    return 0;
}

pub const LockApp = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: Registry,
    outputs: std.ArrayList(OutputInfo),
    surfaces: std.ArrayList(LockSurfaceState),
    effect: Effect,
    egl_ctx: ?EglContext,
    effect_shader: ?EffectShader,
    blit_shader: ?BlitShader,
    session_lock: SessionLock,
    keyboard: ?*c.wl_keyboard,
    input_state: InputState,
    password_widget: ?PasswordWidget,
    running: bool,
    frame_interval_ns: u32,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,

    // File-scope keyboard listener — must outlive the wl_keyboard object.
    const keyboard_listener = c.wl_keyboard_listener{
        .keymap = kbKeymap,
        .enter = kbEnter,
        .leave = kbLeave,
        .key = kbKey,
        .modifiers = kbModifiers,
        .repeat_info = kbRepeatInfo,
    };

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !LockApp {
        const display = c.wl_display_connect(null) orelse {
            std.debug.print("error: failed to connect to Wayland display\n", .{});
            return error.DisplayConnectFailed;
        };
        errdefer c.wl_display_disconnect(display);

        var effect = Effect.init(&config);

        var app = LockApp{
            .allocator = allocator,
            .display = display,
            .registry = Registry{},
            .outputs = .{},
            .surfaces = .{},
            .effect = effect,
            .egl_ctx = null,
            .effect_shader = null,
            .blit_shader = null,
            .session_lock = undefined, // set after registry bind
            .keyboard = null,
            .input_state = .{},
            .password_widget = null,
            .running = true,
            .frame_interval_ns = config.frame_interval_ns,
            .renderer_scale = config.renderer_scale,
            .upscale_filter = config.upscale_filter,
        };
        errdefer app.registry.deinit();
        errdefer {
            for (app.outputs.items) |*out| out.deinit();
            app.outputs.deinit(allocator);
        }
        errdefer if (app.egl_ctx) |*ctx| ctx.deinit();

        try app.registry.bind(display, &app.outputs, allocator);

        const MAX_OUTPUTS = 32;
        try app.outputs.ensureTotalCapacity(allocator, MAX_OUTPUTS);

        // 1st roundtrip: bind all globals.
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
        // 2nd roundtrip: collect output done events.
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

        if (app.registry.compositor == null) {
            std.debug.print("error: compositor not available\n", .{});
            return error.MissingCompositor;
        }
        if (app.registry.shm == null) {
            std.debug.print("error: wl_shm not available\n", .{});
            return error.MissingShm;
        }
        if (app.registry.session_lock_manager == null) {
            std.debug.print("error: ext_session_lock_manager_v1 not available — compositor does not support session locking\n", .{});
            return error.MissingSessionLockManager;
        }

        std.debug.print("bound: compositor={} shm={} session_lock_manager={} seat={}\n", .{
            app.registry.compositor != null,
            app.registry.shm != null,
            app.registry.session_lock_manager != null,
            app.registry.seat != null,
        });

        app.egl_ctx = EglContext.init(display) catch |err| blk: {
            std.debug.print("EGL init failed: {}, falling back to CPU path\n", .{err});
            break :blk null;
        };

        if (app.egl_ctx == null and app.effect.isGpuOnly()) {
            const name = @tagName(config.effect_type);
            std.debug.print("effect {s} requires GPU; falling back to colormix on CPU path\n", .{name});
            effect = Effect{ .colormix = ColormixRenderer.init(
                config.palette[0],
                config.palette[1],
                config.palette[2],
                config.frame_advance_ms,
                config.speed,
            ) };
            app.effect = effect;
        }

        // Initialise session lock — call startLock() here so we can create
        // surfaces before the roundtrip that collects the `locked` event.
        app.session_lock = SessionLock.init(app.registry.session_lock_manager.?);
        app.session_lock.startLock();

        for (app.outputs.items) |*out| {
            if (out.done) {
                std.debug.print("output: {s} {}x{} refresh={}mHz\n", .{ out.name, out.width, out.height, out.refresh_mhz });
            }
        }

        return app;
    }

    pub fn run(self: *LockApp) !void {
        if (self.session_lock.lock == null) return error.LockNotStarted;

        // Pre-allocate to prevent ArrayList realloc invalidating pointers used
        // as listener userdata.
        try self.surfaces.ensureTotalCapacity(self.allocator, self.outputs.items.len);

        for (self.outputs.items) |*out| {
            if (!out.done) continue;

            const surface_state = try LockSurfaceState.create(
                self.allocator,
                self.registry.compositor.?,
                self.registry.shm.?,
                self.session_lock.lock.?,
                out,
                self.display,
                &self.effect,
                &self.running,
                if (self.egl_ctx) |*ctx| ctx else null,
                self.renderer_scale,
                self.upscale_filter,
            );
            try self.surfaces.append(self.allocator, surface_state);
        }

        // Attach listeners and do initial commit for each surface.
        for (self.surfaces.items) |*s| {
            s.attach();
        }

        // First roundtrip: dispatches configure events for all surfaces.
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;
        // Second roundtrip: flushes ack_configure+buffer commits; collects the `locked` event.
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;
        std.debug.print("LockApp.run: after roundtrips locked={} finished={}\n", .{ self.session_lock.locked, self.session_lock.finished });

        if (self.session_lock.finished) {
            std.debug.print("error: compositor rejected the lock request (finished event received)\n", .{});
            return error.LockRejected;
        }

        if (!self.session_lock.locked) {
            std.debug.print("warning: `locked` event not yet received after roundtrip\n", .{});
        }

        // Block SIGTERM/SIGHUP/SIGINT now that the compositor has locked the session.
        // This prevents external processes from killing the lock screen.
        // Signals are unblocked immediately before unlock_and_destroy (see kbKey).
        blockLockSignals();

        // Bind keyboard for input handling.
        if (self.registry.seat) |seat| {
            self.keyboard = c.wl_seat_get_keyboard(seat);
            if (self.keyboard) |kb| {
                _ = c.wl_keyboard_add_listener(kb, &LockApp.keyboard_listener, self);
            }
        } else {
            std.debug.print("warning: no wl_seat available, keyboard input disabled\n", .{});
        }

        // Initialize GLES2 shaders using the first available EGL surface.
        if (self.egl_ctx) |*ctx| {
            var shader_ready = false;
            for (self.surfaces.items) |*s| {
                if (s.egl_surface) |*egl_surf| {
                    if (!egl_surf.makeCurrent(ctx)) {
                        std.debug.print("shader init: makeCurrent failed, trying next surface\n", .{});
                        continue;
                    }
                    self.effect_shader = EffectShader.init(&self.effect) catch |err| blk: {
                        std.debug.print("FATAL: EffectShader.init failed: {}\n", .{err});
                        break :blk null;
                    };
                    if (self.effect_shader) |*sh| sh.bind(&self.effect);

                    if (self.renderer_scale < 1.0) {
                        self.blit_shader = BlitShader.init() catch |err| blk: {
                            std.debug.print("BlitShader.init failed: {} -- offscreen disabled\n", .{err});
                            break :blk null;
                        };
                        if (self.blit_shader) |*bs| {
                            bs.bind();
                        } else {
                            for (self.surfaces.items) |*surf| {
                                if (surf.offscreen) |*ofs| {
                                    ofs.deinit();
                                    surf.offscreen = null;
                                }
                            }
                        }
                    }
                    shader_ready = true;
                    break;
                }
            }
            if (!shader_ready) {
                std.debug.print("warning: no EGL surface available; GPU rendering disabled\n", .{});
            }
        }

        // --- poll+timerfd main loop ---
        const tfd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        defer posix.close(tfd);

        const timer_ns: u32 = self.frame_interval_ns;
        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = timer_ns },
            .it_interval = .{ .sec = 0, .nsec = timer_ns },
        };
        try posix.timerfd_settime(tfd, .{}, &interval, null);

        const wl_fd: posix.fd_t = c.wl_display_get_fd(self.display);

        var fds = [2]posix.pollfd{
            .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = tfd, .events = linux.POLL.IN, .revents = 0 },
        };

        while (self.running) {
            if (c.wl_display_flush(self.display) < 0) {
                std.debug.print("wl_display_flush error, exiting\n", .{});
                break;
            }

            const prep = c.wl_display_prepare_read(self.display);
            if (prep != 0) {
                _ = c.wl_display_dispatch_pending(self.display);
                continue;
            }

            fds[0].revents = 0;
            fds[1].revents = 0;
            _ = posix.poll(&fds, -1) catch |err| {
                c.wl_display_cancel_read(self.display);
                std.debug.print("poll error: {}\n", .{err});
                break;
            };

            if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("Wayland socket HUP/ERR\n", .{});
                break;
            }

            if (fds[1].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("timerfd HUP/ERR, exiting\n", .{});
                break;
            }

            if (fds[0].revents & linux.POLL.IN != 0) {
                if (c.wl_display_read_events(self.display) < 0) {
                    std.debug.print("wl_display_read_events error\n", .{});
                    break;
                }
            } else {
                c.wl_display_cancel_read(self.display);
            }

            _ = c.wl_display_dispatch_pending(self.display);

            // Check for compositor-rejected lock mid-session.
            if (self.session_lock.finished) {
                std.debug.print("error: compositor revoked the lock (finished event)\n", .{});
                break;
            }

            if (fds[1].revents & linux.POLL.IN != 0) {
                var buf: [8]u8 = undefined;
                _ = posix.read(tfd, &buf) catch {};

                // Advance effect animation once per tick, regardless of output count.
                const now_ms: u32 = @truncate(@as(u64, @intCast(@max(0, std.time.milliTimestamp()))));
                self.effect.maybeAdvance(now_ms);

                const sh_ptr: ?*const EffectShader = if (self.effect_shader) |*sh| sh else null;
                const blit_ptr: ?*const BlitShader = if (self.blit_shader) |*bs| bs else null;
                self.input_state.tickFailTimer();
                for (self.surfaces.items) |*s| {
                    s.renderTick(sh_ptr, blit_ptr, &self.input_state);
                }
            }
        }
    }

    pub fn deinit(self: *LockApp) void {
        if (self.keyboard) |kb| {
            c.wl_keyboard_destroy(kb);
            self.keyboard = null;
        }
        // password_widget is owned by each LockSurfaceState and cleaned up in teardown.

        if (self.egl_ctx) |*ctx| {
            for (self.surfaces.items) |*s| {
                if (s.dead) continue;
                if (s.egl_surface) |*egl_surf| {
                    _ = egl_surf.makeCurrent(ctx);
                    break;
                }
            }
        }
        if (self.blit_shader) |*bs| bs.deinit();
        self.blit_shader = null;
        if (self.effect_shader) |*sh| sh.deinit();
        self.effect_shader = null;

        if (self.egl_ctx) |*ctx| {
            _ = c.eglMakeCurrent(ctx.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        }

        for (self.surfaces.items) |*s| {
            s.deinit();
        }
        self.surfaces.deinit(self.allocator);

        for (self.outputs.items) |*out| {
            out.deinit();
        }
        self.outputs.deinit(self.allocator);

        if (self.egl_ctx) |*ctx| ctx.deinit();

        self.registry.deinit();
        c.wl_display_disconnect(self.display);
    }
};

// --- Signal handling ---

fn blockLockSignals() void {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.TERM);
    linux.sigaddset(&mask, linux.SIG.HUP);
    linux.sigaddset(&mask, linux.SIG.INT);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
}

pub fn unblockLockSignals() void {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.TERM);
    linux.sigaddset(&mask, linux.SIG.HUP);
    linux.sigaddset(&mask, linux.SIG.INT);
    _ = linux.sigprocmask(linux.SIG.UNBLOCK, &mask, null);
}

// --- wl_keyboard callbacks ---

fn kbKeymap(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = format;
    // Close the fd to avoid leaking it; we don't use the keymap for the MVP.
    _ = std.os.linux.close(fd);
    _ = size;
}

fn kbEnter(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    surface: ?*c.wl_surface,
    keys: ?*c.wl_array,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;
}

fn kbLeave(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    surface: ?*c.wl_surface,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
}

/// Key event handler — full password entry flow.
fn kbKey(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    time: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time;
    const self: *LockApp = @ptrCast(@alignCast(data));

    const pressed = state == 1; // WL_KEYBOARD_KEY_STATE_PRESSED
    const released = state == 0;

    // Track shift modifier.
    if (key == KEY_LEFTSHIFT or key == KEY_RIGHTSHIFT) {
        self.input_state.shift_held = pressed;
        return;
    }
    if (!pressed) return;

    // Ignore input while auth is in progress or already failed (waiting for timer).
    if (self.input_state.auth_state == .pending) return;
    if (self.input_state.auth_state == .failed) return;

    if (key == KEY_ESC) {
        self.input_state.clearPassword();
        return;
    }

    if (key == KEY_BACKSPACE) {
        self.input_state.popChar();
        return;
    }

    if (key == KEY_ENTER) {
        self.input_state.auth_state = .pending;
        // Resolve username from the real UID — do not trust $USER/$LOGNAME (attacker-controlled).
        const username_z: [:0]const u8 = blk: {
            const uid = c.getuid();
            const pw = c.getpwuid(uid);
            if (pw != null and pw.*.pw_name != null) {
                break :blk std.mem.span(pw.*.pw_name);
            }
            break :blk "root";
        };
        // Copy password to local buffer, then zero it in InputState before calling PAM.
        var pw_copy: [256]u8 = std.mem.zeroes([256]u8);
        const pw_len = self.input_state.password_len;
        @memcpy(pw_copy[0..pw_len], self.input_state.password_buf[0..pw_len]);
        self.input_state.clearPassword();
        const password = pw_copy[0..pw_len];
        if (pam.authenticate(username_z, password)) {
            self.input_state.auth_state = .success;
            unblockLockSignals();
            self.session_lock.unlockAndDestroy();
            _ = c.wl_display_roundtrip(self.display);
            self.running = false;
        } else {
            std.debug.print("authentication failed\n", .{});
            self.input_state.auth_state = .failed;
            self.input_state.fail_timer = 30; // ~2s at 15fps
        }
        @memset(pw_copy[0..pw_len], 0);
        return;
    }

    // Printable character.
    if (self.input_state.auth_state == .idle) {
        const ch = keycodeToAscii(key, self.input_state.shift_held);
        if (ch != 0) {
            self.input_state.appendChar(ch);
        }
    }
    _ = released;
}

fn kbModifiers(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = mods_depressed;
    _ = mods_latched;
    _ = mods_locked;
    _ = group;
}

fn kbRepeatInfo(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = rate;
    _ = delay;
}

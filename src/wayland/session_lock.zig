const std = @import("std");
const c = @import("../wl.zig").c;

pub const LockSurface = struct {
    wl_surface: ?*c.wl_surface,
    lock_surface: ?*c.ext_session_lock_surface_v1,

    pub fn create(
        compositor: *c.wl_compositor,
        lock: *c.ext_session_lock_v1,
        wl_output: ?*c.wl_output,
    ) !LockSurface {
        const wl_surf = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surf);

        const lock_surf = c.ext_session_lock_v1_get_lock_surface(
            lock,
            wl_surf,
            wl_output,
        ) orelse return error.LockSurfaceCreateFailed;

        return LockSurface{
            .wl_surface = wl_surf,
            .lock_surface = lock_surf,
        };
    }

    pub fn destroy(self: *LockSurface) void {
        if (self.lock_surface) |ls| {
            c.ext_session_lock_surface_v1_destroy(ls);
            self.lock_surface = null;
        }
        if (self.wl_surface) |ws| {
            c.wl_surface_destroy(ws);
            self.wl_surface = null;
        }
    }
};

pub const SessionLock = struct {
    manager: *c.ext_session_lock_manager_v1,
    lock: ?*c.ext_session_lock_v1 = null,
    locked: bool = false,
    finished: bool = false,

    const lock_listener = c.ext_session_lock_v1_listener{
        .locked = onLocked,
        .finished = onFinished,
    };

    pub fn init(manager: *c.ext_session_lock_manager_v1) SessionLock {
        return .{
            .manager = manager,
            .lock = null,
            .locked = false,
            .finished = false,
        };
    }

    /// Request the compositor to lock the session.  Call immediately after
    /// creating all LockSurfaces so the compositor can send `locked` as soon
    /// as it has a covered frame on every output.
    pub fn startLock(self: *SessionLock) void {
        const lock_obj = c.ext_session_lock_manager_v1_lock(self.manager);
        self.lock = lock_obj;
        if (lock_obj) |l| {
            _ = c.ext_session_lock_v1_add_listener(l, &lock_listener, self);
        }
    }

    /// Call after successful PAM authentication.  Must be followed by
    /// wl_display_roundtrip before process exit (protocol requirement).
    pub fn unlockAndDestroy(self: *SessionLock) void {
        if (self.lock) |l| {
            c.ext_session_lock_v1_unlock_and_destroy(l);
            self.lock = null;
        }
    }

    /// Call when `finished` event arrived before `locked` (compositor rejected).
    pub fn destroyRejected(self: *SessionLock) void {
        if (self.lock) |l| {
            c.ext_session_lock_v1_destroy(l);
            self.lock = null;
        }
    }
};

fn onLocked(data: ?*anyopaque, lock: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = lock;
    const self: *SessionLock = @ptrCast(@alignCast(data));
    self.locked = true;
    std.debug.print("session lock: locked\n", .{});
}

fn onFinished(data: ?*anyopaque, lock: ?*c.ext_session_lock_v1) callconv(.c) void {
    _ = lock;
    const self: *SessionLock = @ptrCast(@alignCast(data));
    self.finished = true;
    std.debug.print("session lock: finished (compositor rejected or revoked lock)\n", .{});
}

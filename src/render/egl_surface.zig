const std = @import("std");
const c = @import("../wl.zig").c;
const EglContext = @import("egl_context.zig").EglContext;

comptime {
    // EGLNativeWindowType is c_ulong on Wayland/X11 EGL platforms.
    // We cast wl_egl_window pointers to it via @intFromPtr, which is
    // only safe if pointers and c_ulong have the same size.
    if (@sizeOf(c.EGLNativeWindowType) != @sizeOf(*anyopaque)) {
        @compileError("EGLNativeWindowType size differs from pointer size; " ++
            "@intFromPtr cast in EglSurface.create is not safe on this platform");
    }
}

pub const EglSurface = struct {
    egl_window: *c.wl_egl_window,
    egl_surface: c.EGLSurface,
    egl_display: c.EGLDisplay, // borrowed from EglContext, not owned

    pub fn create(
        ctx: *const EglContext,
        wl_surface: *c.wl_surface,
        width: u32,
        height: u32,
    ) !EglSurface {
        const egl_window = c.wl_egl_window_create(wl_surface, @intCast(width), @intCast(height))
            orelse return error.EglWindowCreateFailed;
        errdefer c.wl_egl_window_destroy(egl_window);

        // EGLNativeWindowType is c_ulong on X11/Wayland-EGL platforms,
        // so convert the pointer to an integer rather than using @ptrCast.
        const egl_surface = c.eglCreateWindowSurface(
            ctx.display,
            ctx.config,
            @intFromPtr(egl_window),
            null,
        );
        if (egl_surface == c.EGL_NO_SURFACE) {
            return error.EglSurfaceCreateFailed;
        }

        return EglSurface{
            .egl_window = egl_window,
            .egl_surface = egl_surface,
            .egl_display = ctx.display,
        };
    }

    pub fn resize(self: *EglSurface, width: u32, height: u32) void {
        c.wl_egl_window_resize(self.egl_window, @intCast(width), @intCast(height), 0, 0);
    }

    /// Make this surface current for GLES rendering on the calling thread.
    /// Skips the kernel-crossing eglMakeCurrent call if this surface is
    /// already bound (common case: single output, consecutive frames).
    /// For multi-output setups, context switching still happens when
    /// iterating to a different surface -- this is required and correct.
    pub fn makeCurrent(self: *EglSurface, ctx: *const EglContext) bool {
        // eglGetCurrentSurface is a cheap thread-local query, no kernel crossing.
        if (c.eglGetCurrentSurface(c.EGL_DRAW) == self.egl_surface) return true;
        return c.eglMakeCurrent(ctx.display, self.egl_surface, self.egl_surface, ctx.context) == c.EGL_TRUE;
    }

    /// Present the rendered frame to the compositor.
    pub fn swapBuffers(self: *EglSurface) bool {
        return c.eglSwapBuffers(self.egl_display, self.egl_surface) == c.EGL_TRUE;
    }

    pub fn deinit(self: *EglSurface) void {
        _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
        c.wl_egl_window_destroy(self.egl_window);
    }
};

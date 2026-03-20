const std = @import("std");
const c = @import("../wl.zig").c;

pub const EglContext = struct {
    display: c.EGLDisplay,
    context: c.EGLContext,
    config: c.EGLConfig,

    pub fn init(wl_display: *c.wl_display) !EglContext {
        // 1. Get EGL display from Wayland display.
        //    eglGetDisplay expects EGLNativeDisplayType which is ?*anyopaque.
        const egl_display = c.eglGetDisplay(@as(c.EGLNativeDisplayType, @ptrCast(wl_display)));
        if (egl_display == c.EGL_NO_DISPLAY) return error.EglNoDisplay;

        // 2. Initialize EGL
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(egl_display, &major, &minor) == c.EGL_FALSE) {
            return error.EglInitFailed;
        }
        errdefer _ = c.eglTerminate(egl_display);
        std.debug.print("EGL {}.{} initialized\n", .{ major, minor });

        // 3. Bind OpenGL ES API
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == c.EGL_FALSE) {
            return error.EglBindApiFailed;
        }

        // 4. Choose config
        const attribs = [_]c.EGLint{
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      0,
            c.EGL_NONE,
        };
        var config: c.EGLConfig = null;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(egl_display, &attribs, @ptrCast(&config), 1, &num_configs) == c.EGL_FALSE or num_configs == 0) {
            return error.EglNoConfig;
        }

        // 5. Create context (ES 2.0)
        const ctx_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_CLIENT_VERSION, 2,
            c.EGL_NONE,
        };
        const egl_context = c.eglCreateContext(egl_display, config, c.EGL_NO_CONTEXT, &ctx_attribs);
        if (egl_context == c.EGL_NO_CONTEXT) return error.EglContextFailed;

        std.debug.print("EGL context created (ES 2.0)\n", .{});

        return EglContext{
            .display = egl_display,
            .context = egl_context,
            .config = config,
        };
    }

    pub fn deinit(self: *EglContext) void {
        _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroyContext(self.display, self.context);
        _ = c.eglTerminate(self.display);
        // Release per-thread EGL state (TLS, error codes). Safe to call even
        // if no context is current; required for clean valgrind/ASAN exits.
        _ = c.eglReleaseThread();
        self.display = c.EGL_NO_DISPLAY;
        self.context = c.EGL_NO_CONTEXT;
    }
};

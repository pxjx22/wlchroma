pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("ext-session-lock-v1-client-protocol.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES2/gl2.h");
    @cInclude("wayland-egl.h");
    @cInclude("pwd.h");
    @cInclude("unistd.h");
});

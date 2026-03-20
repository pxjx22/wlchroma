const c = @import("../wl.zig").c;
const UpscaleFilter = @import("../config/config.zig").UpscaleFilter;

pub const Offscreen = struct {
    fbo: c.GLuint,
    tex: c.GLuint,
    width: u32,
    height: u32,

    pub fn init(w: u32, h: u32, filter: UpscaleFilter) !Offscreen {
        var tex: c.GLuint = 0;
        c.glGenTextures(1, &tex);
        if (tex == 0) return error.GlGenTexturesFailed;
        errdefer c.glDeleteTextures(1, &tex);

        const gl_filter: c.GLint = switch (filter) {
            .nearest => c.GL_NEAREST,
            .linear => c.GL_LINEAR,
        };

        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, gl_filter);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @intCast(w),
            @intCast(h),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        var fbo: c.GLuint = 0;
        c.glGenFramebuffers(1, &fbo);
        if (fbo == 0) return error.GlGenFramebuffersFailed;
        errdefer c.glDeleteFramebuffers(1, &fbo);

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, tex, 0);

        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        if (status != c.GL_FRAMEBUFFER_COMPLETE) return error.FramebufferIncomplete;

        return Offscreen{
            .fbo = fbo,
            .tex = tex,
            .width = w,
            .height = h,
        };
    }

    /// Reallocate the texture with a new size. The FBO attachment persists --
    /// only the texture storage changes via glTexImage2D.
    /// Returns false if the FBO is incomplete after resize (caller should
    /// destroy this Offscreen and fall back to direct rendering).
    pub fn resize(self: *Offscreen, w: u32, h: u32) bool {
        // Early-return if dimensions have not changed.
        if (self.width == w and self.height == h) return true;

        self.width = w;
        self.height = h;
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @intCast(w),
            @intCast(h),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        // Validate FBO completeness after texture reallocation.
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (status != c.GL_FRAMEBUFFER_COMPLETE) return false;

        return true;
    }

    pub fn bind(self: *const Offscreen) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
    }

    pub fn unbind(_: *const Offscreen) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    }

    pub fn deinit(self: *Offscreen) void {
        c.glDeleteFramebuffers(1, &self.fbo);
        c.glDeleteTextures(1, &self.tex);
    }
};

const c = @import("../wl.zig").c;
const UpscaleFilter = @import("../config/config.zig").UpscaleFilter;
const Extent = @import("../wayland/dimensions.zig").Extent;

pub const Offscreen = struct {
    fbo: c.GLuint,
    tex: c.GLuint,
    extent: Extent,

    pub fn init(extent: Extent, filter: UpscaleFilter) !Offscreen {
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
            extent.c_width,
            extent.c_height,
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
            .extent = extent,
        };
    }

    /// Reallocate the texture with a new size. The FBO attachment persists --
    /// only the texture storage changes via glTexImage2D.
    /// Returns false if the FBO is incomplete after resize (caller should
    /// destroy this Offscreen and fall back to direct rendering).
    pub fn resize(self: *Offscreen, extent: Extent) bool {
        // Early-return if dimensions have not changed.
        if (self.extent.width == extent.width and self.extent.height == extent.height) return true;

        self.extent = extent;
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            extent.c_width,
            extent.c_height,
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

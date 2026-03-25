const std = @import("std");
const c = @import("../wl.zig").c;

pub const AuthState = enum {
    idle,
    pending,
    failed,
    success,
};

pub const PasswordWidget = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_color_loc: c.GLint,
    u_rect_loc: c.GLint,

    const vert_src: [*:0]const u8 =
        \\#version 100
        \\attribute vec2 a_pos;
        \\uniform vec4 u_rect;
        \\void main() {
        \\    // Map [-1,1] quad coords to pixel rect: x0,y0,x1,y1 in NDC
        \\    float x = u_rect.x + (a_pos.x * 0.5 + 0.5) * (u_rect.z - u_rect.x);
        \\    float y = u_rect.y + (a_pos.y * 0.5 + 0.5) * (u_rect.w - u_rect.y);
        \\    gl_Position = vec4(x, y, 0.0, 1.0);
        \\}
    ;

    const frag_src: [*:0]const u8 =
        \\#version 100
        \\precision mediump float;
        \\uniform vec4 u_color;
        \\void main() {
        \\    gl_FragColor = u_color;
        \\}
    ;

    pub fn init() !PasswordWidget {
        const vert = try compileShader(c.GL_VERTEX_SHADER, vert_src);
        defer c.glDeleteShader(vert);

        const frag = try compileShader(c.GL_FRAGMENT_SHADER, frag_src);
        defer c.glDeleteShader(frag);

        const program = c.glCreateProgram();
        if (program == 0) return error.GlCreateProgramFailed;
        errdefer c.glDeleteProgram(program);

        c.glAttachShader(program, vert);
        c.glAttachShader(program, frag);
        c.glLinkProgram(program);

        var link_status: c.GLint = 0;
        c.glGetProgramiv(program, c.GL_LINK_STATUS, &link_status);
        if (link_status == 0) {
            var buf: [512]u8 = std.mem.zeroes([512]u8);
            c.glGetProgramInfoLog(program, 512, null, &buf);
            std.debug.print("password_widget link error: {s}\n", .{@as([*:0]const u8, @ptrCast(&buf))});
            return error.GlLinkFailed;
        }

        c.glDetachShader(program, vert);
        c.glDetachShader(program, frag);

        const a_pos_raw = c.glGetAttribLocation(program, "a_pos");
        if (a_pos_raw < 0) return error.GlAttribNotFound;

        const u_color_loc = c.glGetUniformLocation(program, "u_color");
        const u_rect_loc = c.glGetUniformLocation(program, "u_rect");

        // Unit quad covering [-1,1] in both axes.
        const verts = [_]f32{ -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, 1.0 };
        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        if (vbo == 0) return error.GlGenBuffersFailed;
        errdefer c.glDeleteBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, c.GL_STATIC_DRAW);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

        return PasswordWidget{
            .program = program,
            .vbo = vbo,
            .a_pos_loc = @intCast(a_pos_raw),
            .u_color_loc = u_color_loc,
            .u_rect_loc = u_rect_loc,
        };
    }

    pub fn deinit(self: *PasswordWidget) void {
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }

    /// Draw the password indicator overlay over the current framebuffer.
    /// Must be called while the EGL context is current, after the effect shader draw.
    /// `surface_w/h`: pixel dimensions of the lock surface.
    /// `char_count`: number of characters typed so far.
    /// `auth_state`: current authentication state (idle/failed/success/pending).
    pub fn render(
        self: *const PasswordWidget,
        surface_w: u32,
        surface_h: u32,
        char_count: usize,
        auth_state: AuthState,
    ) void {
        if (surface_w == 0 or surface_h == 0) return;

        const sw: f32 = @floatFromInt(surface_w);
        const sh: f32 = @floatFromInt(surface_h);

        // Background rectangle: 300x60px, centered horizontally, 30% from bottom.
        const bg_w: f32 = 300.0;
        const bg_h: f32 = 60.0;
        const bg_cx: f32 = sw * 0.5;
        const bg_cy: f32 = sh * 0.30;
        const bg_x0: f32 = bg_cx - bg_w * 0.5;
        const bg_y0: f32 = bg_cy - bg_h * 0.5;
        const bg_x1: f32 = bg_cx + bg_w * 0.5;
        const bg_y1: f32 = bg_cy + bg_h * 0.5;

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUseProgram(self.program);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnableVertexAttribArray(self.a_pos_loc);
        c.glVertexAttribPointer(self.a_pos_loc, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);

        // Background color: dark translucent, or red on failure.
        const bg_color: [4]f32 = switch (auth_state) {
            .failed => .{ 0.8, 0.1, 0.1, 0.75 },
            else => .{ 0.05, 0.05, 0.05, 0.70 },
        };

        drawRect(self, sw, sh, bg_x0, bg_y0, bg_x1, bg_y1, bg_color);

        // Asterisk dots: 8x8px white squares, 12px spacing, centered.
        const max_visible: usize = 32;
        const shown = @min(char_count, max_visible);
        if (shown > 0) {
            const dot_w: f32 = 8.0;
            const dot_h: f32 = 8.0;
            const dot_gap: f32 = 12.0;
            const total_w: f32 = @as(f32, @floatFromInt(shown)) * dot_w +
                @as(f32, @floatFromInt(shown - 1)) * dot_gap;
            var dot_x: f32 = bg_cx - total_w * 0.5;
            const dot_cy: f32 = bg_cy;

            var i: usize = 0;
            while (i < shown) : (i += 1) {
                const dx0 = dot_x;
                const dy0 = dot_cy - dot_h * 0.5;
                const dx1 = dot_x + dot_w;
                const dy1 = dot_cy + dot_h * 0.5;
                drawRect(self, sw, sh, dx0, dy0, dx1, dy1, .{ 1.0, 1.0, 1.0, 0.90 });
                dot_x += dot_w + dot_gap;
            }
        }

        c.glDisableVertexAttribArray(self.a_pos_loc);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        c.glUseProgram(0);
        c.glDisable(c.GL_BLEND);
    }

    /// Draw a solid-color axis-aligned rectangle (pixel coords, y=0 at bottom).
    fn drawRect(
        self: *const PasswordWidget,
        sw: f32,
        sh: f32,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        color: [4]f32,
    ) void {
        // Convert pixel coords to NDC [-1,1] (y=0 at bottom).
        const nx0 = x0 / sw * 2.0 - 1.0;
        const ny0 = y0 / sh * 2.0 - 1.0;
        const nx1 = x1 / sw * 2.0 - 1.0;
        const ny1 = y1 / sh * 2.0 - 1.0;

        c.glUniform4f(self.u_color_loc, color[0], color[1], color[2], color[3]);
        c.glUniform4f(self.u_rect_loc, nx0, ny0, nx1, ny1);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    }
};

fn compileShader(shader_type: c.GLenum, src: [*:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(shader_type);
    if (shader == 0) return error.GlCreateShaderFailed;
    errdefer c.glDeleteShader(shader);

    c.glShaderSource(shader, 1, &src, null);
    c.glCompileShader(shader);

    var status: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var buf: [512]u8 = std.mem.zeroes([512]u8);
        c.glGetShaderInfoLog(shader, 512, null, &buf);
        std.debug.print("password_widget shader compile error: {s}\n", .{@as([*:0]const u8, @ptrCast(&buf))});
        return error.GlShaderCompileFailed;
    }
    return shader;
}

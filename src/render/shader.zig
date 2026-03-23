const std = @import("std");
const builtin = @import("builtin");
const c = @import("../wl.zig").c;

pub const BlitShader = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_tex_loc: c.GLint,
    bound: bool,

    const blit_vert_src: [*:0]const u8 =
        \\#version 100
        \\attribute vec2 a_pos;
        \\varying vec2 v_uv;
        \\void main() {
        \\    v_uv = a_pos * 0.5 + 0.5;
        \\    gl_Position = vec4(a_pos, 0.0, 1.0);
        \\}
    ;

    const blit_frag_src: [*:0]const u8 =
        \\#version 100
        \\precision mediump float;
        \\uniform sampler2D u_tex;
        \\varying vec2 v_uv;
        \\void main() {
        \\    gl_FragColor = vec4(texture2D(u_tex, v_uv).rgb, 1.0);
        \\}
    ;

    pub fn init() !BlitShader {
        const vert = try compileShader(c.GL_VERTEX_SHADER, blit_vert_src);
        defer c.glDeleteShader(vert);

        const frag = try compileShader(c.GL_FRAGMENT_SHADER, blit_frag_src);
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
            std.debug.print("blit program link error: {s}\n", .{@as([*:0]const u8, @ptrCast(&buf))});
            return error.GlLinkFailed;
        }

        c.glDetachShader(program, vert);
        c.glDetachShader(program, frag);

        const a_pos_raw = c.glGetAttribLocation(program, "a_pos");
        if (a_pos_raw < 0) return error.GlAttribNotFound;
        const a_pos_loc: c.GLuint = @intCast(a_pos_raw);

        const u_tex_loc = c.glGetUniformLocation(program, "u_tex");
        if (u_tex_loc < 0) return error.GlUniformNotFound;

        // Create a dedicated VBO for the blit fullscreen quad.
        // Same vertex data as the colormix shader -- 32 bytes of GPU memory
        // is negligible and keeps BlitShader fully self-contained.
        const vertices = [_]f32{
            -1.0, -1.0,
            1.0,  -1.0,
            -1.0, 1.0,
            1.0,  1.0,
        };
        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        errdefer c.glDeleteBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(@TypeOf(vertices))),
            &vertices,
            c.GL_STATIC_DRAW,
        );
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

        return BlitShader{
            .program = program,
            .vbo = vbo,
            .a_pos_loc = a_pos_loc,
            .u_tex_loc = u_tex_loc,
            .bound = false,
        };
    }

    /// Bind blit shader state: program, VBO, vertex layout, texture uniform.
    /// Call once after EGL context is current.
    pub fn bind(self: *BlitShader) void {
        c.glUseProgram(self.program);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnableVertexAttribArray(self.a_pos_loc);
        c.glVertexAttribPointer(
            self.a_pos_loc,
            2,
            c.GL_FLOAT,
            c.GL_FALSE,
            0,
            @as(?*const anyopaque, null),
        );
        // u_tex always samples from texture unit 0
        c.glUniform1i(self.u_tex_loc, 0);
        self.bound = true;
    }

    /// Draw the offscreen texture to the current framebuffer (expected: 0).
    /// Binds the blit program, sets up the texture, draws, then restores
    /// the colormix program so subsequent frames work without re-binding.
    pub fn draw(self: *const BlitShader, tex: c.GLuint, effect_program: c.GLuint, effect_vbo: c.GLuint, effect_a_pos: c.GLuint) void {
        if (builtin.mode == .Debug) std.debug.assert(self.bound);

        // Switch to blit program
        c.glUseProgram(self.program);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glVertexAttribPointer(
            self.a_pos_loc,
            2,
            c.GL_FLOAT,
            c.GL_FALSE,
            0,
            @as(?*const anyopaque, null),
        );

        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        // u_tex uniform is set once in bind(); no need to re-upload per draw.

        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        // Restore effect program state so the next frame's effect pass
        // does not need a full re-bind.
        c.glUseProgram(effect_program);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, effect_vbo);
        c.glVertexAttribPointer(
            effect_a_pos,
            2,
            c.GL_FLOAT,
            c.GL_FALSE,
            0,
            @as(?*const anyopaque, null),
        );
    }

    pub fn deinit(self: *BlitShader) void {
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }
};

pub fn compileShader(shader_type: c.GLenum, src: [*:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(shader_type);
    if (shader == 0) return error.GlCreateShaderFailed;
    errdefer c.glDeleteShader(shader);

    const src_ptr: [*c]const u8 = src;
    c.glShaderSource(shader, 1, @ptrCast(&src_ptr), null);
    c.glCompileShader(shader);

    var status: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var buf: [512]u8 = std.mem.zeroes([512]u8);
        c.glGetShaderInfoLog(shader, 512, null, &buf);
        std.debug.print("shader compile error: {s}\n", .{@as([*:0]const u8, @ptrCast(&buf))});
        return error.GlCompileFailed;
    }
    return shader;
}

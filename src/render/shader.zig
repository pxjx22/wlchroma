const std = @import("std");
const c = @import("../wl.zig").c;

pub const ShaderProgram = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_color_loc: c.GLint,

    // Vertex shader: pass-through, position from attribute
    const vert_src: [*:0]const u8 =
        \\#version 100
        \\attribute vec2 a_pos;
        \\void main() {
        \\    gl_Position = vec4(a_pos, 0.0, 1.0);
        \\}
    ;

    // Fragment shader: output a single solid color uniform
    const frag_src: [*:0]const u8 =
        \\#version 100
        \\precision mediump float;
        \\uniform vec3 u_color;
        \\void main() {
        \\    gl_FragColor = vec4(u_color, 1.0);
        \\}
    ;

    pub fn init() !ShaderProgram {
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
            std.debug.print("program link error: {s}\n", .{@as([*:0]const u8, @ptrCast(&buf))});
            return error.GlLinkFailed;
        }

        const a_pos_raw = c.glGetAttribLocation(program, "a_pos");
        if (a_pos_raw < 0) return error.GlAttribNotFound;
        const a_pos_loc: c.GLuint = @intCast(a_pos_raw);

        const u_color_loc = c.glGetUniformLocation(program, "u_color");
        if (u_color_loc < 0) return error.GlUniformNotFound;

        // Upload the fullscreen quad once into a VBO.
        // Four vertices as a triangle strip covering NDC [-1, 1].
        const vertices = [_]f32{
            -1.0, -1.0,
            1.0,  -1.0,
            -1.0, 1.0,
            1.0,  1.0,
        };
        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(@TypeOf(vertices))),
            &vertices,
            c.GL_STATIC_DRAW,
        );
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

        return ShaderProgram{
            .program = program,
            .vbo = vbo,
            .a_pos_loc = a_pos_loc,
            .u_color_loc = u_color_loc,
        };
    }

    /// Draw the fullscreen quad using the currently active EGL context.
    pub fn draw(self: *const ShaderProgram, r: f32, g: f32, b: f32) void {
        c.glUseProgram(self.program);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnableVertexAttribArray(self.a_pos_loc);
        c.glVertexAttribPointer(
            self.a_pos_loc,
            2, // 2 floats per vertex (x, y)
            c.GL_FLOAT,
            c.GL_FALSE,
            0, // stride = 0 (tightly packed)
            @as(?*const anyopaque, null), // offset into VBO
        );
        c.glUniform3f(self.u_color_loc, r, g, b);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        c.glDisableVertexAttribArray(self.a_pos_loc);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    }

    pub fn deinit(self: *ShaderProgram) void {
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }
};

fn compileShader(shader_type: c.GLenum, src: [*:0]const u8) !c.GLuint {
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

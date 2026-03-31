const std = @import("std");
const builtin = @import("builtin");
const c = @import("../wl.zig").c;
const compileShader = @import("shader.zig").compileShader;
const Rgb = @import("../config/defaults.zig").Rgb;

/// Shared GPU pipeline boilerplate for all StandardShader-based effects.
/// Each effect wraps this struct and provides its own fragment shader source.
pub const StandardShader = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_time_loc: c.GLint,
    u_resolution_loc: c.GLint,
    u_phase_loc: c.GLint,
    u_col0_loc: c.GLint,
    u_col1_loc: c.GLint,
    u_col2_loc: c.GLint,
    /// Debug-only flag: set to true after bind() is called.
    bound: bool,

    /// Shared vertex shader: pass-through a_pos to clip space.
    pub const VERT_SRC: [*:0]const u8 =
        \\#version 100
        \\attribute vec2 a_pos;
        \\void main() {
        \\    gl_Position = vec4(a_pos, 0.0, 1.0);
        \\}
    ;

    /// Compile VERT_SRC + provided frag_src, link program, query all
    /// uniform/attribute locations, upload fullscreen quad VBO.
    pub fn init(frag_src: [*:0]const u8) !StandardShader {
        const vert = try compileShader(c.GL_VERTEX_SHADER, VERT_SRC);
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
            var log_len: c.GLsizei = 0;
            c.glGetProgramInfoLog(program, 512, &log_len, &buf);
            const log_slice = buf[0..@intCast(log_len)];
            std.debug.print("standard_shader program link error: {s}\n", .{log_slice});
            return error.GlLinkFailed;
        }

        c.glDetachShader(program, vert);
        c.glDetachShader(program, frag);

        const a_pos_raw = c.glGetAttribLocation(program, "a_pos");
        if (a_pos_raw < 0) return error.GlAttribNotFound;
        const a_pos_loc: c.GLuint = @intCast(a_pos_raw);

        const u_time_loc = lookupUniform(program, "u_time");
        const u_resolution_loc = lookupUniform(program, "u_resolution");
        const u_phase_loc = lookupUniform(program, "u_phase");
        const u_col0_loc = lookupUniform(program, "u_col0");
        const u_col1_loc = lookupUniform(program, "u_col1");
        const u_col2_loc = lookupUniform(program, "u_col2");

        const vertices = [_]f32{
            -1.0, -1.0,
            1.0,  -1.0,
            -1.0, 1.0,
            1.0,  1.0,
        };
        var vbo: c.GLuint = 0;
        c.glGenBuffers(1, &vbo);
        if (vbo == 0) return error.GlGenBuffersFailed;
        errdefer c.glDeleteBuffers(1, &vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(@TypeOf(vertices))),
            &vertices,
            c.GL_STATIC_DRAW,
        );
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

        return StandardShader{
            .program = program,
            .vbo = vbo,
            .a_pos_loc = a_pos_loc,
            .u_time_loc = u_time_loc,
            .u_resolution_loc = u_resolution_loc,
            .u_phase_loc = u_phase_loc,
            .u_col0_loc = u_col0_loc,
            .u_col1_loc = u_col1_loc,
            .u_col2_loc = u_col2_loc,
            .bound = false,
        };
    }

    /// Bind GL state and upload static uniforms (phase + palette).
    /// Call once after the EGL context is made current.
    pub fn bind(self: *StandardShader, phase: f32, palette: [3]Rgb) void {
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
        uploadStaticUniforms(self, phase, palette);
        self.bound = true;
    }

    /// Re-upload static uniforms after configure/resize (program must be current).
    pub fn setStaticUniforms(self: *const StandardShader, phase: f32, palette: [3]Rgb) void {
        uploadStaticUniforms(self, phase, palette);
    }

    fn uploadStaticUniforms(self: *const StandardShader, phase: f32, palette: [3]Rgb) void {
        if (self.u_phase_loc >= 0) {
            c.glUniform1f(self.u_phase_loc, phase);
        }
        inline for (palette, 0..) |rgb, i| {
            const loc = switch (i) {
                0 => self.u_col0_loc,
                1 => self.u_col1_loc,
                2 => self.u_col2_loc,
                else => unreachable,
            };
            if (loc >= 0) {
                c.glUniform3f(
                    loc,
                    @as(f32, @floatFromInt(rgb.r)) / 255.0,
                    @as(f32, @floatFromInt(rgb.g)) / 255.0,
                    @as(f32, @floatFromInt(rgb.b)) / 255.0,
                );
            }
        }
    }

    /// Upload per-frame uniforms: time and resolution.
    pub fn setUniforms(self: *const StandardShader, time: f32, w: f32, h: f32) void {
        if (self.u_time_loc >= 0) {
            c.glUniform1f(self.u_time_loc, time);
        }
        if (self.u_resolution_loc >= 0) {
            c.glUniform2f(self.u_resolution_loc, w, h);
        }
    }

    fn lookupUniform(program: c.GLuint, name: [:0]const u8) c.GLint {
        const loc = c.glGetUniformLocation(program, name.ptr);
        if (loc < 0) {
            std.debug.print("standard_shader warning: uniform {s} optimized out or unavailable\n", .{name});
        }
        return loc;
    }

    pub fn draw(self: *const StandardShader) void {
        if (builtin.mode == .Debug) std.debug.assert(self.bound);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    }

    pub fn deinit(self: *StandardShader) void {
        c.glDisableVertexAttribArray(self.a_pos_loc);
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }
};

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../wl.zig").c;
const compileShader = @import("shader.zig").compileShader;

pub const GlassDriftShader = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_time_loc: c.GLint,
    u_resolution_loc: c.GLint,
    u_phase_loc: c.GLint,
    /// Debug-only flag: set to true after bind() is called.
    bound: bool,

    // Vertex shader: identical pass-through to ColormixShader
    const vert_src: [*:0]const u8 =
        \\#version 100
        \\attribute vec2 a_pos;
        \\void main() {
        \\    gl_Position = vec4(a_pos, 0.0, 1.0);
        \\}
    ;

    // Fragment shader: three sinusoidal pane layers with fixed frosted-glass
    // palette. No loops, no sqrt — arithmetic cost is O(1) per fragment.
    //
    // Color palette (hardcoded constants in shader source):
    //   ice blue    #7BA9CC  → vec3(0.4824, 0.6627, 0.8000)
    //   pale silver #BCC9D8  → vec3(0.7373, 0.7882, 0.8471)
    //   deep slate  #4A6B88  → vec3(0.2902, 0.4196, 0.5333)
    //
    // Uniforms:
    //   u_time       f32  — frameCount * TIME_SCALE * speed (per-frame)
    //   u_resolution vec2 — output pixel dimensions (per-surface)
    //   u_phase      f32  — random session offset (static, set once in bind)
    const frag_src: [*:0]const u8 =
        \\#version 100
        \\precision highp float;
        \\uniform float u_time;
        \\uniform vec2 u_resolution;
        \\uniform float u_phase;
        \\
        \\// Frosted-glass color palette (fixed)
        \\const vec3 ICE_BLUE    = vec3(0.4824, 0.6627, 0.8000);
        \\const vec3 PALE_SILVER = vec3(0.7373, 0.7882, 0.8471);
        \\const vec3 DEEP_SLATE  = vec3(0.2902, 0.4196, 0.5333);
        \\
        \\void main() {
        \\    // Normalized UV with aspect correction
        \\    vec2 uv = gl_FragCoord.xy / u_resolution;
        \\    float aspect = u_resolution.x / u_resolution.y;
        \\    vec2 p = vec2(uv.x * aspect, uv.y);
        \\
        \\    float t = u_time + u_phase;
        \\
        \\    // Three sinusoidal pane layers at different drift directions:
        \\    // horizontal, vertical, and diagonal — each at a different speed
        \\    // to produce a layered parallax glass effect.
        \\    float pane0 = sin(p.x * 2.5 + t * 0.5) * 0.5 + 0.5;
        \\    float pane1 = sin(p.y * 2.0 - t * 0.3 + 1.0) * 0.5 + 0.5;
        \\    float pane2 = sin((p.x - p.y) * 1.5 + t * 0.4 + 2.5) * 0.5 + 0.5;
        \\
        \\    // Layer blend: deep slate base tinted with ice blue and pale silver
        \\    vec3 col = DEEP_SLATE;
        \\    col = mix(col, ICE_BLUE,    pane0 * 0.6);
        \\    col = mix(col, PALE_SILVER, pane1 * 0.5);
        \\    col = mix(col, ICE_BLUE,    pane2 * 0.4);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !GlassDriftShader {
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
            std.debug.print("glass_drift program link error: {s}\n", .{@as([*:0]const u8, @ptrCast(&buf))});
            return error.GlLinkFailed;
        }

        c.glDetachShader(program, vert);
        c.glDetachShader(program, frag);

        const a_pos_raw = c.glGetAttribLocation(program, "a_pos");
        if (a_pos_raw < 0) return error.GlAttribNotFound;
        const a_pos_loc: c.GLuint = @intCast(a_pos_raw);

        const u_time_loc = c.glGetUniformLocation(program, "u_time");
        if (u_time_loc < 0) return error.GlUniformNotFound;
        const u_resolution_loc = c.glGetUniformLocation(program, "u_resolution");
        if (u_resolution_loc < 0) return error.GlUniformNotFound;
        const u_phase_loc = c.glGetUniformLocation(program, "u_phase");
        if (u_phase_loc < 0) return error.GlUniformNotFound;

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

        return GlassDriftShader{
            .program = program,
            .vbo = vbo,
            .a_pos_loc = a_pos_loc,
            .u_time_loc = u_time_loc,
            .u_resolution_loc = u_resolution_loc,
            .u_phase_loc = u_phase_loc,
            .bound = false,
        };
    }

    /// Bind GL state and upload the static phase uniform.
    /// Call once after the EGL context is made current.
    pub fn bind(self: *GlassDriftShader, phase_offset: f32) void {
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
        c.glUniform1f(self.u_phase_loc, phase_offset);
        self.bound = true;
    }

    /// Re-upload phase after configure/resize (program must be current).
    pub fn setStaticUniforms(self: *const GlassDriftShader, phase_offset: f32) void {
        c.glUniform1f(self.u_phase_loc, phase_offset);
    }

    /// Upload per-frame uniforms: time and resolution.
    pub fn setUniforms(self: *const GlassDriftShader, time: f32, resolution_w: f32, resolution_h: f32) void {
        c.glUniform1f(self.u_time_loc, time);
        c.glUniform2f(self.u_resolution_loc, resolution_w, resolution_h);
    }

    pub fn draw(self: *const GlassDriftShader) void {
        if (builtin.mode == .Debug) std.debug.assert(self.bound);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    }

    pub fn deinit(self: *GlassDriftShader) void {
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }
};

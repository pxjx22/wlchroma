const std = @import("std");
const builtin = @import("builtin");
const c = @import("../wl.zig").c;
const defaults = @import("../config/defaults.zig");
const palette_mod = @import("palette.zig");

pub const ShaderProgram = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_time_loc: c.GLint,
    u_resolution_loc: c.GLint,
    u_cos_mod_loc: c.GLint,
    u_sin_mod_loc: c.GLint,
    u_palette_loc: c.GLint,
    /// Debug-only flag: set to true after bind() is called. draw() asserts
    /// this in debug builds to catch missing bind() calls.
    ///
    /// bind() uploads invariant GL state (program, VBO, vertex layout, palette)
    /// once per EGL context. If the EGL context is ever destroyed and recreated,
    /// bind() must be called again on the new context. deinit() does NOT reset
    /// this flag -- after deinit(), the ShaderProgram must not be used (the GL
    /// objects are deleted). In debug builds, draw() will assert(self.bound)
    /// which catches use-after-deinit only if the memory is zeroed/reused.
    bound: bool,

    // Vertex shader: pass-through, position from attribute
    const vert_src: [*:0]const u8 =
        \\#version 100
        \\attribute vec2 a_pos;
        \\void main() {
        \\    gl_Position = vec4(a_pos, 0.0, 1.0);
        \\}
    ;

    // Fragment shader: colormix warp + palette lookup
    // Exact port of ColormixRenderer.renderGrid from colormix.zig
    const frag_src: [*:0]const u8 =
        \\#version 100
        \\precision highp float;
        \\uniform float u_time;
        \\uniform vec2  u_resolution;
        \\uniform float u_cos_mod;
        \\uniform float u_sin_mod;
        \\uniform vec3  u_palette[12];
        \\void main() {
        \\    float px = gl_FragCoord.x - 0.5;
        \\    // Flip Y: GLES gl_FragCoord.y=0 is bottom, Wayland/SHM expects
        \\    // top-left origin. The CPU path uses (yi*2 - hi) where increasing
        \\    // y goes downward; this flip matches that convention.
        \\    float py = u_resolution.y - gl_FragCoord.y - 0.5;
        \\    float uvx = (px * 2.0 - u_resolution.x) / (u_resolution.y * 2.0);
        \\    float uvy = (py * 2.0 - u_resolution.y) / u_resolution.y;
        \\    float uv2x = uvx + uvy;
        \\    float uv2y = uvx + uvy;
        \\    // NOTE: Inner loop iteration order (len -> uv2 update -> uvx/uvy
        \\    // update -> warp) is intentional and must stay matched with the
        \\    // CPU path in colormix.zig renderGrid.
        \\    for (int i = 0; i < 3; i++) {
        \\        float len = sqrt(uvx * uvx + uvy * uvy);
        \\        uv2x += uvx + len;
        \\        uv2y += uvy + len;
        \\        uvx += 0.5 * cos(u_cos_mod + uv2y * 0.2 + u_time * 0.1);
        \\        uvy += 0.5 * sin(u_sin_mod + uv2x - u_time * 0.1);
        \\        float warp = 1.0 * cos(uvx + uvy) - sin(uvx * 0.7 - uvy);
        \\        uvx -= warp;
        \\        uvy -= warp;
        \\    }
        \\    float len = sqrt(uvx * uvx + uvy * uvy);
        \\    int idx = int(mod(floor(len * 5.0), 12.0));
        \\    gl_FragColor = vec4(u_palette[idx], 1.0);
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

        // Detach shaders after successful link so the shader objects can be
        // freed immediately when glDeleteShader is called (via defer above).
        c.glDetachShader(program, vert);
        c.glDetachShader(program, frag);

        const a_pos_raw = c.glGetAttribLocation(program, "a_pos");
        if (a_pos_raw < 0) return error.GlAttribNotFound;
        const a_pos_loc: c.GLuint = @intCast(a_pos_raw);

        const u_time_loc = c.glGetUniformLocation(program, "u_time");
        if (u_time_loc < 0) return error.GlUniformNotFound;
        const u_resolution_loc = c.glGetUniformLocation(program, "u_resolution");
        if (u_resolution_loc < 0) return error.GlUniformNotFound;
        const u_cos_mod_loc = c.glGetUniformLocation(program, "u_cos_mod");
        if (u_cos_mod_loc < 0) return error.GlUniformNotFound;
        const u_sin_mod_loc = c.glGetUniformLocation(program, "u_sin_mod");
        if (u_sin_mod_loc < 0) return error.GlUniformNotFound;
        const u_palette_loc = c.glGetUniformLocation(program, "u_palette[0]");
        if (u_palette_loc < 0) return error.GlUniformNotFound;

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
            .u_time_loc = u_time_loc,
            .u_resolution_loc = u_resolution_loc,
            .u_cos_mod_loc = u_cos_mod_loc,
            .u_sin_mod_loc = u_sin_mod_loc,
            .u_palette_loc = u_palette_loc,
            .bound = false,
        };
    }

    /// Bind invariant GL state: program, VBO, vertex attribute layout, and
    /// the static palette uniform. Call once after the EGL context is made
    /// current (or after a program switch). This is a single-program
    /// single-VBO setup, so the bound state persists across frames until the
    /// context is destroyed.
    pub fn bind(self: *ShaderProgram, palette_data: *const [36]f32) void {
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
        // Upload static palette once at bind time. The palette is constant
        // after ColormixRenderer.init(), so there is no need to re-upload
        // every frame in setUniforms.
        c.glUniform3fv(self.u_palette_loc, 12, @as([*c]const c.GLfloat, @ptrCast(palette_data)));
        self.bound = true;
    }

    /// Upload invariant uniforms that only change on configure/resize.
    /// Call once after bind() and again on each resize.
    pub fn setStaticUniforms(
        self: *const ShaderProgram,
        resolution_w: f32,
        resolution_h: f32,
        cos_mod: f32,
        sin_mod: f32,
    ) void {
        c.glUniform2f(self.u_resolution_loc, resolution_w, resolution_h);
        c.glUniform1f(self.u_cos_mod_loc, cos_mod);
        c.glUniform1f(self.u_sin_mod_loc, sin_mod);
    }

    /// Upload per-frame uniforms for the colormix shader.
    /// Only u_time changes every frame; resolution, cos_mod, sin_mod are
    /// uploaded once via setStaticUniforms().
    pub fn setUniforms(self: *const ShaderProgram, time: f32) void {
        c.glUniform1f(self.u_time_loc, time);
    }

    /// Draw the fullscreen quad. Assumes bind() was called once and
    /// setUniforms() was called for this frame.
    pub fn draw(self: *const ShaderProgram) void {
        if (builtin.mode == .Debug) std.debug.assert(self.bound);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    }

    pub fn deinit(self: *ShaderProgram) void {
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteProgram(self.program);
    }

    /// Pre-compute blended palette colors as a flat array of 36 f32 values
    /// (12 vec3s, normalized to [0.0, 1.0]). Uses palette_mod.blend to match
    /// the CPU path exactly.
    pub fn buildPaletteData(palette: *const [12]defaults.Cell) [36]f32 {
        var data: [36]f32 = undefined;
        for (palette, 0..) |cell, i| {
            const rgb = palette_mod.blend(cell.fg, cell.bg, cell.alpha);
            data[i * 3 + 0] = @as(f32, @floatFromInt(rgb.r)) / 255.0;
            data[i * 3 + 1] = @as(f32, @floatFromInt(rgb.g)) / 255.0;
            data[i * 3 + 2] = @as(f32, @floatFromInt(rgb.b)) / 255.0;
        }
        return data;
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

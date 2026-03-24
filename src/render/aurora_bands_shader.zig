const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const AuroraBandsShader = struct {
    inner: StandardShader,

    // UV fold kaleidoscope: mirrors UV into a wedge via abs()+fract() at two
    // different angles, producing a hard-edged rotating kaleidoscope tile.
    const frag_src: [*:0]const u8 =
        \\#version 100
        \\precision highp float;
        \\uniform float u_time;
        \\uniform vec2 u_resolution;
        \\uniform float u_phase;
        \\uniform vec3 u_col0;
        \\uniform vec3 u_col1;
        \\uniform vec3 u_col2;
        \\
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / u_resolution;
        \\    float aspect = u_resolution.x / u_resolution.y;
        \\    vec2 p = vec2(uv.x * aspect, uv.y);
        \\    float t = u_time + u_phase;
        \\
        \\    // First fold: larger tiles, slower rotation for bolder regions
        \\    float cs = cos(t * 0.12);
        \\    float sn = sin(t * 0.12);
        \\    vec2 r0 = vec2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);
        \\    vec2 f0 = abs(fract(r0 * 3.0) * 2.0 - 1.0);
        \\
        \\    // Second fold: counter-rotating, different scale for visual clash
        \\    float cs2 = cos(-t * 0.07 + 1.5);
        \\    float sn2 = sin(-t * 0.07 + 1.5);
        \\    vec2 r1 = vec2(p.x * cs2 - p.y * sn2, p.x * sn2 + p.y * cs2);
        \\    vec2 f1 = abs(fract(r1 * 5.0) * 2.0 - 1.0);
        \\
        \\    // Blocky quadrant selectors with hard edges
        \\    float quad0 = step(f0.x, f0.y);
        \\    float quad1 = step(f1.y, f1.x);
        \\    // XOR-like pattern for maximum contrast
        \\    float pattern = abs(quad0 - quad1);
        \\
        \\    // Hard color bands based on folded coordinates
        \\    float band0 = step(0.33, f0.x) * step(f0.x, 0.66);
        \\    float band1 = step(0.5, f1.y);
        \\
        \\    vec3 col = u_col0;
        \\    col = mix(col, u_col1, pattern);
        \\    col = mix(col, u_col2, band0 * (1.0 - band1));
        \\    // Override with u_col1 in diagonal regions for pop
        \\    col = mix(col, u_col1, step(0.7, f0.y) * quad1);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !AuroraBandsShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *AuroraBandsShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const AuroraBandsShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const AuroraBandsShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const AuroraBandsShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *AuroraBandsShader) void {
        self.inner.deinit();
    }
};

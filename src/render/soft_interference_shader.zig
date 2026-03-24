const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const SoftInterferenceShader = struct {
    inner: StandardShader,

    // High-frequency Moire: two grid patterns at slightly different scales/angles.
    // Slow beat frequency between 15.0 and 16.0 creates sweeping interference.
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
        \\    // Hard-edged grid A: use step on sin for binary pattern
        \\    float gaxH = step(0.0, sin(p.x * 10.0 + t * 0.7));
        \\    float gaxV = step(0.0, sin(p.y * 10.0 + t * 0.65));
        \\    float gridA = gaxH + gaxV;
        \\
        \\    // Grid B: offset frequency and slight rotation for Moire
        \\    float bx = p.x + p.y * 0.08;
        \\    float by = p.y - p.x * 0.08;
        \\    float gbxH = step(0.0, sin(bx * 11.0 + t * 0.55));
        \\    float gbxV = step(0.0, sin(by * 11.0 + t * 0.52));
        \\    float gridB = gbxH + gbxV;
        \\
        \\    // XOR-like interference from two grids
        \\    float inter = mod(gridA + gridB, 2.0);
        \\
        \\    // Diagonal stripes overlay
        \\    float diag = step(0.0, sin((p.x + p.y) * 8.0 - t * 0.9));
        \\    float diag2 = step(0.0, sin((p.x - p.y) * 9.0 + t * 0.85));
        \\    float diagComb = diag + diag2;
        \\
        \\    // Hard color banding
        \\    float band = floor(inter * 2.0 + diagComb);
        \\    float isBand0 = step(band, 0.5);
        \\    float isBand1 = step(0.5, band) * step(band, 1.5);
        \\    float isBand2 = step(1.5, band) * step(band, 2.5);
        \\    float isBand3 = step(2.5, band);
        \\
        \\    vec3 col = u_col0;
        \\    col = mix(col, u_col1, isBand1);
        \\    col = mix(col, u_col2, isBand2);
        \\    col = mix(col, u_col1, isBand3 * 0.8);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !SoftInterferenceShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *SoftInterferenceShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const SoftInterferenceShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const SoftInterferenceShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const SoftInterferenceShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *SoftInterferenceShader) void {
        self.inner.deinit();
    }
};

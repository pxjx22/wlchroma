const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const CloudChamberShader = struct {
    inner: StandardShader,

    // High-frequency checkerboard warp: floor/mod grid warped by fast sin waves.
    // Hard pixel edges, tight corrupted-pixel / CRT scanline aesthetic.
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
        \\    // Stronger warp for blocky distortion curves
        \\    vec2 wp;
        \\    wp.x = p.x + sin(p.y * 6.0 + t * 0.8) * 0.12;
        \\    wp.y = p.y + sin(p.x * 7.0 - t * 0.65) * 0.10;
        \\
        \\    // Primary checkerboard at scale 8 - larger blocks for pixelation
        \\    vec2 g0 = floor(wp * 8.0);
        \\    float check0 = mod(g0.x + g0.y, 2.0);
        \\
        \\    // Secondary XOR grid - offset and different frequency
        \\    vec2 wp2;
        \\    wp2.x = p.x + sin(p.y * 5.0 - t * 1.0) * 0.08;
        \\    wp2.y = p.y + sin(p.x * 9.0 + t * 0.7) * 0.08;
        \\    vec2 g1 = floor(wp2 * 12.0);
        \\    float check1 = mod(g1.x + g1.y, 2.0);
        \\
        \\    // Bold scanlines - thicker for pixelation
        \\    float scan = step(0.5, fract(p.y * 16.0 - t * 0.3));
        \\    // Horizontal glitch bands
        \\    float hGlitch = step(0.85, fract(p.x * 4.0 + t * 0.2));
        \\
        \\    // XOR the two checkerboards for visual complexity
        \\    float xored = mod(check0 + check1, 2.0);
        \\    vec3 col = mix(u_col0, u_col1, xored);
        \\    // Overlay col2 in XOR-high regions
        \\    col = mix(col, u_col2, xored * check0);
        \\    // Scanline darkening
        \\    col = mix(col, col * 0.4, scan * 0.6);
        \\    // Glitch highlight
        \\    col = mix(col, u_col2, hGlitch * 0.7);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !CloudChamberShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *CloudChamberShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const CloudChamberShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const CloudChamberShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const CloudChamberShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *CloudChamberShader) void {
        self.inner.deinit();
    }
};

const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const PlasmaQuiltShader = struct {
    inner: StandardShader,

    // Triangle wave plasma: abs(fract(x)-0.5)*2.0 replaces sin for harder edges.
    // Four triangle wave terms at spatial freq 6+ produce angular faceted blocks.
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
        \\    // Triangle wave plasma with larger blocks for pixelation
        \\    float tw0 = abs(fract(p.x * 4.0 + t * 0.35) - 0.5) * 2.0;
        \\    float tw1 = abs(fract(p.y * 5.0 - t * 0.28 + 0.3) - 0.5) * 2.0;
        \\    float tw2 = abs(fract((p.x + p.y) * 3.0 + t * 0.22 + 1.0) - 0.5) * 2.0;
        \\    float tw3 = abs(fract((p.x - p.y) * 6.0 - t * 0.18 + 2.1) - 0.5) * 2.0;
        \\
        \\    // Sum creates interference pattern
        \\    float v = (tw0 + tw1 + tw2 + tw3) * 0.25;
        \\
        \\    // Hard posterize into 4 color bands - no gradients
        \\    float band = floor(v * 4.0);
        \\    float isBand0 = step(band, 0.5);
        \\    float isBand1 = step(0.5, band) * step(band, 1.5);
        \\    float isBand2 = step(1.5, band) * step(band, 2.5);
        \\    float isBand3 = step(2.5, band);
        \\
        \\    // Diagonal cross-hatch overlay for texture
        \\    float hatch = step(0.5, fract((p.x + p.y) * 8.0 - t * 0.15));
        \\    float hatch2 = step(0.5, fract((p.x - p.y) * 8.0 + t * 0.12));
        \\
        \\    // Bold color assignment per band
        \\    vec3 col = u_col0;
        \\    col = mix(col, u_col1, isBand1);
        \\    col = mix(col, u_col2, isBand2);
        \\    col = mix(col, u_col1, isBand3);
        \\
        \\    // Hatch overlay adds pixel-friendly texture
        \\    col = mix(col, col * 0.5, hatch * hatch2 * isBand0);
        \\    col = mix(col, u_col0, hatch * (1.0 - hatch2) * isBand2 * 0.4);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !PlasmaQuiltShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *PlasmaQuiltShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const PlasmaQuiltShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const PlasmaQuiltShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const PlasmaQuiltShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *PlasmaQuiltShader) void {
        self.inner.deinit();
    }
};

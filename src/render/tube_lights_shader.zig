const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const TubeLightsShader = struct {
    inner: StandardShader,

    // Scanline / CRT grid: hard step scanlines scrolling vertically, combined
    // with vertical colour bars like a TV test card. Retro monitor aesthetic.
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
        \\    // Thick scanlines for pixelation - scrolling down
        \\    float scan = step(0.5, fract(p.y * 12.0 - t * 0.25));
        \\
        \\    // Vertical bars: 5 bars, animated color cycling
        \\    float barIdx = floor(p.x / aspect * 5.0);
        \\    float barF = fract(p.x / aspect * 5.0);
        \\    float barEdge = step(0.88, barF);
        \\
        \\    // Bar color cycles with time for more motion
        \\    float cycleIdx = mod(barIdx + floor(t * 0.4), 3.0);
        \\    float isBar1 = step(0.5, cycleIdx) * (1.0 - step(1.5, cycleIdx));
        \\    float isBar2 = step(1.5, cycleIdx);
        \\
        \\    vec3 barCol = u_col0;
        \\    barCol = mix(barCol, u_col1, isBar1);
        \\    barCol = mix(barCol, u_col2, isBar2);
        \\
        \\    // Horizontal stripe overlay - moving right
        \\    float hStripe = step(0.5, fract(p.x * 8.0 - t * 0.18));
        \\
        \\    // Blocky interference pattern
        \\    float blockInter = step(0.5, fract((p.x + p.y * 0.5) * 6.0 + t * 0.3));
        \\
        \\    // Bright flash bands sweeping across
        \\    float flash = step(0.92, fract(p.y * 3.0 + t * 0.6));
        \\
        \\    // Compose: bars + scanlines + overlays
        \\    vec3 col = mix(barCol * 0.3, barCol, scan);
        \\    // Bar edge highlights
        \\    col = mix(col, u_col1, barEdge * 0.8);
        \\    // Horizontal stripe overlay
        \\    col = mix(col, col * 0.5, hStripe * (1.0 - scan) * 0.5);
        \\    // Blocky interference
        \\    col = mix(col, u_col2, blockInter * 0.25);
        \\    // Flash sweep
        \\    col = mix(col, u_col1, flash);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !TubeLightsShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *TubeLightsShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const TubeLightsShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const TubeLightsShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const TubeLightsShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *TubeLightsShader) void {
        self.inner.deinit();
    }
};

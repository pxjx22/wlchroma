const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const RibbonOrbitShader = struct {
    inner: StandardShader,

    // Polar angular quantization: atan2 angle quantized into N hard sectors,
    // each sector coloured by index mod 3. Spins like a colour-wheel pie chart.
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
        \\    vec2 c = p - vec2(aspect * 0.5, 0.5);
        \\    float angle = atan(c.y, c.x);
        \\    float r2 = c.x * c.x + c.y * c.y;
        \\
        \\    float TWO_PI = 6.28318530718;
        \\
        \\    // Outer: 8 sectors, counter-clockwise rotation
        \\    float rotated = angle - t * 0.15;
        \\    float sector = floor(fract(rotated / TWO_PI + 0.5) * 8.0);
        \\    float s3 = mod(sector, 3.0);
        \\    float isCol1 = step(0.5, s3) * step(s3, 1.5);
        \\    float isCol2 = step(1.5, s3);
        \\
        \\    // Middle ring: 12 sectors, clockwise, different speed
        \\    float midMask = step(0.04, r2) * (1.0 - step(0.16, r2));
        \\    float sectorM = floor(fract((angle + t * 0.25) / TWO_PI + 0.5) * 12.0);
        \\    float s3m = mod(sectorM, 3.0);
        \\    float isCol1m = step(0.5, s3m) * step(s3m, 1.5);
        \\    float isCol2m = step(1.5, s3m);
        \\
        \\    // Inner core: 5 sectors, fastest counter-rotation
        \\    float innerMask = step(r2, 0.04);
        \\    float sectorB = floor(fract((angle - t * 0.4) / TWO_PI + 0.5) * 5.0);
        \\    float s3b = mod(sectorB, 3.0);
        \\    float isCol1b = step(0.5, s3b) * step(s3b, 1.5);
        \\    float isCol2b = step(1.5, s3b);
        \\
        \\    // Outer region
        \\    vec3 outer = u_col0;
        \\    outer = mix(outer, u_col1, isCol1);
        \\    outer = mix(outer, u_col2, isCol2);
        \\
        \\    // Middle ring
        \\    vec3 mid = u_col2;
        \\    mid = mix(mid, u_col0, isCol1m);
        \\    mid = mix(mid, u_col1, isCol2m);
        \\
        \\    // Inner core
        \\    vec3 inner = u_col1;
        \\    inner = mix(inner, u_col0, isCol1b);
        \\    inner = mix(inner, u_col2, isCol2b);
        \\
        \\    vec3 col = mix(outer, mid, midMask);
        \\    col = mix(col, inner, innerMask);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !RibbonOrbitShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *RibbonOrbitShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const RibbonOrbitShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const RibbonOrbitShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const RibbonOrbitShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *RibbonOrbitShader) void {
        self.inner.deinit();
    }
};

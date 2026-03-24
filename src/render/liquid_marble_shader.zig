const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const LiquidMarbleShader = struct {
    inner: StandardShader,

    // High-frequency fract vein grid: step() on fract() for razor-thin fracture
    // lines. Heavy warp produces cracked-glass / lightning-bolt network look.
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
        \\    // Strong domain warp for curved distortion
        \\    vec2 q = p;
        \\    q.x += sin(q.y * 5.0 + t * 0.35) * 0.18;
        \\    q.y += sin(q.x * 6.0 - t * 0.28) * 0.15;
        \\    q.x += sin(q.y * 3.0 - t * 0.22 + 1.0) * 0.10;
        \\
        \\    // Thicker fracture lines for pixelation - larger threshold
        \\    float line0 = step(0.88, fract(q.x * 5.0 + q.y * 4.0));
        \\    float line1 = step(0.88, fract(q.x * 4.0 - q.y * 6.0 + t * 0.08));
        \\    float line2 = step(0.90, fract(q.x * 7.0 + t * 0.06));
        \\    float line3 = step(0.90, fract(q.y * 8.0 - t * 0.05));
        \\
        \\    float crack = clamp(line0 + line1 + line2 + line3, 0.0, 1.0);
        \\
        \\    // Blocky cell-based background coloring
        \\    vec2 cellId = floor(q * 3.0);
        \\    float cellHash = fract(sin(dot(cellId, vec2(127.1, 311.7))) * 43758.5453);
        \\    float isCell1 = step(0.33, cellHash) * (1.0 - step(0.66, cellHash));
        \\    float isCell2 = step(0.66, cellHash);
        \\
        \\    // Pulsing border on cells
        \\    vec2 cellFract = fract(q * 3.0);
        \\    float cellEdge = step(0.85, cellFract.x) + step(0.85, cellFract.y);
        \\    cellEdge = clamp(cellEdge, 0.0, 1.0);
        \\
        \\    vec3 bg = mix(u_col0, u_col2, isCell1);
        \\    bg = mix(bg, u_col1, isCell2 * 0.6);
        \\    // Cell borders highlight
        \\    bg = mix(bg, u_col2, cellEdge * 0.5);
        \\
        \\    // Cracks in bright accent
        \\    vec3 col = mix(bg, u_col1, crack);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !LiquidMarbleShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *LiquidMarbleShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const LiquidMarbleShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const LiquidMarbleShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const LiquidMarbleShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *LiquidMarbleShader) void {
        self.inner.deinit();
    }
};

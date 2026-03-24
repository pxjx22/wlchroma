const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const StarfieldFogShader = struct {
    inner: StandardShader,

    // Parallax starfield: 3 depth layers at different cell scales for perspective.
    // Distant stars small+dim, close stars large+bright, all hash-generated.
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
        \\    // Layer 0: far stars - small blocks, slow drift
        \\    vec2 drift0 = vec2(t * 0.008, t * 0.006);
        \\    vec2 p0 = p + drift0;
        \\    vec2 cell0 = floor(p0 * 50.0);
        \\    vec2 cv0 = fract(p0 * 50.0) - 0.5;
        \\    float h0 = fract(sin(dot(cell0, vec2(12.9898, 78.233))) * 43758.5453);
        \\    // Blocky stars: larger threshold, bigger size
        \\    float s0 = step(0.92, h0) * step(cv0.x * cv0.x + cv0.y * cv0.y, 0.12);
        \\
        \\    // Layer 1: mid stars - medium blocks, medium drift
        \\    vec2 drift1 = vec2(t * 0.018, t * 0.012);
        \\    vec2 p1 = p + drift1;
        \\    vec2 cell1 = floor(p1 * 25.0);
        \\    vec2 cv1 = fract(p1 * 25.0) - 0.5;
        \\    float h1 = fract(sin(dot(cell1, vec2(27.3157, 51.821))) * 43758.5453);
        \\    float s1 = step(0.90, h1) * step(cv1.x * cv1.x + cv1.y * cv1.y, 0.18);
        \\
        \\    // Layer 2: close stars - large blocks, fast drift, bright
        \\    vec2 drift2 = vec2(t * 0.04, t * 0.025);
        \\    vec2 p2 = p + drift2;
        \\    vec2 cell2 = floor(p2 * 12.0);
        \\    vec2 cv2 = fract(p2 * 12.0) - 0.5;
        \\    float h2 = fract(sin(dot(cell2, vec2(41.921, 89.345))) * 43758.5453);
        \\    float s2 = step(0.88, h2) * step(cv2.x * cv2.x + cv2.y * cv2.y, 0.25);
        \\
        \\    // Layer 3: nebula clouds - very large, slow
        \\    vec2 drift3 = vec2(t * 0.003, t * 0.002);
        \\    vec2 p3 = p + drift3;
        \\    vec2 cell3 = floor(p3 * 4.0);
        \\    float h3 = fract(sin(dot(cell3, vec2(63.217, 97.431))) * 43758.5453);
        \\    float nebula = step(0.75, h3) * 0.3;
        \\
        \\    // Deep space background
        \\    vec3 col = u_col0;
        \\    // Nebula tint
        \\    col = mix(col, u_col2 * 0.15, nebula);
        \\    // Far stars: dim
        \\    col = mix(col, u_col2 * 0.5, s0 * 0.6);
        \\    // Mid stars: medium
        \\    col = mix(col, u_col1, s1 * 0.8);
        \\    // Close stars: bright + colored core
        \\    col = mix(col, u_col1, s2);
        \\    col = mix(col, u_col2, s2 * step(cv2.x * cv2.x + cv2.y * cv2.y, 0.08));
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !StarfieldFogShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *StarfieldFogShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const StarfieldFogShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const StarfieldFogShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const StarfieldFogShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *StarfieldFogShader) void {
        self.inner.deinit();
    }
};

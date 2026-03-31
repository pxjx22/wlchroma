const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const SignalMatrixShader = struct {
    inner: StandardShader,

    // Adapted from a procedural matrix-like digit field.
    // The original white/green palette is remapped onto wlchroma's 3-color palette.
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
        \\mat2 rotate(float angle) {
        \\    float c = cos(angle);
        \\    float s = sin(angle);
        \\    return mat2(c, -s, s, c);
        \\}
        \\
        \\float noise(vec2 p, float t) {
        \\    return sin(p.x * 10.0) * sin(p.y * (3.0 + sin(t / 11.0))) + 0.2;
        \\}
        \\
        \\float fbm(vec2 p, float t) {
        \\    p *= 1.1;
        \\    float f = 0.0;
        \\    float amp = 0.5;
        \\    for (int i = 0; i < 3; i++) {
        \\        mat2 modify = rotate(t / 50.0 * float(i * i));
        \\        f += amp * noise(p, t);
        \\        p = modify * p;
        \\        p *= 2.0;
        \\        amp /= 2.2;
        \\    }
        \\    return f;
        \\}
        \\
        \\float pattern(vec2 p, out vec2 q, out vec2 r, float t) {
        \\    q = vec2(fbm(p + vec2(1.0), t), fbm(rotate(0.1 * t) * p + vec2(1.0), t));
        \\    r = vec2(fbm(rotate(0.1) * q + vec2(0.0), t), fbm(q + vec2(0.0), t));
        \\    return fbm(p + r, t);
        \\}
        \\
        \\float digit(vec2 p, float t) {
        \\    vec2 grid = vec2(3.0, 1.0) * 15.0;
        \\    vec2 s = floor(p * grid) / grid;
        \\    p *= grid;
        \\    vec2 q;
        \\    vec2 r;
        \\    float intensity = pattern(s / 10.0, q, r, t) * 1.3 - 0.03;
        \\    p = fract(p);
        \\    p *= vec2(1.2);
        \\    float x = fract(p.x * 5.0);
        \\    float y = fract((1.0 - p.y) * 5.0);
        \\    int i = int(floor((1.0 - p.y) * 5.0));
        \\    int j = int(floor(p.x * 5.0));
        \\    int n = (i - 2) * (i - 2) + (j - 2) * (j - 2);
        \\    float f = float(n) / 16.0;
        \\    float isOn = intensity - f > 0.1 ? 1.0 : 0.0;
        \\    return p.x <= 1.0 && p.y <= 1.0 ? isOn * (0.2 + y * 4.0 / 5.0) * (0.75 + x / 4.0) : 0.0;
        \\}
        \\
        \\float hash(float x) {
        \\    return fract(sin(x * 234.1) * 324.19 + sin(sin(x * 3214.09) * 34.132 * x) + x * 234.12);
        \\}
        \\
        \\float onOff(float a, float b, float c, float t) {
        \\    return step(c, sin(t + a * cos(t * b)));
        \\}
        \\
        \\float displace(vec2 look, float t) {
        \\    float y = look.y - mod(t / 4.0, 1.0);
        \\    float window = 1.0 / (1.0 + 50.0 * y * y);
        \\    return sin(look.y * 20.0 + t) / 80.0 * onOff(4.0, 2.0, 0.8, t) * (1.0 + cos(t * 60.0)) * window;
        \\}
        \\
        \\vec3 getColor(vec2 p, float t) {
        \\    float bar = mod(p.y + t * 20.0, 1.0) < 0.2 ? 1.4 : 1.0;
        \\    p.x += displace(p, t);
        \\    float middle = digit(p, t);
        \\    float off = 0.002;
        \\    float sum = 0.0;
        \\    sum += digit(p + vec2(-off, 0.0), t);
        \\    sum += digit(p + vec2(off, 0.0), t);
        \\    sum += digit(p + vec2(0.0, -off), t);
        \\    sum += digit(p + vec2(0.0, off), t);
        \\    sum += middle * 1.5;
        \\
        \\    vec3 base = u_col0 * 0.08;
        \\    vec3 glyph = mix(u_col1, u_col2, 0.35) * middle;
        \\    vec3 glow = (sum / 5.5) * mix(u_col2, u_col1, 0.2) * bar;
        \\    return base + glyph + glow;
        \\}
        \\
        \\void main() {
        \\    float t = u_time / 3.0 + u_phase * 0.5;
        \\    vec2 p = gl_FragCoord.xy / u_resolution.xy;
        \\    vec3 col = getColor(p, t);
        \\    float vignette = 1.0 - dot(p - 0.5, p - 0.5) * 1.5;
        \\    col *= clamp(vignette, 0.35, 1.0);
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !SignalMatrixShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *SignalMatrixShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const SignalMatrixShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const SignalMatrixShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const SignalMatrixShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *SignalMatrixShader) void {
        self.inner.deinit();
    }
};

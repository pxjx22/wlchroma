const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const FractLatticeShader = struct {
    inner: StandardShader,

    // Adapted from a recursive box-lattice raymarch shader.
    // Mouse control is removed; palette colors replace the fixed grey/blue output.
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
        \\float map(vec3 pos) {
        \\    float d = 0.0;
        \\    float scale = 1.0;
        \\    for (int level = 0; level < 4; level++) {
        \\        vec3 p = abs(mod(pos, 1.8 / scale) - 0.9 / scale) - vec3(0.6 / scale);
        \\        float dx = p.x;
        \\        float dy = p.y;
        \\        float dz = p.z;
        \\        d = max(d, min(min(max(dx, min(dy, dz)), max(dy, min(dx, dz))), max(dz, min(dy, dx))));
        \\        scale *= 3.0;
        \\    }
        \\    return d;
        \\}
        \\
        \\vec3 calcNormal(vec3 pos) {
        \\    vec2 e = vec2(0.00012, 0.0);
        \\    return normalize(vec3(
        \\        map(pos + e.xyy) - map(pos - e.xyy),
        \\        map(pos + e.yxy) - map(pos - e.yxy),
        \\        map(pos + e.yyx) - map(pos - e.yyx)
        \\    ));
        \\}
        \\
        \\float castRay(vec3 ro, vec3 rd) {
        \\    float t = 0.0;
        \\    for (int i = 0; i < 56; i++) {
        \\        vec3 pos = ro + t * rd;
        \\        float h = map(pos);
        \\        if (h < 0.001) {
        \\            break;
        \\        }
        \\        t += h;
        \\        if (t > 20.0) break;
        \\    }
        \\    if (t > 20.0) t = -1.0;
        \\    return t;
        \\}
        \\
        \\vec3 paletteMix(float t) {
        \\    vec3 a = mix(u_col0, u_col1, clamp(t, 0.0, 1.0));
        \\    return mix(a, u_col2, clamp((t - 0.5) * 2.0, 0.0, 1.0));
        \\}
        \\
        \\mat2 rot(float a) {
        \\    float c = cos(a);
        \\    float s = sin(a);
        \\    return mat2(c, -s, s, c);
        \\}
        \\
        \\void main() {
        \\    vec2 p = (2.0 * gl_FragCoord.xy - u_resolution.xy) / u_resolution.y;
        \\    vec3 ro = vec3(0.0, 0.0, -u_time * 0.5 + 0.2);
        \\    vec3 rd = normalize(vec3(p, -1.5));
        \\    ro.xy *= rot(sin(u_time * 0.22 + u_phase) * 0.35);
        \\    rd.xy *= rot(sin(u_time * 0.18 + u_phase * 0.7) * 0.2);
        \\    vec3 col = vec3(0.0);
        \\
        \\    float t = castRay(ro, rd);
        \\    if (t > 0.0) {
        \\        vec3 pos = ro + t * rd;
        \\        vec3 nor = calcNormal(pos);
        \\        vec3 sun_dir = normalize(vec3(0.8, 0.4, 0.2));
        \\        float sun_dif = clamp(dot(nor, sun_dir), 0.0, 1.0);
        \\        float sun_sha = step(castRay(pos + nor * 0.001, sun_dir), 0.0);
        \\        float sky_dif = clamp(0.5 + 0.5 * dot(nor, vec3(0.0, 1.0, 1.0)), 0.0, 1.0);
        \\        float fres = pow(1.0 - max(dot(nor, -rd), 0.0), 2.0);
        \\
        \\        vec3 mate = mix(paletteMix(0.35), paletteMix(0.78), 0.5 + 0.5 * nor);
        \\        col += paletteMix(0.12) * 0.08;
        \\        col += mate * sky_dif * 0.65;
        \\        col += paletteMix(0.92) * sun_dif * sun_sha * 0.42;
        \\        col += paletteMix(0.7) * fres * 0.2;
        \\    } else {
        \\        vec3 skyTop = mix(paletteMix(0.55), paletteMix(0.95), 0.5);
        \\        vec3 skyBottom = paletteMix(0.18) * 0.55;
        \\        col = mix(skyBottom, skyTop, p.y * 0.5 + 0.5);
        \\    }
        \\
        \\    col = pow(max(col, 0.0), vec3(1.0 / 2.2));
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !FractLatticeShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *FractLatticeShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const FractLatticeShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const FractLatticeShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const FractLatticeShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *FractLatticeShader) void {
        self.inner.deinit();
    }
};

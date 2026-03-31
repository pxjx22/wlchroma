const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const GyroEchoShader = struct {
    inner: StandardShader,

    // Tuned variant of the source gyroid raymarch: single bounce, shorter march,
    // and lighter AO so it fits wlchroma's existing GPU effect budget better.
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
        \\#define FAR 18.0
        \\#define PI 3.14159265
        \\
        \\mat2 rot(float a) {
        \\    float c = cos(a);
        \\    float s = sin(a);
        \\    return mat2(c, -s, s, c);
        \\}
        \\
        \\mat3 lookAt(vec3 dir) {
        \\    vec3 up = vec3(0.0, 1.0, 0.0);
        \\    vec3 rt = normalize(cross(dir, up));
        \\    return mat3(rt, cross(rt, dir), dir);
        \\}
        \\
        \\float gyroid(vec3 p) {
        \\    return dot(cos(p), sin(p.zxy)) + 1.0;
        \\}
        \\
        \\vec2 mapScene(vec3 p) {
        \\    float d0 = gyroid(p);
        \\    float d1 = gyroid(p - vec3(0.0, 0.0, PI));
        \\    return (d0 < d1) ? vec2(d0, 1.0) : vec2(d1, 2.0);
        \\}
        \\
        \\float mapDist(vec3 p) {
        \\    return mapScene(p).x;
        \\}
        \\
        \\vec2 raymarch(vec3 ro, vec3 rd) {
        \\    float t = 0.0;
        \\    float material = 0.0;
        \\    for (int i = 0; i < 48; i++) {
        \\        vec2 scene = mapScene(ro + rd * t);
        \\        float d = scene.x;
        \\        material = scene.y;
        \\        if (abs(d) < 0.002) break;
        \\        t += d;
        \\        if (t > FAR) break;
        \\    }
        \\    return vec2(t, material);
        \\}
        \\
        \\float getAO(vec3 p, vec3 sn) {
        \\    float occ = 0.0;
        \\    for (int i = 1; i <= 2; i++) {
        \\        float t = float(i) * 0.08;
        \\        float d = mapDist(p + sn * t);
        \\        occ += t - d;
        \\    }
        \\    return clamp(1.0 - occ, 0.0, 1.0);
        \\}
        \\
        \\vec3 getNormal(vec3 p) {
        \\    vec2 e = vec2(0.5773, -0.5773) * 0.0012;
        \\    return normalize(
        \\        e.xyy * mapDist(p + e.xyy) +
        \\        e.yyx * mapDist(p + e.yyx) +
        \\        e.yxy * mapDist(p + e.yxy) +
        \\        e.xxx * mapDist(p + e.xxx)
        \\    );
        \\}
        \\
        \\vec3 trace(vec3 ro, vec3 rd) {
        \\    vec2 hit = raymarch(ro, rd);
        \\    float t = hit.x;
        \\    float material = hit.y;
        \\    if (t > FAR) {
        \\        float horizon = smoothstep(-0.25, 0.9, rd.y * 0.5 + 0.5);
        \\        return mix(u_col0 * 0.08, mix(u_col1, u_col2, 0.4) * 0.16, horizon);
        \\    }
        \\
        \\    vec3 p = ro + rd * t;
        \\    vec3 sn = normalize(getNormal(p) + pow(abs(cos(p * 32.0)), vec3(8.0)) * 0.06);
        \\
        \\    vec3 lp = vec3(8.0, -7.0, -8.0 + ro.z);
        \\    vec3 ld = normalize(lp - p);
        \\    float diff = max(0.0, 0.3 + 1.4 * dot(sn, ld));
        \\    float spec = pow(max(0.0, dot(reflect(-ld, sn), -rd)), 10.0);
        \\    float fres = pow(1.0 - max(0.0, dot(-rd, sn)), 2.0);
        \\    float diff2 = dot(sin(sn * 2.0) * 0.5 + 0.5, vec3(0.3333));
        \\    float diff3 = max(0.0, 0.5 + 0.5 * dot(sn, vec3(0.0, 1.0, 0.0)));
        \\    float freck = dot(cos(p * 23.0), vec3(1.0));
        \\
        \\    vec3 alb0 = mix(u_col1, u_col2, 0.25);
        \\    alb0 *= max(0.6, step(2.5, freck));
        \\    vec3 alb1 = mix(u_col2, u_col1, 0.2);
        \\    alb1 *= max(0.8, step(-2.5, freck));
        \\    vec3 alb = mix(alb0, alb1, step(1.5, material));
        \\
        \\    vec3 col = vec3(0.0);
        \\    col += mix(u_col0, u_col1, 0.7) * diff;
        \\    col += mix(u_col2, u_col1, diff2) * diff2 * 0.45;
        \\    col += mix(u_col0, u_col2, 0.65) * diff3 * 0.55;
        \\    col += mix(u_col1, u_col2, 0.5) * spec * 1.35;
        \\    col *= alb;
        \\    col *= getAO(p, sn);
        \\
        \\    vec3 echo = mix(u_col1, u_col2, 0.5 + 0.5 * rd.y);
        \\    col += echo * fres * 0.22;
        \\    float fog = 1.0 - exp(-0.006 * t * t);
        \\    col = mix(col, u_col0 * 0.05, fog);
        \\    return col;
        \\}
        \\
        \\void main() {
        \\    vec2 uv = (gl_FragCoord.xy - u_resolution * 0.5) / u_resolution.y;
        \\    float t = u_time;
        \\
        \\    vec3 ro = vec3(PI * 0.5, 0.0, -t * 0.45);
        \\    vec3 rd = normalize(vec3(uv, -0.7));
        \\
        \\    rd.xy = rot(sin(t * 0.18 + u_phase * 0.4) * 0.35) * rd.xy;
        \\    vec3 ta = vec3(cos(t * 0.35 + u_phase), sin(t * 0.27 + u_phase * 0.7), 4.0);
        \\    rd = lookAt(normalize(ta)) * rd;
        \\
        \\    vec3 col = trace(ro, rd);
        \\    col *= smoothstep(0.0, 1.0, 1.2 - length(uv * 0.9));
        \\    col = pow(max(col, 0.0), vec3(0.4545));
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !GyroEchoShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *GyroEchoShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const GyroEchoShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const GyroEchoShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const GyroEchoShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *GyroEchoShader) void {
        self.inner.deinit();
    }
};

const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const HexFloretShader = struct {
    inner: StandardShader,

    // Adapted for wlchroma from the Shadertoy shader "Subdivided Hexagon Floret"
    // by Shane: https://www.shadertoy.com/view/3fcfWl
    // The original used a larger helper set and heavier BRDF/shadow code; this
    // version keeps the subdivided floret field and trims the lighting budget.
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
        \\#define PI 3.14159265
        \\#define TAU 6.28318530718
        \\#define FAR 7.0
        \\
        \\const float gSc = 1.0 / 1.5;
        \\const float INV_R = 0.755929;
        \\const vec2 HEX_S = vec2(1.732, 1.0) * gSc;
        \\const vec2 V0 = vec2(-4.0, 0.0) * (HEX_S / 12.0);
        \\const vec2 V1 = vec2(-2.0, 6.0) * (HEX_S / 12.0);
        \\const vec2 E0 = vec2(-3.0, 3.0) * (HEX_S / 12.0);
        \\const vec2 E1 = vec2(0.0, 6.0) * (HEX_S / 12.0);
        \\const mat2 MR = mat2(0.944911, 0.327327, -0.327327, 0.944911);
        \\const mat2 MR_INV = mat2(0.944911, -0.327327, 0.327327, 0.944911);
        \\
        \\mat2 rot2(float a) {
        \\    float c = cos(a);
        \\    float s = sin(a);
        \\    return mat2(c, s, -s, c);
        \\}
        \\
        \\float hash21(vec2 p) {
        \\    p = fract(p * vec2(123.34, 456.21));
        \\    p += dot(p, p + 45.32);
        \\    return fract(p.x * p.y);
        \\}
        \\
        \\float hm(vec2 p) {
        \\    p *= 2.0;
        \\    float d0 = dot(sin(p * 0.5 - cos(p.yx * 0.7)), vec2(0.25)) + 0.5;
        \\    float d1 = dot(sin(p - cos(p.yx * 1.4)), vec2(0.25)) + 0.5;
        \\    return mix(d0, d1, 1.0 / 3.0);
        \\}
        \\
        \\float smax(float a, float b, float k) {
        \\    float f = max(0.0, 1.0 - abs(b - a) / k);
        \\    return max(a, b) + k * 0.25 * f * f;
        \\}
        \\
        \\float distLineS(vec2 p, vec2 a, vec2 b) {
        \\    vec2 e = b - a;
        \\    return dot(p - a, vec2(-e.y, e.x) / length(e));
        \\}
        \\
        \\float lineStep(vec2 p, vec2 a, vec2 b) {
        \\    vec2 e = b - a;
        \\    return dot(p - a, vec2(-e.y, e.x));
        \\}
        \\
        \\float lineCheck(vec2 p, vec2 a, vec2 b) {
        \\    vec2 e = b - a;
        \\    vec2 q = p - a;
        \\    return e.x * q.y - e.y * q.x;
        \\}
        \\
        \\vec4 getGrid(vec2 p) {
        \\    vec4 h = vec4(p, p - HEX_S / 2.0);
        \\    vec4 iC = floor(h / HEX_S.xyxy) + 0.5;
        \\    h -= iC * HEX_S.xyxy;
        \\    return dot(h.xy, h.xy) < dot(h.zw, h.zw) ? vec4(h.xy, iC.xy * 12.0) : vec4(h.zw, iC.zw * 12.0 + 6.0);
        \\}
        \\
        \\vec4 distField(vec2 p) {
        \\    vec2 p2 = p;
        \\    vec4 p4 = getGrid(p2);
        \\    vec2 id = p4.zw;
        \\    p4.xy = MR * p4.xy;
        \\
        \\    vec2 vP0 = vec2(0.0);
        \\    vec2 vP1 = V0 * INV_R;
        \\    vec2 vP2 = MR_INV * V0;
        \\    vec2 vP3 = MR * V1;
        \\    vec2 vP4 = V1 * INV_R;
        \\
        \\    int tID = int(floor(fract(atan(p4.x, p4.y) / TAU) * 6.0 - 0.5) + 2.0);
        \\    tID = int(mod(float(tID), 6.0));
        \\    p4.xy = rot2(TAU / 6.0 * float(tID)) * p4.xy;
        \\
        \\    float lnI2 = lineCheck(p4.xy, vP1, vP2);
        \\    float lnI2B = lineCheck(p4.xy, vP3, vP4);
        \\
        \\    if (lnI2 > 0.0) {
        \\        p4.xy -= MR * E0 * 2.0;
        \\        p4.xy = rot2(-TAU * 0.5) * p4.xy;
        \\        tID = int(mod(float(tID + 3), 6.0));
        \\    }
        \\
        \\    if (lnI2B > 0.0) {
        \\        p4.xy -= MR * E1 * 2.0;
        \\        p4.xy = rot2(-TAU * 2.0 / 6.0) * p4.xy;
        \\        tID = int(mod(float(tID + 4), 6.0));
        \\    }
        \\
        \\    vec2 oCntr = mix(vP1, vP4, 0.5);
        \\
        \\    vec2 eP0 = mix(vP0, vP1, 0.75);
        \\    vec2 eP1 = mix(vP1, vP2, 0.5);
        \\    vec2 eP2 = mix(vP2, vP3, 0.5);
        \\    vec2 eP3 = mix(vP3, vP4, 0.5);
        \\    vec2 eP4 = mix(vP0, vP4, 0.75);
        \\
        \\    float div0 = lineStep(p4.xy, oCntr, eP0);
        \\    float div1 = lineStep(p4.xy, oCntr, eP1);
        \\    float div2 = lineStep(p4.xy, oCntr, eP2);
        \\    float div3 = lineStep(p4.xy, oCntr, eP3);
        \\    float div4 = lineStep(p4.xy, oCntr, eP4);
        \\
        \\    vec2 q0 = oCntr;
        \\    vec2 q1 = eP0;
        \\    vec2 q2 = vP1;
        \\    vec2 q3 = eP1;
        \\    float polyID = 0.0;
        \\
        \\    if (max(div0, -div1) < 0.0) {
        \\        q0 = oCntr; q1 = eP0; q2 = vP1; q3 = eP1; polyID = 4.0;
        \\    } else if (max(div1, -div2) < 0.0) {
        \\        q0 = oCntr; q1 = eP1; q2 = vP2; q3 = eP2; polyID = 3.0;
        \\    } else if (max(div2, -div3) < 0.0) {
        \\        q0 = oCntr; q1 = eP2; q2 = vP3; q3 = eP3; polyID = 2.0;
        \\    } else if (max(div3, -div4) < 0.0) {
        \\        q0 = oCntr; q1 = eP3; q2 = vP4; q3 = eP4; polyID = 1.0;
        \\    } else {
        \\        q0 = oCntr; q1 = eP4; q2 = vP0; q3 = eP0; polyID = 0.0;
        \\    }
        \\
        \\    vec2 localCenter = (q0 + q1 + q2 + q3) * 0.25;
        \\    vec2 globalId = id * (HEX_S / 12.0) + rot2(-float(tID) * TAU / 6.0) * localCenter;
        \\
        \\    float poly = -1e5;
        \\    poly = smax(poly, distLineS(p4.xy, q0, q1), 0.02);
        \\    poly = smax(poly, distLineS(p4.xy, q1, q2), 0.02);
        \\    poly = smax(poly, distLineS(p4.xy, q2, q3), 0.02);
        \\    poly = smax(poly, distLineS(p4.xy, q3, q0), 0.02);
        \\
        \\    if (hash21(globalId + 0.11) < 0.5) {
        \\        float ew = 0.018 * gSc;
        \\        if (polyID < 0.5) ew *= 1.5;
        \\        poly = max(poly, -(length(p4.xy - localCenter) - ew));
        \\    }
        \\
        \\    return vec4(poly, globalId, polyID);
        \\}
        \\
        \\float mapDist(vec3 p) {
        \\    vec4 field = distField(p.xy);
        \\    float h = hm(field.yz * 3.0) * 0.2;
        \\    float d = field.x + 0.0025;
        \\    float top = max(abs(p.z + h * 0.5 - 0.25) - h * 0.5 - 0.25, d);
        \\    top += max(d, -0.05 * gSc) * 0.25;
        \\    float floorD = -p.z + 0.25;
        \\    return min(top, floorD);
        \\}
        \\
        \\vec3 getNormal(vec3 p) {
        \\    vec2 e = vec2(0.001, 0.0);
        \\    return normalize(vec3(
        \\        mapDist(p + vec3(e.x, e.y, e.y)) - mapDist(p - vec3(e.x, e.y, e.y)),
        \\        mapDist(p + vec3(e.y, e.x, e.y)) - mapDist(p - vec3(e.y, e.x, e.y)),
        \\        mapDist(p + vec3(e.y, e.y, e.x)) - mapDist(p - vec3(e.y, e.y, e.x))
        \\    ));
        \\}
        \\
        \\float calcAO(vec3 p, vec3 n) {
        \\    float sca = 2.0;
        \\    float occ = 0.0;
        \\    for (int i = 0; i < 2; i++) {
        \\        float hr = 0.01 + float(i) * 0.07;
        \\        float d = mapDist(p + n * hr);
        \\        occ += (hr - d) * sca;
        \\        sca *= 0.7;
        \\    }
        \\    return clamp(1.0 - occ, 0.0, 1.0);
        \\}
        \\
        \\float softShadow(vec3 ro, vec3 rd) {
        \\    float shade = 1.0;
        \\    float t = 0.02;
        \\    for (int i = 0; i < 10; i++) {
        \\        float h = mapDist(ro + rd * t);
        \\        shade = min(shade, 10.0 * h / t);
        \\        t += clamp(h, 0.03, 0.18);
        \\        if (h < 0.001 || t > FAR) break;
        \\    }
        \\    return clamp(shade, 0.0, 1.0);
        \\}
        \\
        \\float trace(vec3 ro, vec3 rd) {
        \\    float t = (-0.5 - ro.z) / rd.z;
        \\    for (int i = 0; i < 40; i++) {
        \\        float d = mapDist(ro + rd * t);
        \\        if (abs(d) < 0.0015 || t > FAR) break;
        \\        t += d * 0.72;
        \\    }
        \\    return min(t, FAR);
        \\}
        \\
        \\void main() {
        \\    vec2 uv = (gl_FragCoord.xy - u_resolution * 0.5) / u_resolution.y;
        \\    float t = u_time + u_phase * 0.6;
        \\
        \\    vec3 rd = normalize(vec3(uv, 1.0));
        \\    vec3 ro = vec3(0.0, 0.0, -1.5);
        \\    rd.xy *= rot2(sin(t / 8.0) * PI * 0.5);
        \\    ro.xy += vec2(cos(t / 16.0) * 2.0, sin(t / 8.0)) * 2.0;
        \\
        \\    float hit = trace(ro, rd);
        \\    vec3 sp = ro + rd * hit;
        \\    vec3 n = getNormal(sp);
        \\    vec4 field = distField(sp.xy);
        \\    vec2 id = field.yz;
        \\    float d = field.x;
        \\    float height = hm(id * 3.0) * 0.2;
        \\
        \\    float rnd = hash21(id + 0.019);
        \\    vec3 sCol = mix(u_col1, u_col2, rnd);
        \\    vec3 sCol2 = mix(u_col2, u_col0, fract(rnd + 0.22));
        \\    if (dot(sCol2 - sCol, vec3(0.299, 0.587, 0.114)) < 0.0) {
        \\        vec3 tmp = sCol;
        \\        sCol = sCol2;
        \\        sCol2 = tmp;
        \\    }
        \\    vec3 pCol = mix(sCol2, sCol, clamp(length(uv) * 1.2, 0.0, 1.0));
        \\
        \\    float ns = hm(sp.xy * 9.0 + sp.z * 3.0);
        \\    float ns2 = hm(sp.xy * 22.0 - sp.z * 5.0);
        \\    pCol *= mix(0.8, 1.25, ns2);
        \\
        \\    float rw = 0.004;
        \\    float edge = abs(d) - rw;
        \\    edge = max(edge, sp.z + height - rw * 0.5);
        \\    pCol = mix(pCol, pCol * 0.2, 1.0 - smoothstep(0.0, 0.003, edge));
        \\
        \\    vec3 lp = vec3(0.5, 0.75, -1.25);
        \\    lp.xy += vec2(cos(t / 16.0) * 2.0, sin(t / 8.0)) * 2.0;
        \\    vec3 ld = lp - sp;
        \\    float lDist = length(ld);
        \\    ld /= max(lDist, 1e-5);
        \\    float atten = 1.0 / (1.0 + lDist * 0.25);
        \\    float ao = calcAO(sp, n);
        \\    float sh = softShadow(sp + n * 0.002, ld);
        \\
        \\    float nl = max(dot(n, ld), 0.0);
        \\    vec3 h = normalize(ld - rd);
        \\    float nh = max(dot(n, h), 0.0);
        \\    float fres = pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
        \\    float spec = pow(nh, mix(10.0, 36.0, ns));
        \\    float bac = clamp(dot(n, -normalize(vec3(ld.xy, 0.0))), 0.0, 1.0);
        \\
        \\    vec3 col = vec3(0.0);
        \\    col += pCol * (0.22 + nl * 0.95) * atten * ao * mix(0.3, 1.0, sh);
        \\    col += mix(u_col1, u_col2, 0.4) * spec * sh * 1.1 * atten;
        \\    col += pCol * vec3(1.0, 0.35, 0.15) * bac * bac * 0.8;
        \\    col += mix(u_col0, u_col2, 0.6) * fres * 0.18;
        \\    col += mix(u_col0, u_col1, 0.45) * (0.08 + 0.12 * ns);
        \\
        \\    col /= (3.5 + col) / 4.0;
        \\    col = sqrt(max(col, 0.0));
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !HexFloretShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *HexFloretShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const HexFloretShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const HexFloretShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const HexFloretShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *HexFloretShader) void {
        self.inner.deinit();
    }
};

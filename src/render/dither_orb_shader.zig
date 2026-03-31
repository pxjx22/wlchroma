const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const DitherOrbShader = struct {
    inner: StandardShader,

    // Adapted from a Shadertoy-style ordered-dither raymarched orb.
    // Mouse interaction is removed; palette colors replace the source black/white output.
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
        \\#define PIXEL_SIZE 4.0
        \\
        \\bool getValue(float brightness, vec2 pos) {
        \\    if (brightness > 16.0 / 17.0) return false;
        \\    if (brightness < 1.0 / 17.0) return true;
        \\
        \\    vec2 pixel = floor(mod((pos.xy + 0.5) / PIXEL_SIZE, 4.0));
        \\    int x = int(pixel.x);
        \\    int y = int(pixel.y);
        \\    bool result = false;
        \\
        \\         if (x == 0 && y == 0) result = brightness < 16.0 / 17.0;
        \\    else if (x == 2 && y == 2) result = brightness < 15.0 / 17.0;
        \\    else if (x == 2 && y == 0) result = brightness < 14.0 / 17.0;
        \\    else if (x == 0 && y == 2) result = brightness < 13.0 / 17.0;
        \\    else if (x == 1 && y == 1) result = brightness < 12.0 / 17.0;
        \\    else if (x == 3 && y == 3) result = brightness < 11.0 / 17.0;
        \\    else if (x == 3 && y == 1) result = brightness < 10.0 / 17.0;
        \\    else if (x == 1 && y == 3) result = brightness < 9.0 / 17.0;
        \\    else if (x == 1 && y == 0) result = brightness < 8.0 / 17.0;
        \\    else if (x == 3 && y == 2) result = brightness < 7.0 / 17.0;
        \\    else if (x == 3 && y == 0) result = brightness < 6.0 / 17.0;
        \\    else if (x == 0 && y == 1) result = brightness < 5.0 / 17.0;
        \\    else if (x == 1 && y == 2) result = brightness < 4.0 / 17.0;
        \\    else if (x == 2 && y == 3) result = brightness < 3.0 / 17.0;
        \\    else if (x == 2 && y == 1) result = brightness < 2.0 / 17.0;
        \\    else if (x == 0 && y == 3) result = brightness < 1.0 / 17.0;
        \\
        \\    return result;
        \\}
        \\
        \\mat2 rot(float a) {
        \\    float c = cos(a);
        \\    float s = sin(a);
        \\    return mat2(c, s, -s, c);
        \\}
        \\
        \\float de(vec3 p) {
        \\    float d = length(p) - 5.0;
        \\    d += (sin(p.x * 3.0424 + u_time * 1.9318) * 0.5 + 0.5) * 0.3;
        \\    d += (sin(p.y * 2.0157 + u_time * 1.5647) * 0.5 + 0.5) * 0.4;
        \\    return d;
        \\}
        \\
        \\vec3 normal(vec3 p) {
        \\    vec3 e = vec3(0.0, 0.001, 0.0);
        \\    return normalize(vec3(
        \\        de(p + e.yxx) - de(p - e.yxx),
        \\        de(p + e.xyx) - de(p - e.xyx),
        \\        de(p + e.xxy) - de(p - e.xxy)
        \\    ));
        \\}
        \\
        \\vec3 paletteMix(float t) {
        \\    vec3 a = mix(u_col0, u_col1, clamp(t, 0.0, 1.0));
        \\    return mix(a, u_col2, clamp((t - 0.5) * 2.0, 0.0, 1.0));
        \\}
        \\
        \\void main() {
        \\    vec2 fragCoord = gl_FragCoord.xy;
        \\    vec2 uv = fragCoord / u_resolution.xy * 2.0 - 1.0;
        \\    uv.y *= u_resolution.y / u_resolution.x;
        \\
        \\    vec3 from = vec3(-50.0, 0.0, 0.0);
        \\    vec3 dir = normalize(vec3(uv * 0.2, 1.0));
        \\    dir.xz *= rot(3.1415 * 0.5);
        \\
        \\    mat2 rotxz = rot(u_time * 0.0652 + u_phase * 0.9);
        \\    mat2 rotxy = rot(0.3 + sin(u_time * 0.37 + u_phase) * 0.35);
        \\
        \\    from.xy *= rotxy;
        \\    from.xz *= rotxz;
        \\    dir.xy *= rotxy;
        \\    dir.xz *= rotxz;
        \\
        \\    float mindist = 100000.0;
        \\    float totdist = 0.0;
        \\    bool hit = false;
        \\    vec3 norm = vec3(0.0);
        \\
        \\    vec3 light = normalize(vec3(1.0, -3.0, 2.0));
        \\    for (int steps = 0; steps < 72; steps++) {
        \\        if (hit) continue;
        \\        vec3 p = from + totdist * dir;
        \\        float dist = clamp(de(p), 0.0, 1.0);
        \\        mindist = min(dist, mindist);
        \\        totdist += dist;
        \\        if (dist < 0.01) {
        \\            hit = true;
        \\            norm = normal(p);
        \\        }
        \\    }
        \\
        \\    vec3 col;
        \\    if (hit) {
        \\        float brightness = dot(light, norm) * 0.5 + 0.5;
        \\        bool on = getValue(brightness, fragCoord);
        \\        vec3 lit = paletteMix(0.85 + brightness * 0.1);
        \\        vec3 shadow = paletteMix(0.15 + brightness * 0.15) * 0.35;
        \\        col = on ? shadow : lit;
        \\    } else {
        \\        if (mindist < 0.5) {
        \\            col = paletteMix(0.05) * 0.12;
        \\        } else {
        \\            vec2 pos = fragCoord - u_resolution.xy * 0.5;
        \\            vec2 bgdir = vec2(0.0, 1.0) * rot(sin(u_time * 0.4545 + u_phase * 0.2) * 0.112);
        \\            float value = sin(dot(pos, bgdir) * 0.048 - u_time * 1.412) * 0.5 + 0.5;
        \\            bool on = getValue(value, pos);
        \\            vec3 bgA = paletteMix(0.08) * 0.28;
        \\            vec3 bgB = paletteMix(0.45) * 0.55;
        \\            col = on ? bgA : bgB;
        \\        }
        \\    }
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !DitherOrbShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *DitherOrbShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const DitherOrbShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const DitherOrbShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const DitherOrbShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *DitherOrbShader) void {
        self.inner.deinit();
    }
};

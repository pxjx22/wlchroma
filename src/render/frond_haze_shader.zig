const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const FrondHazeShader = struct {
    inner: StandardShader,

    // Clean-room organic field: mirrored branch columns, drifting bloom nodes,
    // and hash-based ray jitter instead of texture input.
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
        \\vec2 rotate2(vec2 p, float a) {
        \\    float cs = cos(a);
        \\    float sn = sin(a);
        \\    return vec2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);
        \\}
        \\
        \\float hash21(vec2 p) {
        \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
        \\}
        \\
        \\float branchField(vec3 p) {
        \\    p.z = mod(p.z, 1.6) - 0.8;
        \\    p.x = abs(p.x) - 0.14;
        \\    p.y += 0.2;
        \\    float d = 1e9;
        \\    float scale = 0.34;
        \\    for (int i = 0; i < 3; i++) {
        \\        float fi = float(i);
        \\        vec3 q = p;
        \\        q.xy = rotate2(q.xy, 0.28 + fi * 0.15);
        \\        q.xz = rotate2(q.xz, 0.35 + q.y * 0.12 + fi * 0.08);
        \\        vec2 stem = vec2(length(q.xz) - 0.05 * scale, q.y - 0.28 * scale);
        \\        float segment = max(abs(stem.x) - 0.022 * scale, abs(stem.y) - 0.22 * scale);
        \\        d = min(d, segment);
        \\        p.y -= 0.22 * scale;
        \\        p.x = abs(p.x) - 0.09 * scale;
        \\        p.xy = rotate2(p.xy, 0.42 + fi * 0.18);
        \\        scale *= 0.77;
        \\    }
        \\    return d;
        \\}
        \\
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / u_resolution;
        \\    vec2 p = uv * 2.0 - 1.0;
        \\    p.x *= u_resolution.x / u_resolution.y;
        \\    float t = u_time * 0.22 + u_phase;
        \\
        \\    vec3 ray = normalize(vec3(p, 0.62));
        \\    float dist = 0.18 + hash21(gl_FragCoord.xy + floor(vec2(t * 37.0))) * 0.06;
        \\    float radial = 0.08 / (0.18 + length(p));
        \\    vec3 col = u_col0 * 0.02;
        \\
        \\    for (int i = 0; i < 20; i++) {
        \\        float fi = float(i);
        \\        vec3 sample_pos = ray * dist;
        \\        sample_pos.z += t * 3.0;
        \\        float segment_id = floor(sample_pos.z * 0.9);
        \\        float rand0 = hash21(vec2(segment_id, fi * 0.37));
        \\        float rand1 = hash21(vec2(segment_id + 17.0, fi * 0.23 + 4.0));
        \\        float rand2 = hash21(vec2(segment_id - 9.0, fi * 0.41 + 7.0));
        \\        sample_pos.x += sin(sample_pos.z * (0.55 + rand0 * 0.45) + t * (1.8 + rand1 * 1.1)) * (0.14 + rand2 * 0.16);
        \\        sample_pos.y += cos(sample_pos.z * (0.4 + rand1 * 0.35) - t * (1.2 + rand0 * 0.9)) * (0.1 + rand0 * 0.16);
        \\
        \\        float branch = abs(branchField(sample_pos));
        \\
        \\        float bloom_radius = 0.2 + rand1 * 0.28;
        \\        float bloom_depth = 0.12 + rand2 * 0.22;
        \\        vec3 bloom_center = vec3(
        \\            sin(sample_pos.z * (0.28 + rand2 * 0.4) + t * (2.0 + rand0 * 1.7)) * (0.25 + rand1 * 0.5),
        \\            cos(sample_pos.z * (0.22 + rand0 * 0.3) - t * (1.3 + rand2 * 1.2)) * (0.12 + rand2 * 0.42),
        \\            sample_pos.z + bloom_depth
        \\        );
        \\        float bloom = length(sample_pos - bloom_center) - bloom_radius;
        \\        float canopy = 0.08 + rand0 * 0.18 + 0.08 * sin(sample_pos.z * (0.7 + rand1 * 0.6) + sample_pos.y * (2.5 + rand2 * 2.5));
        \\        float field = min(branch, abs(bloom) + canopy);
        \\
        \\        float branch_glow = 0.012 / (0.02 + branch * branch * 22.0);
        \\        float branch_edge = smoothstep(0.07, 0.0, branch);
        \\        float bloom_glow = 0.008 / (0.03 + abs(bloom) * 9.0);
        \\        float bloom_edge = smoothstep(0.09, 0.01, abs(bloom));
        \\
        \\        vec3 layer_col = mix(u_col1, u_col2, 0.5 + 0.5 * sin(sample_pos.z * 0.28 + fi * 0.17));
        \\        col += layer_col * (branch_glow + branch_edge * 0.065);
        \\        col += mix(u_col1, u_col2, 0.35) * (bloom_glow * 0.45 + bloom_edge * 0.022);
        \\        col += mix(u_col0, u_col1, 0.6) * radial * 0.016;
        \\
        \\        dist += clamp(0.04 + field * 0.32 + fi * 0.0015, 0.035, 0.18);
        \\    }
        \\
        \\    float vignette = smoothstep(1.18, 0.18, length(p));
        \\    float veil = 0.5 + 0.5 * sin((p.x - p.y) * 28.0 + t * 9.0);
        \\    col += u_col2 * veil * vignette * 0.012;
        \\    col *= mix(1.02, 0.3, smoothstep(0.25, 1.22, length(p)));
        \\    col = col / (1.0 + col);
        \\    col = mix(col, sqrt(max(col, 0.0)), 0.14);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !FrondHazeShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *FrondHazeShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const FrondHazeShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const FrondHazeShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const FrondHazeShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *FrondHazeShader) void {
        self.inner.deinit();
    }
};

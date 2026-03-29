const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const LumenTunnelShader = struct {
    inner: StandardShader,

    // Clean-room tunnel effect: layered rotating rings with palette-tinted glow
    // and a subtle screen-space shimmer. Single pass, no textures or buffers.
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
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / u_resolution;
        \\    vec2 p = uv * 2.0 - 1.0;
        \\    p.x *= u_resolution.x / u_resolution.y;
        \\    float t = u_time + u_phase;
        \\
        \\    vec3 ray = normalize(vec3(p * 1.15, 1.7));
        \\    vec3 pos = vec3(0.0, 0.0, t * 2.4);
        \\    vec3 col = u_col0 * 0.03;
        \\    float travel = 0.0;
        \\
        \\    for (int i = 0; i < 9; i++) {
        \\        float fi = float(i);
        \\        vec3 sample_pos = pos + ray * travel;
        \\        float spin = t * 0.32 + sample_pos.z * 0.22 + fi * 0.31;
        \\        vec2 swirl = rotate2(sample_pos.xy, spin);
        \\        float radius = length(swirl);
        \\
        \\        float tunnel_radius = 0.62 + 0.18 * sin(sample_pos.z * 0.9 + fi * 0.7);
        \\        float shell = smoothstep(0.13, 0.01, abs(radius - tunnel_radius));
        \\        float ribs = 0.35 + 0.65 * smoothstep(0.15, 1.0, 0.5 + 0.5 * cos(swirl.x * 11.0 - swirl.y * 7.0 - sample_pos.z * 1.5));
        \\        float flare = smoothstep(0.07, 0.0, abs(swirl.y)) * smoothstep(1.0, 0.35, radius);
        \\        float glow = shell * (0.3 + ribs * 0.95) + flare * 0.18;
        \\
        \\        vec3 layer_col = mix(u_col1, u_col2, 0.5 + 0.5 * sin(sample_pos.z * 0.4 + fi * 0.6));
        \\        col += layer_col * glow / (1.0 + fi * 0.22);
        \\
        \\        travel += 0.48 + radius * 0.16 + fi * 0.015;
        \\    }
        \\
        \\    float shimmer = 0.5 + 0.5 * sin((p.x + p.y * 0.35) * 42.0 - t * 3.5);
        \\    float scan = 0.5 + 0.5 * sin(p.y * 95.0 + t * 5.2);
        \\    float center = smoothstep(1.05, 0.08, length(p));
        \\    col += u_col2 * shimmer * scan * center * 0.035;
        \\
        \\    col += mix(u_col1, u_col2, 0.25) * center * 0.055;
        \\    col *= mix(1.08, 0.34, smoothstep(0.3, 1.1, length(p)));
        \\    col = col / (1.0 + col);
        \\    col = mix(col, sqrt(max(col, 0.0)), 0.16);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !LumenTunnelShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *LumenTunnelShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const LumenTunnelShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const LumenTunnelShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const LumenTunnelShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *LumenTunnelShader) void {
        self.inner.deinit();
    }
};

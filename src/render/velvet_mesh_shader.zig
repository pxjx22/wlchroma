const StandardShader = @import("standard_shader.zig").StandardShader;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const VelvetMeshShader = struct {
    inner: StandardShader,

    // Hexagonal grid SDF via domain repetition and dot-product distance.
    // No sqrt: uses elongated rhombus approximation for hex cell boundaries.
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
        \\    // Hex grid: larger cells for pixelation, stronger breathing
        \\    float scale = 5.0 + sin(t * 0.08) * 0.8;
        \\    vec2 hp = p * scale;
        \\    // Axial hex coordinate via skew
        \\    vec2 skewed = vec2(hp.x - hp.y * 0.57735, hp.y * 1.1547);
        \\    vec2 cellId = floor(skewed + 0.5);
        \\    vec2 local = skewed - cellId;
        \\
        \\    // Hex SDF approximation: max of three rhombus distances
        \\    float d = abs(local.x);
        \\    d = max(d, abs(local.y));
        \\    d = max(d, abs(local.x + local.y * 0.5) * 1.15);
        \\
        \\    // Hard edge at hex border
        \\    float border = step(0.42, d);
        \\    // Inner ring: stronger pulse animation
        \\    float innerRing = step(0.20, d) * (1.0 - step(0.38, d));
        \\    float pulse = step(d, 0.20 + sin(t * 0.5 + cellId.x * 0.3) * 0.08);
        \\
        \\    // Hash cell for colour variation
        \\    float ch = fract(sin(dot(cellId, vec2(127.1, 311.7))) * 43758.5453);
        \\    float isCh1 = step(0.33, ch) * (1.0 - step(0.66, ch));
        \\    float isCh2 = step(0.66, ch);
        \\
        \\    vec3 cellCol = u_col0;
        \\    cellCol = mix(cellCol, u_col1, isCh1);
        \\    cellCol = mix(cellCol, u_col2, isCh2);
        \\
        \\    // Compose: cell color, inner ring highlight, border accent
        \\    vec3 col = cellCol;
        \\    col = mix(col, u_col1, pulse * 0.7);
        \\    col = mix(col, u_col0, innerRing * 0.5);
        \\    col = mix(col, u_col2, border);
        \\
        \\    gl_FragColor = vec4(col, 1.0);
        \\}
    ;

    pub fn init() !VelvetMeshShader {
        return .{ .inner = try StandardShader.init(frag_src) };
    }

    pub fn bind(self: *VelvetMeshShader, phase: f32, palette: [3]Rgb) void {
        self.inner.bind(phase, palette);
    }

    pub fn setStaticUniforms(self: *const VelvetMeshShader, phase: f32, palette: [3]Rgb) void {
        self.inner.setStaticUniforms(phase, palette);
    }

    pub fn setUniforms(self: *const VelvetMeshShader, time: f32, w: f32, h: f32) void {
        self.inner.setUniforms(time, w, h);
    }

    pub fn draw(self: *const VelvetMeshShader) void {
        self.inner.draw();
    }

    pub fn deinit(self: *VelvetMeshShader) void {
        self.inner.deinit();
    }
};

const std = @import("std");
const defaults = @import("defaults.zig");
const Rgb = defaults.Rgb;

pub const UpscaleFilter = enum {
    nearest,
    linear,
};

pub const AppConfig = struct {
    fps: u32,
    frame_interval_ns: u32,
    frame_advance_ms: u32,
    palette: [3]Rgb,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,
};

pub fn defaultConfig() AppConfig {
    return .{
        .fps = DEFAULT_FPS,
        .frame_interval_ns = defaults.FRAME_INTERVAL_NS,
        .frame_advance_ms = defaults.FRAME_ADVANCE_MS,
        .palette = .{ defaults.DEFAULT_COL1, defaults.DEFAULT_COL2, defaults.DEFAULT_COL3 },
        .renderer_scale = 1.0,
        .upscale_filter = .nearest,
    };
}

const DEFAULT_FPS: u32 = 15;

pub fn loadConfig(allocator: std.mem.Allocator) !AppConfig {
    const path = resolveConfigPath(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.debug.print("config: could not resolve config path, using defaults\n", .{});
                return defaultConfig();
            },
        }
    };
    defer if (path.allocated) allocator.free(path.slice);

    const file = std.fs.openFileAbsolute(path.slice, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("config: no config file found at {s}, using defaults\n", .{path.slice});
                return defaultConfig();
            },
            else => {
                std.debug.print("config: failed to open {s}: {}\n", .{ path.slice, err });
                return error.ConfigFileError;
            },
        }
    };
    defer file.close();

    const max_size = 64 * 1024; // 64 KiB ought to be enough for a config file
    const content = file.readToEndAlloc(allocator, max_size) catch |err| {
        std.debug.print("config: failed to read config file: {}\n", .{err});
        return error.ConfigFileError;
    };
    defer allocator.free(content);

    return parseAndValidate(content);
}

const ConfigPath = struct {
    slice: []const u8,
    allocated: bool,
};

fn resolveConfigPath(allocator: std.mem.Allocator) !ConfigPath {
    // Try XDG_CONFIG_HOME first
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) {
            const path = try std.fmt.allocPrint(allocator, "{s}/wlchroma/config.toml", .{xdg});
            return .{ .slice = path, .allocated = true };
        }
    }

    // Fall back to $HOME/.config
    if (std.posix.getenv("HOME")) |home| {
        if (home.len > 0) {
            const path = try std.fmt.allocPrint(allocator, "{s}/.config/wlchroma/config.toml", .{home});
            return .{ .slice = path, .allocated = true };
        }
    }

    return error.NoHome;
}

fn parseAndValidate(content: []const u8) !AppConfig {
    var config = defaultConfig();

    // Current section path, e.g. "" for top-level, "outputs", "effect", "effect.settings"
    var section: Section = .top;

    var line_num: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        line_num += 1;
        const line = stripComment(std.mem.trim(u8, raw_line, &std.ascii.whitespace));

        if (line.len == 0) continue;

        // Section header
        if (line[0] == '[') {
            section = parseSectionHeader(line) orelse {
                // Unknown section -- ignore for forward compatibility
                section = .unknown;
                continue;
            };
            continue;
        }

        // Key = value
        const kv = parseKeyValue(line) orelse {
            std.debug.print("config: line {}: malformed key-value pair\n", .{line_num});
            return error.MalformedConfig;
        };

        switch (section) {
            .top => {
                if (std.mem.eql(u8, kv.key, "version")) {
                    const v = parseInteger(kv.value) orelse {
                        std.debug.print("config: line {}: 'version' must be an integer\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (v != 1) {
                        std.debug.print("config: unsupported config version {}, expected 1\n", .{v});
                        return error.UnsupportedVersion;
                    }
                } else if (std.mem.eql(u8, kv.key, "fps")) {
                    const fps = parseInteger(kv.value) orelse {
                        std.debug.print("config: line {}: 'fps' must be an integer\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (fps < 1 or fps > 120) {
                        std.debug.print("config: line {}: 'fps' must be between 1 and 120, got {}\n", .{ line_num, fps });
                        return error.InvalidValue;
                    }
                    const fps_u32: u32 = @intCast(fps);
                    config.fps = fps_u32;
                    config.frame_interval_ns = 1_000_000_000 / fps_u32;
                    // Jitter margin: ~90% of the frame period in ms
                    config.frame_advance_ms = @intCast((1000 * 9) / (fps_u32 * 10));
                    // Clamp to at least 1ms so maybeAdvance is not stuck at 0
                    if (config.frame_advance_ms == 0) config.frame_advance_ms = 1;
                } else {
                    // Unknown top-level key -- ignore for forward compatibility
                }
            },
            .outputs => {
                if (std.mem.eql(u8, kv.key, "policy")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'policy' must be a quoted string\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (!std.mem.eql(u8, val, "all")) {
                        std.debug.print("config: line {}: unsupported outputs.policy \"{s}\", only \"all\" is supported in v1\n", .{ line_num, val });
                        return error.UnsupportedPolicy;
                    }
                }
            },
            .effect => {
                if (std.mem.eql(u8, kv.key, "name")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'name' must be a quoted string\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (!std.mem.eql(u8, val, "colormix")) {
                        std.debug.print("config: line {}: unsupported effect.name \"{s}\", only \"colormix\" is supported in v1\n", .{ line_num, val });
                        return error.UnsupportedEffect;
                    }
                }
            },
            .effect_settings => {
                if (std.mem.eql(u8, kv.key, "palette")) {
                    const colors = parseStringArray(kv.value) orelse {
                        std.debug.print("config: line {}: 'palette' must be an array of 3 hex color strings\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (colors.len != 3) {
                        std.debug.print("config: line {}: 'palette' must contain exactly 3 colors, got {}\n", .{ line_num, colors.len });
                        return error.InvalidValue;
                    }
                    for (colors.items(), 0..) |color_str, i| {
                        config.palette[i] = parseHexColor(color_str) orelse {
                            std.debug.print("config: line {}: invalid hex color \"{s}\" in palette\n", .{ line_num, color_str });
                            return error.InvalidValue;
                        };
                    }
                }
            },
            .renderer => {
                if (std.mem.eql(u8, kv.key, "scale")) {
                    const scale = parseFloat(kv.value) orelse {
                        std.debug.print("config: line {}: 'scale' must be a float\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (scale < 0.1 or scale > 1.0) {
                        std.debug.print("config: line {}: 'scale' must be between 0.1 and 1.0, got {d:.2}\n", .{ line_num, scale });
                        return error.InvalidValue;
                    }
                    config.renderer_scale = scale;
                } else if (std.mem.eql(u8, kv.key, "upscale_filter")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'upscale_filter' must be a quoted string\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (std.mem.eql(u8, val, "nearest")) {
                        config.upscale_filter = .nearest;
                    } else if (std.mem.eql(u8, val, "linear")) {
                        config.upscale_filter = .linear;
                    } else {
                        std.debug.print("config: line {}: 'upscale_filter' must be \"nearest\" or \"linear\", got \"{s}\"\n", .{ line_num, val });
                        return error.InvalidValue;
                    }
                }
            },
            .unknown => {
                // Ignore keys in unknown sections
            },
        }
    }

    return config;
}

const Section = enum {
    top,
    outputs,
    effect,
    effect_settings,
    renderer,
    unknown,
};

fn parseSectionHeader(line: []const u8) ?Section {
    if (line.len < 2 or line[0] != '[') return null;
    // Find closing bracket
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    if (close < 2) return null;
    const name = std.mem.trim(u8, line[1..close], &std.ascii.whitespace);

    if (std.mem.eql(u8, name, "outputs")) return .outputs;
    if (std.mem.eql(u8, name, "effect")) return .effect;
    if (std.mem.eql(u8, name, "effect.settings")) return .effect_settings;
    if (std.mem.eql(u8, name, "renderer")) return .renderer;
    return null; // Unknown section
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseKeyValue(line: []const u8) ?KeyValue {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (eq == 0) return null;
    const key = std.mem.trimRight(u8, line[0..eq], &std.ascii.whitespace);
    if (key.len == 0) return null;
    const value = std.mem.trimLeft(u8, line[eq + 1 ..], &std.ascii.whitespace);
    return .{ .key = key, .value = value };
}

fn parseInteger(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn parseFloat(value: []const u8) ?f32 {
    if (value.len == 0) return null;
    return std.fmt.parseFloat(f32, value) catch null;
}

fn parseQuotedString(value: []const u8) ?[]const u8 {
    if (value.len < 2) return null;
    if (value[0] != '"') return null;
    // Find the closing quote
    const close = std.mem.indexOfScalarPos(u8, value, 1, '"') orelse return null;
    return value[1..close];
}

fn stripComment(line: []const u8) []const u8 {
    // Strip # comments that are not inside a string.
    // Simple approach: if # appears outside of quotes, truncate there.
    var in_quote = false;
    for (line, 0..) |ch, i| {
        if (ch == '"') {
            in_quote = !in_quote;
        } else if (ch == '#' and !in_quote) {
            return std.mem.trimRight(u8, line[0..i], &std.ascii.whitespace);
        }
    }
    return line;
}

/// Parse an inline array of quoted strings: ["a", "b", "c"]
/// Returns a bounded array (max 16 elements) of slices into the input.
const MAX_ARRAY_ELEMS = 16;

const StringArray = struct {
    buf: [MAX_ARRAY_ELEMS][]const u8,
    len: usize,

    fn items(self: *const StringArray) []const []const u8 {
        return self.buf[0..self.len];
    }
};

fn parseStringArray(value: []const u8) ?StringArray {
    if (value.len < 2) return null;
    if (value[0] != '[') return null;
    const close = std.mem.lastIndexOfScalar(u8, value, ']') orelse return null;
    if (close < 1) return null;
    const inner = value[1..close];

    var result = StringArray{ .buf = undefined, .len = 0 };

    var pos: usize = 0;
    while (pos < inner.len) {
        // Skip whitespace and commas
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == ',' or inner[pos] == '\t')) {
            pos += 1;
        }
        if (pos >= inner.len) break;

        if (inner[pos] != '"') return null; // Expected quoted string
        pos += 1; // skip opening quote
        const start = pos;
        // Find closing quote
        while (pos < inner.len and inner[pos] != '"') {
            pos += 1;
        }
        if (pos >= inner.len) return null; // Unterminated string
        const str = inner[start..pos];
        pos += 1; // skip closing quote

        if (result.len >= MAX_ARRAY_ELEMS) return null; // Too many elements
        result.buf[result.len] = str;
        result.len += 1;
    }

    return result;
}

pub fn parseHexColor(s: []const u8) ?Rgb {
    if (s.len != 7) return null;
    if (s[0] != '#') return null;
    const r = hexByte(s[1], s[2]) orelse return null;
    const g = hexByte(s[3], s[4]) orelse return null;
    const b = hexByte(s[5], s[6]) orelse return null;
    return .{ .r = r, .g = g, .b = b };
}

fn hexByte(hi: u8, lo: u8) ?u8 {
    const h: u8 = hexDigit(hi) orelse return null;
    const l: u8 = hexDigit(lo) orelse return null;
    return (h << 4) | l;
}

fn hexDigit(ch: u8) ?u4 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    if (ch >= 'A' and ch <= 'F') return @intCast(ch - 'A' + 10);
    return null;
}

// --- Tests ---

test "parseHexColor valid" {
    const rgb = parseHexColor("#1e1e2e").?;
    try std.testing.expectEqual(@as(u8, 0x1e), rgb.r);
    try std.testing.expectEqual(@as(u8, 0x1e), rgb.g);
    try std.testing.expectEqual(@as(u8, 0x2e), rgb.b);
}

test "parseHexColor uppercase" {
    const rgb = parseHexColor("#89B4FA").?;
    try std.testing.expectEqual(@as(u8, 0x89), rgb.r);
    try std.testing.expectEqual(@as(u8, 0xB4), rgb.g);
    try std.testing.expectEqual(@as(u8, 0xFA), rgb.b);
}

test "parseHexColor invalid" {
    try std.testing.expect(parseHexColor("") == null);
    try std.testing.expect(parseHexColor("#12345") == null);
    try std.testing.expect(parseHexColor("1234567") == null);
    try std.testing.expect(parseHexColor("#gggggg") == null);
}

test "parseAndValidate defaults" {
    const cfg = try parseAndValidate("");
    const def = defaultConfig();
    try std.testing.expectEqual(def.fps, cfg.fps);
    try std.testing.expectEqual(def.palette[0].r, cfg.palette[0].r);
}

test "parseAndValidate full config" {
    const toml =
        \\version = 1
        \\fps = 30
        \\
        \\[outputs]
        \\policy = "all"
        \\
        \\[effect]
        \\name = "colormix"
        \\
        \\[effect.settings]
        \\palette = ["#ff0000", "#00ff00", "#0000ff"]
    ;
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(@as(u32, 30), cfg.fps);
    try std.testing.expectEqual(@as(u32, 1_000_000_000 / 30), cfg.frame_interval_ns);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0x00), cfg.palette[0].g);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.palette[1].g);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.palette[2].b);
}

test "parseAndValidate bad version" {
    const toml = "version = 2\n";
    try std.testing.expectError(error.UnsupportedVersion, parseAndValidate(toml));
}

test "parseAndValidate bad fps" {
    const toml = "fps = 0\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate fps too high" {
    const toml = "fps = 121\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate unsupported effect" {
    const toml = "[effect]\nname = \"fire\"\n";
    try std.testing.expectError(error.UnsupportedEffect, parseAndValidate(toml));
}

test "parseAndValidate unsupported policy" {
    const toml = "[outputs]\npolicy = \"manual\"\n";
    try std.testing.expectError(error.UnsupportedPolicy, parseAndValidate(toml));
}

test "parseAndValidate comments" {
    const toml = "# A comment\nfps = 20 # inline comment\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(@as(u32, 20), cfg.fps);
}

test "parseAndValidate unknown keys and sections ignored" {
    const toml = "future_key = 42\n\n[unknown_section]\nfoo = \"bar\"\n";
    const cfg = try parseAndValidate(toml);
    // Should return defaults without error
    try std.testing.expectEqual(defaultConfig().fps, cfg.fps);
}

test "parseStringArray basic" {
    const arr = parseStringArray("[\"a\", \"b\", \"c\"]").?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expect(std.mem.eql(u8, "a", arr.buf[0]));
    try std.testing.expect(std.mem.eql(u8, "b", arr.buf[1]));
    try std.testing.expect(std.mem.eql(u8, "c", arr.buf[2]));
}

test "frame_advance_ms jitter margin" {
    // At 15fps: 1000*9 / (15*10) = 9000/150 = 60
    const toml = "fps = 15\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(@as(u32, 60), cfg.frame_advance_ms);
}

test "parseAndValidate renderer scale" {
    const toml = "[renderer]\nscale = 0.5\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cfg.renderer_scale, 0.001);
    try std.testing.expectEqual(UpscaleFilter.nearest, cfg.upscale_filter);
}

test "parseAndValidate renderer upscale_filter linear" {
    const toml = "[renderer]\nupscale_filter = \"linear\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(UpscaleFilter.linear, cfg.upscale_filter);
}

test "parseAndValidate renderer scale too low" {
    const toml = "[renderer]\nscale = 0.05\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate renderer scale too high" {
    const toml = "[renderer]\nscale = 1.5\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate renderer invalid filter" {
    const toml = "[renderer]\nupscale_filter = \"bicubic\"\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate missing renderer section uses defaults" {
    const toml = "fps = 15\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.renderer_scale, 0.001);
    try std.testing.expectEqual(UpscaleFilter.nearest, cfg.upscale_filter);
}

test "frame_advance_ms at 120fps" {
    const toml = "fps = 120\n";
    const cfg = try parseAndValidate(toml);
    // 1000*9 / (120*10) = 9000/1200 = 7
    try std.testing.expectEqual(@as(u32, 7), cfg.frame_advance_ms);
}

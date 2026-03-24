const std = @import("std");
const defaults = @import("defaults.zig");
const Rgb = defaults.Rgb;

pub const UpscaleFilter = enum {
    nearest,
    linear,
};

pub const EffectType = enum {
    colormix,
    glass_drift,
    aurora_bands,
    cloud_chamber,
    ribbon_orbit,
    plasma_quilt,
    liquid_marble,
    velvet_mesh,
    soft_interference,
    starfield_fog,
    tube_lights,
};

pub const AppConfig = struct {
    fps: u32,
    frame_interval_ns: u32,
    frame_advance_ms: u32,
    effect_type: EffectType,
    palette: [3]Rgb,
    speed: f32,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,
};

pub fn defaultConfig() AppConfig {
    return .{
        .fps = DEFAULT_FPS,
        .frame_interval_ns = defaults.FRAME_INTERVAL_NS,
        .frame_advance_ms = defaults.FRAME_ADVANCE_MS,
        .effect_type = .colormix,
        .palette = .{ defaults.DEFAULT_COL1, defaults.DEFAULT_COL2, defaults.DEFAULT_COL3 },
        .speed = 1.0,
        .renderer_scale = 1.0,
        .upscale_filter = .nearest,
    };
}

const DEFAULT_FPS: u32 = 15;

pub fn loadConfig(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !AppConfig {
    if (explicit_path) |ep| {
        return loadConfigFromExplicitPath(allocator, ep);
    }
    return loadConfigFromDefaults(allocator);
}

fn loadConfigFromExplicitPath(allocator: std.mem.Allocator, path: []const u8) !AppConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("config: failed to open {s}: {}\n", .{ path, err });
        return error.ConfigFileError;
    };
    defer file.close();

    const max_size = 64 * 1024;
    const content = file.readToEndAlloc(allocator, max_size) catch |err| {
        std.debug.print("config: failed to read config file: {}\n", .{err});
        return error.ConfigFileError;
    };
    defer allocator.free(content);

    return parseAndValidateExistingConfig(content);
}

fn loadConfigFromDefaults(allocator: std.mem.Allocator) !AppConfig {
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

    return parseAndValidateExistingConfig(content);
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

const ParseOptions = struct {
    require_version: bool = false,
};

const MAX_SEEN_KEYS = 64;
const RENDERER_SCALE_NEAR_NATIVE_MIN: f32 = 0.95;

const SeenNames = struct {
    buf: [MAX_SEEN_KEYS][]const u8,
    len: usize,

    fn contains(self: *const SeenNames, name: []const u8) bool {
        for (self.buf[0..self.len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return true;
        }
        return false;
    }

    fn add(self: *SeenNames, name: []const u8) !void {
        if (self.contains(name)) return error.DuplicateConfigEntry;
        if (self.len >= self.buf.len) return error.MalformedConfig;
        self.buf[self.len] = name;
        self.len += 1;
    }
};

const SeenKey = struct {
    section_name: []const u8,
    key: []const u8,
};

const SeenKeys = struct {
    buf: [MAX_SEEN_KEYS]SeenKey,
    len: usize,

    fn contains(self: *const SeenKeys, section_name: []const u8, key: []const u8) bool {
        for (self.buf[0..self.len]) |seen| {
            if (std.mem.eql(u8, seen.section_name, section_name) and std.mem.eql(u8, seen.key, key)) return true;
        }
        return false;
    }

    fn add(self: *SeenKeys, section_name: []const u8, key: []const u8) !void {
        if (self.contains(section_name, key)) return error.DuplicateConfigEntry;
        if (self.len >= self.buf.len) return error.MalformedConfig;
        self.buf[self.len] = .{ .section_name = section_name, .key = key };
        self.len += 1;
    }
};

fn parseAndValidateExistingConfig(content: []const u8) !AppConfig {
    return parseAndValidateWithOptions(content, .{ .require_version = true });
}

fn parseAndValidate(content: []const u8) !AppConfig {
    return parseAndValidateWithOptions(content, .{});
}

fn parseAndValidateWithOptions(content: []const u8, options: ParseOptions) !AppConfig {
    var config = defaultConfig();

    // Current section path, e.g. "" for top-level, "outputs", "effect", "effect.settings"
    var section: Section = .top;
    var section_name: []const u8 = "";
    var seen_sections = SeenNames{ .buf = undefined, .len = 0 };
    var seen_keys = SeenKeys{ .buf = undefined, .len = 0 };
    var saw_version = false;

    var line_num: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        line_num += 1;
        const line = stripComment(std.mem.trim(u8, raw_line, &std.ascii.whitespace));

        if (line.len == 0) continue;

        // Section header
        if (line[0] == '[') {
            const parsed_section = parseSectionHeader(line) orelse {
                std.debug.print("config: line {}: malformed section header\n", .{line_num});
                return error.MalformedConfig;
            };
            if (shouldTrackSection(parsed_section.section)) {
                seen_sections.add(parsed_section.name) catch |err| switch (err) {
                    error.DuplicateConfigEntry => {
                        std.debug.print("config: line {}: duplicate section [{s}] is not allowed\n", .{ line_num, parsed_section.name });
                        return error.DuplicateConfigEntry;
                    },
                    else => return err,
                };
            }
            if (parsed_section.section == .unknown) {
                std.debug.print("config: line {}: ignoring unknown section [{s}]\n", .{ line_num, parsed_section.name });
            }
            section = parsed_section.section;
            section_name = parsed_section.name;
            continue;
        }

        // Key = value
        const kv = parseKeyValue(line) orelse {
            std.debug.print("config: line {}: malformed key-value pair\n", .{line_num});
            return error.MalformedConfig;
        };

        if (shouldTrackKey(section, kv.key)) {
            seen_keys.add(section_name, kv.key) catch |err| switch (err) {
                error.DuplicateConfigEntry => {
                    if (section == .top) {
                        std.debug.print("config: line {}: duplicate key '{s}' is not allowed\n", .{ line_num, kv.key });
                    } else {
                        std.debug.print("config: line {}: duplicate key '{s}.{s}' is not allowed\n", .{ line_num, section_name, kv.key });
                    }
                    return error.DuplicateConfigEntry;
                },
                else => return err,
            };
        }

        switch (section) {
            .top => {
                if (std.mem.eql(u8, kv.key, "version")) {
                    saw_version = true;
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
                        std.debug.print("config: line {}: 'fps' must be a whole number between 1 and 120\n", .{line_num});
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
                    std.debug.print("config: line {}: ignoring unknown top-level key '{s}'\n", .{ line_num, kv.key });
                }
            },
            .outputs => {
                // Reserved/internal compatibility field for v1. It is accepted so
                // explicit configs can state the only supported policy today, but it
                // is intentionally omitted from the public example surface for now.
                if (std.mem.eql(u8, kv.key, "policy")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'policy' must be a quoted string\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (!std.mem.eql(u8, val, "all")) {
                        std.debug.print("config: line {}: unsupported outputs.policy \"{s}\", only \"all\" is supported in v1\n", .{ line_num, val });
                        return error.UnsupportedPolicy;
                    }
                } else {
                    std.debug.print("config: line {}: ignoring unknown key 'outputs.{s}'\n", .{ line_num, kv.key });
                }
            },
            .effect => {
                if (std.mem.eql(u8, kv.key, "name")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'name' must be a quoted string\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (std.meta.stringToEnum(EffectType, val)) |effect_type| {
                        config.effect_type = effect_type;
                    } else {
                        std.debug.print("config: unknown effect name \"{s}\"\n", .{val});
                        return error.UnsupportedEffect;
                    }
                } else {
                    std.debug.print("config: line {}: ignoring unknown key 'effect.{s}'\n", .{ line_num, kv.key });
                }
            },
            .effect_settings => {
                if (std.mem.eql(u8, kv.key, "speed")) {
                    const speed = parseFloat(kv.value) orelse {
                        std.debug.print("config: line {}: 'effect.settings.speed' must be a number\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (!std.math.isFinite(speed) or speed < 0.25 or speed > 2.5) {
                        std.debug.print("config: line {}: 'effect.settings.speed' must be between 0.25 and 2.5, got {d}\n", .{ line_num, speed });
                        return error.InvalidValue;
                    }
                    config.speed = speed;
                } else if (std.mem.eql(u8, kv.key, "palette")) {
                    const colors = parseStringArray(kv.value) orelse {
                        std.debug.print("config: line {}: 'palette' must be an array of exactly 3 quoted '#RRGGBB' strings\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (colors.len != 3) {
                        std.debug.print("config: line {}: 'palette' must contain exactly 3 colors, got {}\n", .{ line_num, colors.len });
                        return error.InvalidValue;
                    }
                    for (colors.items(), 0..) |color_str, i| {
                        config.palette[i] = parseHexColor(color_str) orelse {
                            std.debug.print("config: line {}: 'palette' entry {} must be a '#RRGGBB' color, got \"{s}\"\n", .{ line_num, i + 1, color_str });
                            return error.InvalidValue;
                        };
                    }
                } else {
                    std.debug.print("config: line {}: ignoring unknown key 'effect.settings.{s}'\n", .{ line_num, kv.key });
                }
            },
            .renderer => {
                if (std.mem.eql(u8, kv.key, "scale")) {
                    const scale = parseFloat(kv.value) orelse {
                        std.debug.print("config: line {}: 'renderer.scale' must be a number between 0.1 and 1.0\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (!std.math.isFinite(scale) or scale < 0.1 or scale > 1.0) {
                        std.debug.print("config: line {}: 'renderer.scale' must be between 0.1 and 1.0, got {d}\n", .{ line_num, scale });
                        return error.InvalidValue;
                    }
                    if (scale < 1.0 and scale >= RENDERER_SCALE_NEAR_NATIVE_MIN) {
                        std.debug.print("config: line {}: 'renderer.scale' values from {d} up to but not including 1.0 are too close to native; use a value below {d} or exactly 1.0\n", .{ line_num, RENDERER_SCALE_NEAR_NATIVE_MIN, RENDERER_SCALE_NEAR_NATIVE_MIN });
                        return error.InvalidValue;
                    }
                    config.renderer_scale = scale;
                } else if (std.mem.eql(u8, kv.key, "upscale_filter")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'renderer.upscale_filter' must be \"nearest\" or \"linear\"\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (std.mem.eql(u8, val, "nearest")) {
                        config.upscale_filter = .nearest;
                    } else if (std.mem.eql(u8, val, "linear")) {
                        config.upscale_filter = .linear;
                    } else {
                        std.debug.print("config: line {}: 'renderer.upscale_filter' must be \"nearest\" or \"linear\", got \"{s}\"\n", .{ line_num, val });
                        return error.InvalidValue;
                    }
                } else {
                    std.debug.print("config: line {}: ignoring unknown key 'renderer.{s}'\n", .{ line_num, kv.key });
                }
            },
            .unknown => {
                // Ignore keys in unknown sections
            },
        }
    }

    if (options.require_version and !saw_version) {
        std.debug.print("config: existing config file is missing required top-level 'version = 1'\n", .{});
        return error.UnsupportedVersion;
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

const ParsedSection = struct {
    section: Section,
    name: []const u8,
};

fn shouldTrackSection(section: Section) bool {
    return section != .unknown;
}

fn shouldTrackKey(section: Section, key: []const u8) bool {
    return switch (section) {
        .top => std.mem.eql(u8, key, "version") or std.mem.eql(u8, key, "fps"),
        .outputs => std.mem.eql(u8, key, "policy"),
        .effect => std.mem.eql(u8, key, "name"),
        .effect_settings => std.mem.eql(u8, key, "palette") or std.mem.eql(u8, key, "speed"),
        .renderer => std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "upscale_filter"),
        .unknown => false,
    };
}

fn parseSectionHeader(line: []const u8) ?ParsedSection {
    if (line.len < 2 or line[0] != '[') return null;
    // Find closing bracket
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    if (close < 2) return null;
    if (std.mem.trim(u8, line[close + 1 ..], &std.ascii.whitespace).len != 0) return null;
    const name = std.mem.trim(u8, line[1..close], &std.ascii.whitespace);

    if (std.mem.eql(u8, name, "outputs")) return .{ .section = .outputs, .name = name };
    if (std.mem.eql(u8, name, "effect")) return .{ .section = .effect, .name = name };
    if (std.mem.eql(u8, name, "effect.settings")) return .{ .section = .effect_settings, .name = name };
    if (std.mem.eql(u8, name, "renderer")) return .{ .section = .renderer, .name = name };
    return .{ .section = .unknown, .name = name };
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
    if (std.mem.trim(u8, value[close + 1 ..], &std.ascii.whitespace).len != 0) return null;
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
    if (std.mem.trim(u8, value[close + 1 ..], &std.ascii.whitespace).len != 0) return null;
    const inner = value[1..close];

    var result = StringArray{ .buf = undefined, .len = 0 };

    var pos: usize = 0;
    var needs_comma = false;
    while (pos < inner.len) {
        while (pos < inner.len and std.ascii.isWhitespace(inner[pos])) {
            pos += 1;
        }
        if (pos >= inner.len) break;

        if (needs_comma) {
            if (inner[pos] != ',') return null;
            pos += 1;
            while (pos < inner.len and std.ascii.isWhitespace(inner[pos])) {
                pos += 1;
            }
            if (pos >= inner.len) return null;
        }

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
        needs_comma = true;
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
        \\[renderer]
        \\scale = 1.0
        \\upscale_filter = "nearest"
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

test "parseAndValidate existing config requires version" {
    const toml = "fps = 15\n";
    try std.testing.expectError(error.UnsupportedVersion, parseAndValidateExistingConfig(toml));
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

test "parseAndValidate duplicate top-level key fails" {
    const toml =
        \\version = 1
        \\fps = 15
        \\fps = 30
    ;
    try std.testing.expectError(error.DuplicateConfigEntry, parseAndValidateExistingConfig(toml));
}

test "parseAndValidate duplicate section fails" {
    const toml =
        \\version = 1
        \\
        \\[renderer]
        \\scale = 0.5
        \\
        \\[renderer]
        \\upscale_filter = "nearest"
    ;
    try std.testing.expectError(error.DuplicateConfigEntry, parseAndValidateExistingConfig(toml));
}

test "parseAndValidate repeated unknown sections are ignored" {
    const toml =
        \\version = 1
        \\
        \\[future]
        \\foo = 1
        \\
        \\[future]
        \\foo = 2
    ;
    const cfg = try parseAndValidateExistingConfig(toml);
    try std.testing.expectEqual(defaultConfig().fps, cfg.fps);
}

test "parseAndValidate duplicate unknown keys are ignored" {
    const toml =
        \\version = 1
        \\
        \\[future]
        \\foo = 1
        \\foo = 2
    ;
    const cfg = try parseAndValidateExistingConfig(toml);
    try std.testing.expectEqual(defaultConfig().fps, cfg.fps);
}

test "parseAndValidate duplicate unknown key in known section is ignored" {
    const toml =
        \\version = 1
        \\
        \\[renderer]
        \\future = 1
        \\future = 2
        \\scale = 1.0
    ;
    const cfg = try parseAndValidateExistingConfig(toml);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.renderer_scale, 0.001);
}

test "parseAndValidate renderer scale must be finite" {
    const toml = "[renderer]\nscale = inf\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate palette needs commas" {
    const toml = "[effect.settings]\npalette = [\"#ff0000\" \"#00ff00\", \"#0000ff\"]\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate quoted values reject trailing junk" {
    const toml = "[renderer]\nupscale_filter = \"nearest\" trailing\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
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

test "parseAndValidate renderer scale near one is rejected" {
    const toml = "[renderer]\nscale = 0.95\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
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

test "parseAndValidate glass_drift effect" {
    const toml = "[effect]\nname = \"glass_drift\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.glass_drift, cfg.effect_type);
}

test "parseAndValidate colormix effect explicit" {
    const toml = "[effect]\nname = \"colormix\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.colormix, cfg.effect_type);
}

test "parseAndValidate speed valid min" {
    const toml = "[effect.settings]\nspeed = 0.25\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cfg.speed, 0.001);
}

test "parseAndValidate speed valid max" {
    const toml = "[effect.settings]\nspeed = 2.5\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), cfg.speed, 0.001);
}

test "parseAndValidate speed too low" {
    const toml = "[effect.settings]\nspeed = 0.24\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate speed too high" {
    const toml = "[effect.settings]\nspeed = 2.51\n";
    try std.testing.expectError(error.InvalidValue, parseAndValidate(toml));
}

test "parseAndValidate speed missing uses default" {
    const toml = "";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.speed, 0.001);
}

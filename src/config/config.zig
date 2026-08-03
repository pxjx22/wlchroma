const std = @import("std");
const defaults = @import("defaults.zig");
const Rgb = defaults.Rgb;

pub const UpscaleFilter = enum {
    nearest,
    linear,
};

/// A named palette entry loaded from the config's [[palettes]] table.
/// The name is stored in a fixed-size buffer to avoid heap lifetime issues.
pub const NamedPalette = struct {
    name: [64:0]u8,
    name_len: usize,
    colors: [3]Rgb,

    pub fn nameSlice(self: *const NamedPalette) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Full result of loading a config file: the parsed AppConfig plus a
/// heap-allocated slice of named palettes (may be empty). The caller owns
/// the palettes slice and must free it with the same allocator.
pub const LoadResult = struct {
    config: AppConfig,
    palettes: []NamedPalette,

    pub fn deinit(result: *LoadResult, allocator: std.mem.Allocator) void {
        allocator.free(result.palettes);
        result.* = undefined;
    }
};

pub const ConfigPathOrigin = enum { explicit, default };

pub const ResolvedConfigPath = struct {
    path: []const u8,
    origin: ConfigPathOrigin,
};

pub const EffectType = enum {
    colormix,
    glass_drift,
    frond_haze,
    lumen_tunnel,
    velvet_mesh,
    starfield_fog,
    gyro_echo,
    hex_floret,
    dither_orb,
    signal_matrix,
    fract_lattice,
};

pub const AppConfig = struct {
    fps: u32,
    frame_interval_ns: u32,
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
        .effect_type = .colormix,
        .palette = .{ defaults.DEFAULT_COL1, defaults.DEFAULT_COL2, defaults.DEFAULT_COL3 },
        .speed = 1.0,
        .renderer_scale = 1.0,
        .upscale_filter = .nearest,
    };
}

const DEFAULT_FPS: u32 = 15;

/// Maximum accepted config file size in bytes.
const MAX_CONFIG_SIZE = 64 * 1024;

/// Load config and return both AppConfig and named palettes.
/// The returned palettes slice is heap-allocated; caller must free it.
pub fn loadConfigFull(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    explicit_path: ?[]const u8,
) !LoadResult {
    if (explicit_path) |ep| {
        return loadConfigFullFromExplicitPath(allocator, io, ep);
    }
    return loadConfigFullFromDefaults(allocator, io, environ);
}

fn loadConfigFullFromExplicitPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadResult {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_CONFIG_SIZE)) catch |err| {
        std.debug.print("config: failed to read {s}: {}\n", .{ path, err });
        return error.ConfigFileError;
    };
    defer allocator.free(content);

    return parseAndValidateFull(allocator, content);
}

/// Like loadConfigFull, but a missing config file is an error instead of a
/// silent fall-back to built-in defaults. Used by the IPC reload path: the
/// contract promises "config file not found" there, and quietly resetting a
/// running session to defaults would be surprising.
pub fn loadConfigFullRequireFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    explicit_path: ?[]const u8,
) !LoadResult {
    const resolved = resolveConfigPathForReload(allocator, environ, explicit_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.ConfigFileNotFound,
    };
    defer allocator.free(resolved.path);

    return loadConfigFullResolved(allocator, io, resolved);
}

pub fn resolveConfigPathForReload(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    explicit_path: ?[]const u8,
) !ResolvedConfigPath {
    if (explicit_path) |path| {
        return .{
            .path = try allocator.dupe(u8, path),
            .origin = .explicit,
        };
    }

    const path = try resolveConfigPath(allocator, environ);
    if (path.allocated) {
        return .{ .path = path.slice, .origin = .default };
    }
    return .{
        .path = try allocator.dupe(u8, path.slice),
        .origin = .default,
    };
}

pub fn loadConfigFullResolved(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: ResolvedConfigPath,
) !LoadResult {
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        resolved.path,
        allocator,
        .limited(MAX_CONFIG_SIZE),
    ) catch |err| switch (resolved.origin) {
        .explicit => {
            std.debug.print("config: failed to read {s}: {}\n", .{ resolved.path, err });
            return error.ConfigFileError;
        },
        .default => switch (err) {
            error.FileNotFound => return error.ConfigFileNotFound,
            else => {
                std.debug.print("config: failed to read {s}: {}\n", .{ resolved.path, err });
                return error.ConfigFileError;
            },
        },
    };
    defer allocator.free(content);

    return parseAndValidateFull(allocator, content);
}

fn loadConfigFullFromDefaults(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !LoadResult {
    const path = resolveConfigPath(allocator, environ) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.debug.print("config: could not resolve config path, using defaults\n", .{});
                return LoadResult{ .config = defaultConfig(), .palettes = try allocator.alloc(NamedPalette, 0) };
            },
        }
    };
    defer if (path.allocated) allocator.free(path.slice);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path.slice, allocator, .limited(MAX_CONFIG_SIZE)) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.debug.print("config: no config file found at {s}, using defaults\n", .{path.slice});
                return LoadResult{ .config = defaultConfig(), .palettes = try allocator.alloc(NamedPalette, 0) };
            },
            else => {
                std.debug.print("config: failed to read {s}: {}\n", .{ path.slice, err });
                return error.ConfigFileError;
            },
        }
    };
    defer allocator.free(content);

    return parseAndValidateFull(allocator, content);
}

const ConfigPath = struct {
    slice: []const u8,
    allocated: bool,
};

fn resolveConfigPath(allocator: std.mem.Allocator, environ: std.process.Environ) !ConfigPath {
    // Try XDG_CONFIG_HOME first
    if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) {
            const path = try std.fmt.allocPrint(allocator, "{s}/wlchroma/config.toml", .{xdg});
            return .{ .slice = path, .allocated = true };
        }
    }

    // Fall back to $HOME/.config
    if (environ.getPosix("HOME")) |home| {
        if (home.len > 0) {
            const path = try std.fmt.allocPrint(allocator, "{s}/.config/wlchroma/config.toml", .{home});
            return .{ .slice = path, .allocated = true };
        }
    }

    return error.NoHome;
}

const MAX_SEEN_KEYS = 64;
const MAX_PALETTES = 64;

const ParseError = error{
    MalformedConfig,
    DuplicateConfigEntry,
    InvalidValue,
    UnsupportedPolicy,
    UnsupportedEffect,
};

const ParsedDocument = struct {
    config: AppConfig,
    palettes: [MAX_PALETTES]NamedPalette,
    palette_count: usize,
};

fn finalizePalette(
    document: *ParsedDocument,
    current: *const NamedPalette,
    has_name: bool,
    has_colors: bool,
) ParseError!void {
    if (!has_name or !has_colors) return error.MalformedConfig;
    if (document.palette_count >= document.palettes.len) return error.MalformedConfig;
    document.palettes[document.palette_count] = current.*;
    document.palette_count += 1;
}
/// Scales in [this, 1.0) are rejected as visually indistinguishable from
/// native while still paying the offscreen-FBO cost. Shared by config
/// validation and the IPC set-scale handler so both enforce the same rule.
pub const RENDERER_SCALE_NEAR_NATIVE_MIN: f32 = 0.95;

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

fn parseAndValidate(content: []const u8) ParseError!AppConfig {
    return (try parseDocument(content)).config;
}

fn parseDocument(content: []const u8) ParseError!ParsedDocument {
    return parseDocumentObserved(content, null);
}

fn parseDocumentObserved(
    content: []const u8,
    line_visits: ?*usize,
) ParseError!ParsedDocument {
    try validateDocumentBytes(content);

    var document = ParsedDocument{
        .config = defaultConfig(),
        .palettes = undefined,
        .palette_count = 0,
    };

    // Current section path, e.g. "" for top-level, "outputs", "effect", "effect.settings"
    var section: Section = .top;
    var section_name: []const u8 = "";
    var seen_sections = SeenNames{ .buf = undefined, .len = 0 };
    var seen_keys = SeenKeys{ .buf = undefined, .len = 0 };
    var seen_palette_names = SeenNames{ .buf = undefined, .len = 0 };
    var current_palette = std.mem.zeroes(NamedPalette);
    var palette_active = false;
    var palette_has_name = false;
    var palette_has_colors = false;

    var line_num: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        line_num += 1;
        if (line_visits) |visits| visits.* += 1;
        const line = stripComment(std.mem.trim(u8, raw_line, &std.ascii.whitespace));

        if (line.len == 0) continue;

        // Section header
        if (line[0] == '[') {
            const parsed_section = parseSectionHeader(line) orelse {
                std.debug.print("config: line {}: malformed section header\n", .{line_num});
                return error.MalformedConfig;
            };
            if (palette_active) {
                finalizePalette(
                    &document,
                    &current_palette,
                    palette_has_name,
                    palette_has_colors,
                ) catch |err| {
                    if (!palette_has_name or !palette_has_colors) {
                        std.debug.print("config: [[palettes]] entry before line {} is missing name or colors\n", .{line_num});
                    } else {
                        std.debug.print("config: too many [[palettes]] entries (max {})\n", .{MAX_PALETTES});
                    }
                    return err;
                };
                palette_active = false;
                palette_has_name = false;
                palette_has_colors = false;
            }
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
            if (section == .palettes_entry) {
                current_palette = std.mem.zeroes(NamedPalette);
                palette_active = true;
            }
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
                    // Accepted for backward compatibility with older configs;
                    // the value never gated any behavior and is ignored.
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
                    document.config.fps = fps_u32;
                    document.config.frame_interval_ns = 1_000_000_000 / fps_u32;
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
                        document.config.effect_type = effect_type;
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
                    document.config.speed = speed;
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
                        document.config.palette[i] = parseHexColor(color_str) orelse {
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
                    document.config.renderer_scale = scale;
                } else if (std.mem.eql(u8, kv.key, "upscale_filter")) {
                    const val = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: 'renderer.upscale_filter' must be \"nearest\" or \"linear\"\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (std.mem.eql(u8, val, "nearest")) {
                        document.config.upscale_filter = .nearest;
                    } else if (std.mem.eql(u8, val, "linear")) {
                        document.config.upscale_filter = .linear;
                    } else {
                        std.debug.print("config: line {}: 'renderer.upscale_filter' must be \"nearest\" or \"linear\", got \"{s}\"\n", .{ line_num, val });
                        return error.InvalidValue;
                    }
                } else {
                    std.debug.print("config: line {}: ignoring unknown key 'renderer.{s}'\n", .{ line_num, kv.key });
                }
            },
            .palettes_entry => {
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (palette_has_name) {
                        std.debug.print("config: line {}: duplicate 'name' in [[palettes]] entry\n", .{line_num});
                        return error.DuplicateConfigEntry;
                    }
                    const name = parseQuotedString(kv.value) orelse {
                        std.debug.print("config: line {}: [[palettes]] name must be a quoted string\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (name.len == 0 or name.len > 63) {
                        std.debug.print("config: line {}: [[palettes]] name must be 1–63 UTF-8 bytes\n", .{line_num});
                        return error.InvalidValue;
                    }
                    seen_palette_names.add(name) catch |err| switch (err) {
                        error.DuplicateConfigEntry => {
                            std.debug.print("config: line {}: duplicate palette name \"{s}\"\n", .{ line_num, name });
                            return error.DuplicateConfigEntry;
                        },
                        else => return err,
                    };
                    @memcpy(current_palette.name[0..name.len], name);
                    current_palette.name_len = name.len;
                    palette_has_name = true;
                } else if (std.mem.eql(u8, kv.key, "colors")) {
                    if (palette_has_colors) {
                        std.debug.print("config: line {}: duplicate 'colors' in [[palettes]] entry\n", .{line_num});
                        return error.DuplicateConfigEntry;
                    }
                    const colors = parseStringArray(kv.value) orelse {
                        std.debug.print("config: line {}: [[palettes]] colors must be an array of 3 '#RRGGBB' strings\n", .{line_num});
                        return error.InvalidValue;
                    };
                    if (colors.len != 3) {
                        std.debug.print("config: line {}: [[palettes]] colors must have exactly 3 entries, got {}\n", .{ line_num, colors.len });
                        return error.InvalidValue;
                    }
                    for (colors.items(), 0..) |color_str, i| {
                        current_palette.colors[i] = parseHexColor(color_str) orelse {
                            std.debug.print("config: line {}: [[palettes]] color {} must be '#RRGGBB', got \"{s}\"\n", .{ line_num, i + 1, color_str });
                            return error.InvalidValue;
                        };
                    }
                    palette_has_colors = true;
                } else {
                    std.debug.print("config: line {}: ignoring unknown key 'palettes.{s}'\n", .{ line_num, kv.key });
                }
            },
            .unknown => {
                // Ignore keys in unknown sections
            },
        }
    }

    if (palette_active) {
        finalizePalette(
            &document,
            &current_palette,
            palette_has_name,
            palette_has_colors,
        ) catch |err| {
            if (!palette_has_name or !palette_has_colors) {
                std.debug.print("config: [[palettes]] entry at end of file is missing name or colors\n", .{});
            } else {
                std.debug.print("config: too many [[palettes]] entries (max {})\n", .{MAX_PALETTES});
            }
            return err;
        };
    }

    return document;
}

/// Like parseAndValidate but also returns [[palettes]] entries.
/// The returned palettes slice is heap-allocated; caller must free it.
fn parseAndValidateFull(
    allocator: std.mem.Allocator,
    content: []const u8,
) (ParseError || std.mem.Allocator.Error)!LoadResult {
    const document = try parseDocument(content);
    const palettes = try allocator.dupe(NamedPalette, document.palettes[0..document.palette_count]);
    return .{ .config = document.config, .palettes = palettes };
}

const Section = enum {
    top,
    outputs,
    effect,
    effect_settings,
    renderer,
    palettes_entry, // inside a [[palettes]] array-of-tables entry
    unknown,
};

const ParsedSection = struct {
    section: Section,
    name: []const u8,
};

fn shouldTrackSection(section: Section) bool {
    // palettes_entry appears multiple times by design (array-of-tables); don't dedup-track it.
    return section != .unknown and section != .palettes_entry;
}

fn shouldTrackKey(section: Section, key: []const u8) bool {
    return switch (section) {
        .top => std.mem.eql(u8, key, "version") or std.mem.eql(u8, key, "fps"),
        .outputs => std.mem.eql(u8, key, "policy"),
        .effect => std.mem.eql(u8, key, "name"),
        .effect_settings => std.mem.eql(u8, key, "palette") or std.mem.eql(u8, key, "speed"),
        .renderer => std.mem.eql(u8, key, "scale") or std.mem.eql(u8, key, "upscale_filter"),
        // palettes_entry keys are tracked per-entry in parseDocument.
        .palettes_entry, .unknown => false,
    };
}

fn parseSectionHeader(line: []const u8) ?ParsedSection {
    if (line.len < 2 or line[0] != '[') return null;

    // Detect [[name]] (TOML array-of-tables).
    if (line.len >= 4 and line[1] == '[') {
        const close2 = std.mem.indexOf(u8, line, "]]") orelse return null;
        if (close2 < 3) return null;
        if (std.mem.trim(u8, line[close2 + 2 ..], &std.ascii.whitespace).len != 0) return null;
        const name = std.mem.trim(u8, line[2..close2], &std.ascii.whitespace);
        if (std.mem.eql(u8, name, "palettes")) return .{ .section = .palettes_entry, .name = name };
        return .{ .section = .unknown, .name = name };
    }

    // Single-bracket [name].
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
    const key = std.mem.trimEnd(u8, line[0..eq], &std.ascii.whitespace);
    if (key.len == 0) return null;
    const value = std.mem.trimStart(u8, line[eq + 1 ..], &std.ascii.whitespace);
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

fn validateDocumentBytes(content: []const u8) error{MalformedConfig}!void {
    if (!std.unicode.utf8ValidateSlice(content)) return error.MalformedConfig;
    for (content, 0..) |byte, i| {
        if (byte == '\t' or byte == '\n') continue;
        if (byte == '\r') {
            if (i + 1 < content.len and content[i + 1] == '\n') continue;
            return error.MalformedConfig;
        }
        if (byte < 0x20 or byte == 0x7f) return error.MalformedConfig;
    }
}

fn parseQuotedString(value: []const u8) ?[]const u8 {
    if (value.len < 2) return null;
    if (value[0] != '"') return null;
    var pos: usize = 1;
    while (pos < value.len) : (pos += 1) {
        if (value[pos] == '\\') return null;
        if (value[pos] == '"') {
            if (std.mem.trim(u8, value[pos + 1 ..], &std.ascii.whitespace).len != 0) return null;
            return value[1..pos];
        }
    }
    return null;
}

fn stripComment(line: []const u8) []const u8 {
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (in_quote and line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == '"') in_quote = !in_quote;
        if (line[i] == '#' and !in_quote) {
            return std.mem.trimEnd(u8, line[0..i], &std.ascii.whitespace);
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
        while (pos < inner.len and inner[pos] != '"') : (pos += 1) {
            if (inner[pos] == '\\') return null;
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

test "parseAndValidate ignores version value" {
    const toml = "version = 3\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(defaultConfig().fps, cfg.fps);
}

test "parseAndValidate version 2 accepted" {
    const toml = "version = 2\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(defaultConfig().fps, cfg.fps);
}

test "parseAndValidateFull collects named palettes" {
    const allocator = std.testing.allocator;
    const toml =
        "version = 2\n" ++
        "[[palettes]]\n" ++
        "name = \"ocean\"\n" ++
        "colors = [\"#0077b6\", \"#00b4d8\", \"#90e0ef\"]\n";

    const result = try parseAndValidateFull(allocator, toml);
    defer allocator.free(result.palettes);

    try std.testing.expectEqual(@as(usize, 1), result.palettes.len);
    try std.testing.expectEqualStrings("ocean", result.palettes[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 0x00), result.palettes[0].colors[0].r);
    try std.testing.expectEqual(@as(u8, 0xb4), result.palettes[0].colors[1].g);
    try std.testing.expectEqual(@as(u8, 0xef), result.palettes[0].colors[2].b);
}

test "parseAndValidateFull accepts a 63-byte multibyte palette name and rejects 64 bytes" {
    const name_63 = "あいうえおあいうえおあいうえおあいうえおあ";
    const name_64 = "あいうえおあいうえおあいうえおあいうえおあx";
    const valid_toml =
        "[[palettes]]\n" ++
        "name = \"あいうえおあいうえおあいうえおあいうえおあ\"\n" ++
        "colors = [\"#0077b6\", \"#00b4d8\", \"#90e0ef\"]\n";
    const invalid_toml =
        "[[palettes]]\n" ++
        "name = \"あいうえおあいうえおあいうえおあいうえおあx\"\n" ++
        "colors = [\"#0077b6\", \"#00b4d8\", \"#90e0ef\"]\n";

    try std.testing.expectEqual(@as(usize, 63), name_63.len);
    try std.testing.expectEqual(@as(usize, 64), name_64.len);

    const result = try parseAndValidateFull(std.testing.allocator, valid_toml);
    defer std.testing.allocator.free(result.palettes);
    try std.testing.expectEqualStrings(name_63, result.palettes[0].nameSlice());
    try std.testing.expectError(
        error.InvalidValue,
        parseAndValidateFull(std.testing.allocator, invalid_toml),
    );
}

test "parseAndValidateFull rejects duplicate palette names" {
    const allocator = std.testing.allocator;
    const toml =
        "version = 2\n" ++
        "[[palettes]]\n" ++
        "name = \"ocean\"\n" ++
        "colors = [\"#0077b6\", \"#00b4d8\", \"#90e0ef\"]\n" ++
        "[[palettes]]\n" ++
        "name = \"ocean\"\n" ++
        "colors = [\"#88c0d0\", \"#81a1c1\", \"#5e81ac\"]\n";

    try std.testing.expectError(error.DuplicateConfigEntry, parseAndValidateFull(allocator, toml));
}

test "parseAndValidate existing config does not require version" {
    const toml = "fps = 15\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(@as(u32, 15), cfg.fps);
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
    try std.testing.expectError(error.DuplicateConfigEntry, parseAndValidate(toml));
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
    try std.testing.expectError(error.DuplicateConfigEntry, parseAndValidate(toml));
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
    const cfg = try parseAndValidate(toml);
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
    const cfg = try parseAndValidate(toml);
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
    const cfg = try parseAndValidate(toml);
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

test "parseAndValidate glass_drift effect" {
    const toml = "[effect]\nname = \"glass_drift\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.glass_drift, cfg.effect_type);
}

test "parseAndValidate frond_haze effect" {
    const toml = "[effect]\nname = \"frond_haze\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.frond_haze, cfg.effect_type);
}

test "parseAndValidate lumen_tunnel effect" {
    const toml = "[effect]\nname = \"lumen_tunnel\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.lumen_tunnel, cfg.effect_type);
}

test "parseAndValidate colormix effect explicit" {
    const toml = "[effect]\nname = \"colormix\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.colormix, cfg.effect_type);
}

test "parseAndValidate gyro_echo effect" {
    const toml = "[effect]\nname = \"gyro_echo\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.gyro_echo, cfg.effect_type);
}

test "parseAndValidate hex_floret effect" {
    const toml = "[effect]\nname = \"hex_floret\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.hex_floret, cfg.effect_type);
}

test "parseAndValidate dither_orb effect" {
    const toml = "[effect]\nname = \"dither_orb\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.dither_orb, cfg.effect_type);
}

test "parseAndValidate signal_matrix effect" {
    const toml = "[effect]\nname = \"signal_matrix\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.signal_matrix, cfg.effect_type);
}

test "parseAndValidate fract_lattice effect" {
    const toml = "[effect]\nname = \"fract_lattice\"\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(EffectType.fract_lattice, cfg.effect_type);
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

test "parseAndValidate rejects invalid UTF-8 and disallowed controls" {
    const invalid_utf8 = [_]u8{ 'f', 'p', 's', ' ', '=', ' ', '1', '5', '\n', 0xff };
    const nul = [_]u8{ 'f', 'p', 's', ' ', '=', ' ', '1', '5', 0, '\n' };
    const del = [_]u8{ 'f', 'p', 's', ' ', '=', ' ', '1', '5', 0x7f, '\n' };
    const malformed_documents = [_][]const u8{ &invalid_utf8, &nul, &del };

    for (malformed_documents) |document| {
        try std.testing.expectError(error.MalformedConfig, parseAndValidate(document));
    }
    try std.testing.expectError(
        error.MalformedConfig,
        parseAndValidate("fps = 15\rscale = 1.0\n"),
    );
}

test "parseAndValidate accepts horizontal tabs and CRLF" {
    const cfg = try parseAndValidate("fps\t=\t30\r\n");
    try std.testing.expectEqual(@as(u32, 30), cfg.fps);
}

test "parseAndValidate preserves opaque unknown and version values" {
    const toml =
        "version = \"future\\q#value\" # ignored\n" ++
        "future = \"opaque\\\"#pair\" # ignored\n" ++
        "fps = 30\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(@as(u32, 30), cfg.fps);
}

fn expectRecognizedEscapeRejected(prefix: []const u8, suffix: []const u8) !void {
    const escapes = [_][]const u8{ "\\q", "\\n", "\\u1234", "\\\"", "\\" };
    for (escapes) |escape| {
        const toml = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}{s}",
            .{ prefix, escape, suffix },
        );
        defer std.testing.allocator.free(toml);
        if (parseAndValidateFull(std.testing.allocator, toml)) |loaded_value| {
            std.testing.allocator.free(loaded_value.palettes);
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expect(err == error.InvalidValue);
        }
    }
}

test "recognized string escapes are rejected in every supported context" {
    try expectRecognizedEscapeRejected("[outputs]\npolicy = \"all", "\"\n");
    try expectRecognizedEscapeRejected("[effect]\nname = \"colormix", "\"\n");
    try expectRecognizedEscapeRejected("[renderer]\nupscale_filter = \"nearest", "\"\n");
    try expectRecognizedEscapeRejected(
        "[effect.settings]\npalette = [\"#ff0000\", \"#00ff00",
        "\", \"#0000ff\"]\n",
    );
    try expectRecognizedEscapeRejected(
        "[[palettes]]\nname = \"ocean",
        "\"\ncolors = [\"#0077b6\", \"#00b4d8\", \"#90e0ef\"]\n",
    );
    try expectRecognizedEscapeRejected(
        "[[palettes]]\nname = \"ocean\"\ncolors = [\"#0077b6\", \"#00b4d8",
        "\", \"#90e0ef\"]\n",
    );
}

test "parseAndValidateFull keeps hashes in quoted palettes while removing comments" {
    const result = try parseAndValidateFull(
        std.testing.allocator,
        "[[palettes]]\n" ++
            "name = \"ocean#night\"\n" ++
            "colors = [\"#0077b6\", \"#00b4d8\", \"#90e0ef\"] # ignored\n",
    );
    defer std.testing.allocator.free(result.palettes);

    try std.testing.expectEqualStrings("ocean#night", result.palettes[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 0x00), result.palettes[0].colors[0].r);
    try std.testing.expectEqual(@as(u8, 0xef), result.palettes[0].colors[2].b);
}

fn parseDocumentWithPaletteCount(palette_count: usize) !ParsedDocument {
    var toml: std.ArrayList(u8) = .empty;
    defer toml.deinit(std.testing.allocator);

    for (0..palette_count) |i| {
        try toml.print(
            std.testing.allocator,
            "[[palettes]]\nname = \"palette-{}\"\ncolors = [\"#010203\", \"#040506\", \"#070809\"]\n",
            .{i},
        );
    }
    return parseDocument(toml.items);
}

test "parseDocument accepts palette-count boundaries" {
    const zero = try parseDocumentWithPaletteCount(0);
    try std.testing.expectEqual(@as(usize, 0), zero.palette_count);

    const one = try parseDocumentWithPaletteCount(1);
    try std.testing.expectEqual(@as(usize, 1), one.palette_count);
    try std.testing.expectEqualStrings("palette-0", one.palettes[0].nameSlice());

    const max = try parseDocumentWithPaletteCount(64);
    try std.testing.expectEqual(@as(usize, 64), max.palette_count);
    try std.testing.expectEqualStrings("palette-63", max.palettes[63].nameSlice());

    try std.testing.expectError(error.MalformedConfig, parseDocumentWithPaletteCount(65));
}

test "parseDocument finalizes palettes at section transition and EOF" {
    const toml =
        "[[palettes]]\n" ++
        "name = \"one\"\n" ++
        "colors = [\"#010203\", \"#040506\", \"#070809\"]\n" ++
        "[renderer]\n" ++
        "scale = 0.5\n" ++
        "[[palettes]]\n" ++
        "name = \"two\"\n" ++
        "colors = [\"#111213\", \"#141516\", \"#171819\"]\n";
    const document = try parseDocument(toml);
    try std.testing.expectEqual(@as(usize, 2), document.palette_count);
    try std.testing.expectEqualStrings("one", document.palettes[0].nameSlice());
    try std.testing.expectEqualStrings("two", document.palettes[1].nameSlice());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), document.config.renderer_scale, 0.001);
}

test "parseDocument rejects incomplete palette before section transition" {
    const toml = "[[palettes]]\nname = \"one\"\n[renderer]\nscale = 0.5\n";
    try std.testing.expectError(error.MalformedConfig, parseDocument(toml));
}

test "parseDocument rejects incomplete palette at EOF" {
    const toml = "[[palettes]]\nname = \"one\"\n";
    try std.testing.expectError(error.MalformedConfig, parseDocument(toml));
}

test "parseDocument rejects duplicate keys in one repeated palette entry" {
    const toml =
        "[[palettes]]\n" ++
        "name = \"one\"\n" ++
        "name = \"two\"\n" ++
        "colors = [\"#010203\", \"#040506\", \"#070809\"]\n";
    try std.testing.expectError(error.DuplicateConfigEntry, parseDocument(toml));
}

test "parseDocument visits each input line once" {
    const toml = "fps = 30\n[effect]\nname = \"colormix\"\n[[palettes]]\nname = \"one\"\ncolors = [\"#010203\", \"#040506\", \"#070809\"]";
    var line_visits: usize = 0;
    _ = try parseDocumentObserved(toml, &line_visits);
    try std.testing.expectEqual(@as(usize, 6), line_visits);
}

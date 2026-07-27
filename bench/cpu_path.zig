const std = @import("std");
const src = @import("wlchroma_src");
const sys = @import("sys");

const Rgb = src.defaults.Rgb;
const Extent = src.dimensions.Extent;
const ShmLayout = src.dimensions.ShmLayout;
const ColormixRenderer = src.colormix.ColormixRenderer;

const warmup_batches: usize = 3;
const measured_batches: usize = 9;
const frames_per_batch: usize = 16;
const fixed_animation_time: f32 = 2.11;

const Case = struct {
    label: []const u8,
    width: u32,
    height: u32,
    outputs: usize,
};

const cases = [_]Case{
    .{ .label = "1920x1200-1", .width = 1920, .height = 1200, .outputs = 1 },
    .{ .label = "1920x1200-2", .width = 1920, .height = 1200, .outputs = 2 },
    .{ .label = "2560x1440-1", .width = 2560, .height = 1440, .outputs = 1 },
    .{ .label = "2560x1440-2", .width = 2560, .height = 1440, .outputs = 2 },
    .{ .label = "3840x2160-1", .width = 3840, .height = 2160, .outputs = 1 },
    .{ .label = "3840x2160-2", .width = 3840, .height = 2160, .outputs = 2 },
};

const stable_colors = [3]Rgb{
    .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
    .{ .r = 0x89, .g = 0xb4, .b = 0xfa },
    .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 },
};

const changing_colors = [2][3]Rgb{
    stable_colors,
    .{
        .{ .r = 0x24, .g = 0x19, .b = 0x2f },
        .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 },
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 },
    },
};

const Phase = enum {
    grid,
    expand,
    combined_stable,
    combined_changing,

    fn label(self: Phase) []const u8 {
        return switch (self) {
            .grid => "grid",
            .expand => "expand",
            .combined_stable => "combined-stable",
            .combined_changing => "combined-changing",
        };
    }
};

const phases = [_]Phase{
    .grid,
    .expand,
    .combined_stable,
    .combined_changing,
};

const Measurement = struct {
    median_ns: u64,
    checksum: u64,
};

const BenchmarkState = struct {
    allocator: std.mem.Allocator,
    layout: ShmLayout,
    outputs: usize,
    cells: []Rgb,
    pixels: []u8,
    stable_renderer: ColormixRenderer,

    fn init(allocator: std.mem.Allocator, case: Case) !BenchmarkState {
        const extent = try Extent.init(case.width, case.height);
        const layout = try ShmLayout.init(extent);
        const cells_len = try std.math.mul(usize, layout.grid.len, case.outputs);
        const pixels_len = try std.math.mul(usize, layout.total_bytes, case.outputs);

        const cells = try allocator.alloc(Rgb, cells_len);
        errdefer allocator.free(cells);
        const pixels = try allocator.alloc(u8, pixels_len);
        errdefer allocator.free(pixels);
        @memset(cells, .{ .r = 0, .g = 0, .b = 0 });
        @memset(pixels, 0);

        return .{
            .allocator = allocator,
            .layout = layout,
            .outputs = case.outputs,
            .cells = cells,
            .pixels = pixels,
            .stable_renderer = makeRenderer(stable_colors),
        };
    }

    fn deinit(self: *BenchmarkState) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.cells);
    }

    fn cellSlice(self: *BenchmarkState, output: usize) []Rgb {
        const start = output * self.layout.grid.len;
        return self.cells[start..][0..self.layout.grid.len];
    }

    fn pixelSlice(self: *BenchmarkState, output: usize, index: u1) []u8 {
        const output_start = output * self.layout.total_bytes;
        const range = self.layout.bufferRange(index);
        return self.pixels[output_start + range.start .. output_start + range.end];
    }

    fn prepareExpansion(self: *BenchmarkState) void {
        for (0..self.outputs) |output| {
            self.stable_renderer.renderGrid(
                fixed_animation_time,
                self.layout.grid,
                self.cellSlice(output),
            ) catch unreachable;
        }
    }

    fn runBatch(self: *BenchmarkState, phase: Phase) void {
        for (0..frames_per_batch) |frame| {
            const buffer_index: u1 = @intCast(frame & 1);
            switch (phase) {
                .grid => {
                    for (0..self.outputs) |output| {
                        self.stable_renderer.renderGrid(
                            fixed_animation_time,
                            self.layout.grid,
                            self.cellSlice(output),
                        ) catch unreachable;
                    }
                },
                .expand => {
                    for (0..self.outputs) |output| {
                        src.framebuffer.expandCells(
                            self.cellSlice(output),
                            self.pixelSlice(output, buffer_index),
                            self.layout,
                        ) catch unreachable;
                    }
                },
                .combined_stable => {
                    for (0..self.outputs) |output| {
                        const cells = self.cellSlice(output);
                        self.stable_renderer.renderGrid(
                            fixed_animation_time,
                            self.layout.grid,
                            cells,
                        ) catch unreachable;
                        src.framebuffer.expandCells(
                            cells,
                            self.pixelSlice(output, buffer_index),
                            self.layout,
                        ) catch unreachable;
                    }
                },
                .combined_changing => {
                    const renderer = makeRenderer(changing_colors[frame % changing_colors.len]);
                    for (0..self.outputs) |output| {
                        const cells = self.cellSlice(output);
                        renderer.renderGrid(
                            fixed_animation_time,
                            self.layout.grid,
                            cells,
                        ) catch unreachable;
                        src.framebuffer.expandCells(
                            cells,
                            self.pixelSlice(output, buffer_index),
                            self.layout,
                        ) catch unreachable;
                    }
                },
            }
        }
    }

    fn checksum(self: *BenchmarkState, phase: Phase) u64 {
        return switch (phase) {
            .grid => logicalGridChecksum(self),
            .expand, .combined_stable, .combined_changing => bytesChecksum(self.pixels),
        };
    }
};

pub fn main() !void {
    std.debug.print(
        "bench config warmup_batches={} measured_batches={} frames_per_batch={}\n",
        .{ warmup_batches, measured_batches, frames_per_batch },
    );

    for (cases) |case| {
        var state = try BenchmarkState.init(std.heap.page_allocator, case);
        defer state.deinit();

        for (phases) |phase| {
            const measurement = try measure(&state, phase);
            report(case.label, phase.label(), measurement.median_ns, measurement.checksum);
        }
    }
}

fn makeRenderer(colors: [3]Rgb) ColormixRenderer {
    return ColormixRenderer.init(
        colors[0],
        colors[1],
        colors[2],
    );
}

fn measure(state: *BenchmarkState, phase: Phase) !Measurement {
    if (phase == .expand) state.prepareExpansion();

    for (0..warmup_batches) |_| state.runBatch(phase);

    var durations: [measured_batches]u64 = undefined;
    for (&durations) |*duration| {
        const start_ns = try sys.monotonicNsChecked();
        state.runBatch(phase);
        const end_ns = try sys.monotonicNsChecked();
        if (end_ns <= start_ns) return error.NonIncreasingClock;
        duration.* = end_ns - start_ns;
    }

    const checksum = state.checksum(phase);
    std.mem.doNotOptimizeAway(checksum);
    return .{ .median_ns = median(&durations), .checksum = checksum };
}

fn logicalGridChecksum(state: *BenchmarkState) u64 {
    var checksum = fnv_offset_basis;
    for (0..state.outputs) |output| {
        const cells = state.cellSlice(output);
        for (0..state.layout.grid.height) |y| {
            for (0..state.layout.grid.width) |x| {
                const color = cells[x * state.layout.grid.height + y];
                checksumByte(&checksum, color.r);
                checksumByte(&checksum, color.g);
                checksumByte(&checksum, color.b);
            }
        }
    }
    return checksum;
}

fn bytesChecksum(bytes: []const u8) u64 {
    var checksum = fnv_offset_basis;
    for (bytes) |byte| checksumByte(&checksum, byte);
    return checksum;
}

const fnv_offset_basis: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

fn checksumByte(checksum: *u64, byte: u8) void {
    checksum.* = (checksum.* ^ byte) *% fnv_prime;
}

fn median(values: *[measured_batches]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn report(label: []const u8, phase: []const u8, ns: u64, checksum: u64) void {
    std.debug.print(
        "bench {s} {s} median_ns={} checksum={x}\n",
        .{ label, phase, ns, checksum },
    );
}

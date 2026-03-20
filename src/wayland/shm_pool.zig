const std = @import("std");
const c = @import("../wl.zig").c;
const posix = std.posix;

pub const ShmPool = struct {
    pool: ?*c.wl_shm_pool,
    buffers: [2]?*c.wl_buffer,
    busy: [2]bool,
    mmap_ptr: [*]u8,
    buf_size: usize,
    fd: posix.fd_t,

    pub fn init(shm: *c.wl_shm, width: u32, height: u32) !ShmPool {
        // Use usize for stride to prevent u32 overflow on extreme resolutions.
        const stride: usize = @as(usize, width) * 4; // XRGB8888
        const buf_size: usize = stride * @as(usize, height);
        const total_size = buf_size * 2;

        // Guard against i32 overflow: wl_shm_create_pool takes i32 size.
        if (total_size > @as(usize, @intCast(std.math.maxInt(i32)))) {
            return error.ShmTooLarge;
        }

        var self = try initResources(shm, width, height, stride, buf_size, total_size);
        // deinit handles all cleanup: buffers (null-checked), pool, mmap, fd.
        errdefer self.deinit();

        for (0..2) |i| {
            const offset: i32 = @intCast(i * buf_size);
            const buf = c.wl_shm_pool_create_buffer(
                self.pool.?,
                offset,
                @intCast(width),
                @intCast(height),
                @intCast(stride),
                c.WL_SHM_FORMAT_XRGB8888,
            ) orelse return error.BufferCreateFailed;
            self.buffers[i] = buf;
        }

        return self;
    }

    /// Allocate fd, mmap, and wl_shm_pool. Separated from init so that a
    /// single errdefer self.deinit() in init covers buffer creation failures
    /// without risking double-close of fd or double-munmap.
    fn initResources(
        shm: *c.wl_shm,
        width: u32,
        height: u32,
        stride: usize,
        buf_size: usize,
        total_size: usize,
    ) !ShmPool {
        _ = width;
        _ = height;
        _ = stride;

        const fd = try posix.memfd_create("ly-colormix-shm", 1);
        errdefer posix.close(fd);

        try posix.ftruncate(fd, @intCast(total_size));

        const mmap_result = try posix.mmap(
            null,
            total_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(mmap_result);

        const pool = c.wl_shm_create_pool(shm, @as(i32, @intCast(fd)), @as(i32, @intCast(total_size))) orelse {
            return error.ShmPoolFailed;
        };

        // Successful return: caller takes ownership of all resources via
        // the returned ShmPool struct. errdefers do not fire on success.
        return ShmPool{
            .pool = pool,
            .buffers = .{ null, null },
            .busy = .{ false, false },
            .mmap_ptr = @ptrCast(mmap_result.ptr),
            .buf_size = buf_size,
            .fd = fd,
        };
    }

    /// Register wl_buffer release listeners with caller-provided userdata
    /// and listener vtable. This allows the caller (SurfaceState) to supply
    /// a richer context (e.g. BufReleaseCtx) instead of bare *bool.
    pub fn attachListeners(
        self: *ShmPool,
        listener: *const c.wl_buffer_listener,
        data0: *anyopaque,
        data1: *anyopaque,
    ) void {
        if (self.buffers[0]) |buf| {
            _ = c.wl_buffer_add_listener(buf, listener, data0);
        }
        if (self.buffers[1]) |buf| {
            _ = c.wl_buffer_add_listener(buf, listener, data1);
        }
    }

    pub fn deinit(self: *ShmPool) void {
        for (self.buffers) |buf| {
            if (buf) |b| c.wl_buffer_destroy(b);
        }
        if (self.pool) |p| c.wl_shm_pool_destroy(p);
        const total = self.buf_size * 2;
        posix.munmap(@as([*]align(std.heap.page_size_min) u8, @alignCast(self.mmap_ptr))[0..total]);
        posix.close(self.fd);
    }

    /// Returns index of a free buffer, or null if both are busy.
    pub fn acquireBuffer(self: *ShmPool) ?u1 {
        if (!self.busy[0]) {
            self.busy[0] = true;
            return 0;
        }
        if (!self.busy[1]) {
            self.busy[1] = true;
            return 1;
        }
        return null;
    }

    pub fn pixelSlice(self: *ShmPool, idx: u1) []u8 {
        const offset = @as(usize, idx) * self.buf_size;
        return self.mmap_ptr[offset .. offset + self.buf_size];
    }

    pub fn wlBuffer(self: *ShmPool, idx: u1) *c.wl_buffer {
        return self.buffers[idx].?;
    }
};


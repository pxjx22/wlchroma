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
        const stride = width * 4; // XRGB8888
        const buf_size: usize = @as(usize, stride) * @as(usize, height);
        const total_size = buf_size * 2;

        // memfd_create with MFD_CLOEXEC = 1
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

        // Correction #4: cast fd and size to i32 for C API
        const pool = c.wl_shm_create_pool(shm, @as(i32, @intCast(fd)), @as(i32, @intCast(total_size))) orelse {
            posix.munmap(mmap_result);
            posix.close(fd);
            return error.ShmPoolFailed;
        };

        var self = ShmPool{
            .pool = pool,
            .buffers = .{ null, null },
            .busy = .{ false, false },
            .mmap_ptr = @ptrCast(mmap_result.ptr),
            .buf_size = buf_size,
            .fd = fd,
        };

        // Correction #6: wire wl_buffer_listener.release for busy state tracking
        for (0..2) |i| {
            const offset: i32 = @intCast(i * buf_size);
            const buf = c.wl_shm_pool_create_buffer(
                pool,
                offset,
                @intCast(width),
                @intCast(height),
                @intCast(stride),
                c.WL_SHM_FORMAT_XRGB8888,
            ) orelse return error.BufferCreateFailed;
            self.buffers[i] = buf;
            _ = c.wl_buffer_add_listener(buf, &buf_listener, &self.busy[i]);
        }

        return self;
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

const buf_listener = c.wl_buffer_listener{
    .release = bufferRelease,
};

fn bufferRelease(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = buffer;
    const busy: *bool = @ptrCast(@alignCast(data));
    busy.* = false;
}

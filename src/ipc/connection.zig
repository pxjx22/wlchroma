const std = @import("std");

pub const REQUEST_MAX: usize = 4096;
pub const RESPONSE_MAX: usize = 1024;
pub const PHASE_TIMEOUT_NS: u64 = 500 * std.time.ns_per_ms;

pub const FeedResult = union(enum) {
    incomplete,
    complete: []const u8,
    line_too_long,
    extra_data,
};

pub const RequestAccumulator = struct {
    bytes: [REQUEST_MAX]u8 = undefined,
    len: usize = 0,
    status: enum { reading, complete, rejected } = .reading,
    line_len: usize = 0,

    pub fn feed(self: *RequestAccumulator, chunk: []const u8) FeedResult {
        if (self.status != .reading) return .extra_data;

        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline_index| {
            const wire_len = newline_index + 1;
            const remaining = self.bytes.len - self.len;
            if (wire_len > remaining) {
                self.status = .rejected;
                return .line_too_long;
            }
            if (wire_len != chunk.len) {
                self.status = .rejected;
                return .extra_data;
            }

            @memcpy(self.bytes[self.len .. self.len + wire_len], chunk);
            self.len += wire_len;
            var end = self.len - 1;
            if (end > 0 and self.bytes[end - 1] == '\r') end -= 1;
            self.line_len = end;
            self.status = .complete;
            return .{ .complete = self.bytes[0..end] };
        }

        const remaining = self.bytes.len - self.len;
        if (chunk.len >= remaining) {
            self.status = .rejected;
            return .line_too_long;
        }
        @memcpy(self.bytes[self.len .. self.len + chunk.len], chunk);
        self.len += chunk.len;
        return .incomplete;
    }

    pub fn line(self: *const RequestAccumulator) []const u8 {
        std.debug.assert(self.status == .complete);
        return self.bytes[0..self.line_len];
    }
};

pub const ResponseQueue = struct {
    bytes: [RESPONSE_MAX]u8 = undefined,
    len: usize = 0,
    sent_offset: usize = 0,
    failed_closed: bool = false,

    pub fn appendLine(self: *ResponseQueue, line: []const u8) void {
        if (self.failed_closed) return;
        const remaining = self.bytes.len - self.len;
        if (line.len >= remaining) {
            self.failInternal();
            return;
        }
        @memcpy(self.bytes[self.len .. self.len + line.len], line);
        self.bytes[self.len + line.len] = '\n';
        self.len += line.len + 1;
    }

    pub fn pending(self: *const ResponseQueue) []const u8 {
        return self.bytes[self.sent_offset..self.len];
    }

    pub fn consume(self: *ResponseQueue, written: usize) error{InvalidWriteCount}!void {
        if (written > self.pending().len) return error.InvalidWriteCount;
        self.sent_offset += written;
    }

    pub fn isComplete(self: *const ResponseQueue) bool {
        return self.sent_offset == self.len;
    }

    pub fn failInternal(self: *ResponseQueue) void {
        if (self.sent_offset != 0) {
            self.len = self.sent_offset;
            self.failed_closed = true;
            return;
        }
        const internal = "error: internal\n";
        @memcpy(self.bytes[0..internal.len], internal);
        self.len = internal.len;
        self.sent_offset = 0;
        self.failed_closed = true;
    }
};

pub fn deadlineAfter(now_ns: u64) u64 {
    return now_ns +| PHASE_TIMEOUT_NS;
}

pub fn deadlineExpired(now_ns: u64, deadline_ns: u64) bool {
    return now_ns >= deadline_ns;
}

pub fn pollTimeoutMs(now_ns: u64, deadline_ns: u64) i32 {
    if (deadlineExpired(now_ns, deadline_ns)) return 0;
    const remaining_ns = deadline_ns - now_ns;
    const milliseconds = 1 + (remaining_ns - 1) / std.time.ns_per_ms;
    const max_timeout_ms: u64 = @intCast(std.math.maxInt(i32));
    return @intCast(@min(milliseconds, max_timeout_ms));
}

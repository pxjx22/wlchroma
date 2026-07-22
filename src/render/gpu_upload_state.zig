pub const DirtyBits = packed struct(u8) {
    program_binding: bool = false,
    palette: bool = false,
    static_uniforms: bool = false,
    _padding: u5 = 0,
};

pub const GpuUploadState = packed struct(u8) {
    dirty: DirtyBits = .{},

    pub fn newGeneration() GpuUploadState {
        return .{ .dirty = .{
            .program_binding = true,
            .palette = true,
            .static_uniforms = true,
        } };
    }

    pub fn clear(self: *GpuUploadState) void {
        self.* = .{};
    }

    pub fn markPaletteDirty(self: *GpuUploadState, shader_live: bool) void {
        if (shader_live) self.dirty.palette = true;
    }

    pub fn isClean(self: *const GpuUploadState) bool {
        return !self.dirty.program_binding and
            !self.dirty.palette and
            !self.dirty.static_uniforms;
    }

    pub fn flushIfCurrent(
        self: *GpuUploadState,
        comptime Ops: type,
        ops: *Ops,
        confirmed_current: bool,
    ) void {
        if (!confirmed_current or self.isClean()) return;
        ops.useProgram();
        if (self.dirty.program_binding) {
            ops.bindGeometry();
            self.dirty.program_binding = false;
        }
        if (self.dirty.palette) {
            ops.uploadPalette();
            self.dirty.palette = false;
        }
        if (self.dirty.static_uniforms) {
            ops.uploadStatic();
            self.dirty.static_uniforms = false;
        }
    }
};

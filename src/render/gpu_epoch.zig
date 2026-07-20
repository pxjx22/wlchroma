pub fn handlesMatch(
    current_draw: anytype,
    expected_draw: @TypeOf(current_draw),
    current_context: anytype,
    expected_context: @TypeOf(current_context),
) bool {
    return current_draw == expected_draw and current_context == expected_context;
}

pub fn acquireCurrent(comptime Ops: type, ops: *Ops) bool {
    for (0..ops.candidateCount()) |index| {
        if (ops.tryMakeCurrent(index)) return true;
    }
    return false;
}

pub fn close(comptime Ops: type, ops: *Ops) void {
    ops.detachAll();
    const has_current = acquireCurrent(Ops, ops);
    const count = ops.candidateCount();
    if (has_current) {
        ops.deleteAppGl();
        for (0..count) |index| ops.deleteSurfaceGl(index);
    }
    ops.clearCurrent();
    for (0..count) |index| ops.destroySurface(index);
    ops.destroyContext();
    ops.clearHandles();
}

pub fn shouldStart(has_context: bool, permanent_failure: bool, ready_outputs: usize) bool {
    return !has_context and !permanent_failure and ready_outputs > 0;
}

pub fn start(comptime Ops: type, ops: *Ops) bool {
    if (ops.hasContext()) return true;
    if (ops.permanentFailure()) return false;
    if (ops.readyOutputCount() == 0) return false;
    return ops.createContext();
}

pub fn requiresCpuFallback(permanent_failure: bool, gpu_only: bool) bool {
    return permanent_failure and gpu_only;
}

pub fn replaceCurrentOwned(comptime Ops: type, ops: *Ops) bool {
    if (!ops.acquireCurrent()) return false;
    const replacement = ops.createReplacement() catch return false;
    ops.commitReplacement(replacement);
    return true;
}

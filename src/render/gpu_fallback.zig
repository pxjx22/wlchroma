/// Apply the one-way CPU fallback transition after a permanent GPU pipeline
/// failure. The operations adapter keeps resource ownership and surface
/// details outside this pure ordering model.
pub fn apply(comptime Ops: type, ops: *Ops) bool {
    if (!ops.permanentFailure() or ops.fallbackApplied()) return false;

    ops.closeGpuEpoch();
    if (ops.effectIsGpuOnly()) {
        ops.replaceWithColormix(ops.currentPalette());
    }
    ops.invalidateCpuStandins();
    ops.configureCpuSurfaces();
    ops.markFallbackApplied();
    return true;
}

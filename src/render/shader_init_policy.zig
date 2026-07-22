const build_options = @import("build_options");

pub const Error = error{Phase3aForcedShaderInitFailure};

pub fn beforeInitialization() Error!void {
    if (build_options.phase3a_force_shader_init_failure) {
        return error.Phase3aForcedShaderInitFailure;
    }
}

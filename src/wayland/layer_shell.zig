const std = @import("std");
const c = @import("../wl.zig").c;

pub const LayerSurface = struct {
    wl_surface: ?*c.wl_surface,
    layer_surface: ?*c.zwlr_layer_surface_v1,

    pub fn create(
        compositor: *c.wl_compositor,
        layer_shell: *c.zwlr_layer_shell_v1,
        wl_output: ?*c.wl_output,
        namespace: [*:0]const u8,
    ) !LayerSurface {
        const wl_surf = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surf);

        const layer_surf = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surf,
            wl_output,
            c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
            namespace,
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_size(layer_surf, 0, 0);
        c.zwlr_layer_surface_v1_set_anchor(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surf, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surf,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        return LayerSurface{
            .wl_surface = wl_surf,
            .layer_surface = layer_surf,
        };
    }

    pub fn destroy(self: *LayerSurface) void {
        if (self.layer_surface) |ls| {
            c.zwlr_layer_surface_v1_destroy(ls);
            self.layer_surface = null;
        }
        if (self.wl_surface) |ws| {
            c.wl_surface_destroy(ws);
            self.wl_surface = null;
        }
    }
};

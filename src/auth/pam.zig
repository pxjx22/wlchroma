const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("security/pam_appl.h");
});

const PamConvState = struct {
    password: [*c]const u8,
    password_len: usize,
};

fn pamConversation(
    num_msg: c_int,
    msg: [*c][*c]const c.pam_message,
    resp: [*c][*c]c.pam_response,
    appdata_ptr: ?*anyopaque,
) callconv(.c) c_int {
    const state: *PamConvState = @ptrCast(@alignCast(appdata_ptr));

    const responses: [*c]c.pam_response = @ptrCast(@alignCast(
        c.calloc(@intCast(num_msg), @sizeOf(c.pam_response)),
    ));
    if (responses == null) return c.PAM_BUF_ERR;

    var i: c_int = 0;
    while (i < num_msg) : (i += 1) {
        const m = msg[@intCast(i)];
        switch (m.*.msg_style) {
            c.PAM_PROMPT_ECHO_OFF, c.PAM_PROMPT_ECHO_ON => {
                const copy: [*c]u8 = @ptrCast(
                    c.calloc(state.password_len + 1, 1),
                );
                if (copy == null) {
                    var j: c_int = 0;
                    while (j < i) : (j += 1) {
                        if (responses[@intCast(j)].resp) |r| c.free(r);
                    }
                    c.free(responses);
                    return c.PAM_BUF_ERR;
                }
                @memcpy(copy[0..state.password_len], state.password[0..state.password_len]);
                copy[state.password_len] = 0;
                responses[@intCast(i)].resp = copy;
                responses[@intCast(i)].resp_retcode = 0;
            },
            c.PAM_ERROR_MSG, c.PAM_TEXT_INFO => {
                responses[@intCast(i)].resp = null;
                responses[@intCast(i)].resp_retcode = 0;
            },
            else => {
                var j: c_int = 0;
                while (j < i) : (j += 1) {
                    if (responses[@intCast(j)].resp) |r| c.free(r);
                }
                c.free(responses);
                return c.PAM_CONV_ERR;
            },
        }
    }

    resp.* = responses;
    return c.PAM_SUCCESS;
}

/// Authenticate the given user with a password against the "login" PAM service.
/// Returns true on success, false on any failure.
pub fn authenticate(username: [:0]const u8, password: []const u8) bool {
    var state = PamConvState{
        .password = password.ptr,
        .password_len = password.len,
    };

    var conv = c.pam_conv{
        .conv = pamConversation,
        .appdata_ptr = &state,
    };

    var pamh: ?*c.pam_handle_t = null;
    var ret = c.pam_start("login", username.ptr, &conv, &pamh);
    if (ret != c.PAM_SUCCESS) {
        std.debug.print("pam_start failed: {s}\n", .{c.pam_strerror(pamh, ret)});
        return false;
    }
    defer _ = c.pam_end(pamh, ret);

    ret = c.pam_authenticate(pamh, 0);
    if (ret != c.PAM_SUCCESS) {
        return false;
    }

    ret = c.pam_acct_mgmt(pamh, 0);
    return ret == c.PAM_SUCCESS;
}

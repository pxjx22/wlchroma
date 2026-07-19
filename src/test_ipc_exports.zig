//! Source-root shim for out-of-tree IPC tests under tests/ipc/. Keeping the
//! module root at src/ allows IPC modules to use their production relative
//! imports while tests consume both the public parser and hardening internals.

pub const dispatch = @import("ipc/dispatch.zig");
pub const connection = @import("ipc/connection.zig");

pub const IpcCommand = dispatch.IpcCommand;
pub const ParseError = dispatch.ParseError;
pub const parseLine = dispatch.parseLine;
pub const PALETTE_NAME_MAX = dispatch.PALETTE_NAME_MAX;

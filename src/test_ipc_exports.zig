//! Module root for the out-of-tree IPC protocol test under tests/ipc/. Rooting
//! the module at src/ keeps dispatch.zig's relative imports (server.zig and
//! ../config/config.zig) within the module root directory — the same trick
//! test_exports.zig uses for the effect tests. Re-exports the dispatch API the
//! test consumes under the "dispatch" import name.

const dispatch = @import("ipc/dispatch.zig");

pub const IpcCommand = dispatch.IpcCommand;
pub const ParseError = dispatch.ParseError;
pub const parseLine = dispatch.parseLine;
pub const PALETTE_NAME_MAX = dispatch.PALETTE_NAME_MAX;

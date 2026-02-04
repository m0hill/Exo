const builtin = @import("builtin");

const impl = if (builtin.os.tag == .windows)
    @import("terminal_windows.zig")
else
    @import("terminal_posix.zig");

pub const Size = @import("term_size.zig").Size;

pub const Options = impl.Options;
pub const Terminal = impl.Terminal;
pub const CrashRestoreState = impl.CrashRestoreState;
pub const restoreBestEffort = impl.restoreBestEffort;
pub const emergencyExit = impl.emergencyExit;

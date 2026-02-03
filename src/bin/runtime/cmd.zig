const std = @import("std");

pub fn parseCmdArgs(args: []const []const u8) ![]const []const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmd")) {
            if (i + 1 >= args.len) break;
            return args[i + 1 ..];
        }
    }
    std.debug.print("usage: tui_runtime --cmd <backend> [args...]\n", .{});
    return error.InvalidArgs;
}

pub const ResolvedCmd = struct {
    argv: []const []const u8,
    owned_argv: bool,
    owned_cmd0: bool,
};

pub fn resolveCmdArgv(allocator: std.mem.Allocator, cmd_argv: []const []const u8) !ResolvedCmd {
    if (cmd_argv.len == 0) return error.InvalidArgs;

    const cmd = cmd_argv[0];
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return .{ .argv = cmd_argv, .owned_argv = false, .owned_cmd0 = false };
    }

    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_path_buf);
    const self_dir = std.fs.path.dirname(self_path) orelse ".";
    const maybe_path = try std.fs.path.join(allocator, &.{ self_dir, cmd });
    errdefer allocator.free(maybe_path);

    if (std.fs.openFileAbsolute(maybe_path, .{})) |f| {
        f.close();
        var out = try allocator.alloc([]const u8, cmd_argv.len);
        out[0] = maybe_path;
        for (cmd_argv[1..], 1..) |arg, idx| out[idx] = arg;
        return .{ .argv = out, .owned_argv = true, .owned_cmd0 = true };
    } else |_| {
        allocator.free(maybe_path);
        return .{ .argv = cmd_argv, .owned_argv = false, .owned_cmd0 = false };
    }
}

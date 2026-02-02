const std = @import("std");

const jsonl = @import("jsonl.zig");
const protocol = @import("protocol.zig");
const render = @import("render.zig");
const terminal = @import("terminal.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd_argv = try parseCmdArgs(args);

    var term = terminal.Terminal.init() catch |e| {
        if (e == error.NotATty) {
            std.debug.print("tui_runtime: stdin and stdout must be a TTY (run interactively, not via a pipe)\n", .{});
            return;
        }
        return e;
    };
    defer term.deinit();

    const resolved = try resolveCmdArgv(allocator, cmd_argv);
    defer {
        if (resolved.owned_cmd0) allocator.free(resolved.argv[0]);
        if (resolved.owned_argv) allocator.free(resolved.argv);
    }

    var child = std.process.Child.init(resolved.argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    defer {
        _ = child.wait() catch {};
    }

    const child_in_file = child.stdin orelse return error.Unexpected;
    const child_out_file = child.stdout orelse return error.Unexpected;

    var child_in_buf: [4096]u8 = undefined;
    var child_in_w = child_in_file.writerStreaming(&child_in_buf);
    const child_in = &child_in_w.interface;

    var child_out_buf: [4096]u8 = undefined;
    var child_out_r = child_out_file.readerStreaming(&child_out_buf);
    var patch_lr = jsonl.LineReader.init(allocator, &child_out_r.interface, 1024 * 1024);
    defer patch_lr.deinit();

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = null;

    const backend_out_fd = child_out_file.handle;
    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = backend_out_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        _ = try std.posix.poll(fds[0..], -1);

        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            break;
        }

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            const n = patch_lr.readMore() catch |e| {
                if (e == error.LineTooLong) {
                    std.debug.print("PATCH_ERR reason=line_too_long\n", .{});
                    continue;
                }
                return e;
            };
            if (n == 0) break;
            std.debug.print("PATCH_RX bytes={d}\n", .{n});

            while (patch_lr.nextLine()) |line| {
                var next_arena = std.heap.ArenaAllocator.init(allocator);
                var accepted = false;
                defer if (!accepted) next_arena.deinit();

                // Copy line into arena so parsed strings reference owned memory
                const line_owned = try next_arena.allocator().dupe(u8, line);

                const msg = protocol.parseMsgLeaky(next_arena.allocator(), line_owned) catch |e| {
                    std.debug.print("PATCH_ERR reason={s}\n", .{@errorName(e)});
                    continue;
                };

                switch (msg) {
                    .patch => |p| {
                        current_arena.deinit();
                        current_arena = next_arena;
                        current_root = p.root;
                        accepted = true;
                        std.debug.print("PATCH_OK\n", .{});

                        const size = term.getSize() catch terminal.Size{ .rows = 0, .cols = 0 };
                        try render.render(&term, current_root.?);
                        std.debug.print("RENDER_OK rows={d} cols={d}\n", .{ size.rows, size.cols });
                    },
                    else => {},
                }
            }
        }

        if ((fds[1].revents & std.posix.POLL.IN) != 0) {
            const b = try term.readByte();
            const key = mapKey(b) orelse continue;

            std.debug.print("EVENT_TX key={s}\n", .{key});
            try protocol.writeEventJsonl(child_in, key);
            try child_in.flush();

            if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "ctrl-c")) {
                break;
            }
        }
    }
}

fn parseCmdArgs(args: []const []const u8) ![]const []const u8 {
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

const ResolvedCmd = struct {
    argv: []const []const u8,
    owned_argv: bool,
    owned_cmd0: bool,
};

fn resolveCmdArgv(allocator: std.mem.Allocator, cmd_argv: []const []const u8) !ResolvedCmd {
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

fn mapKey(b: u8) ?[]const u8 {
    return switch (b) {
        'q' => "q",
        'x' => "x",
        3 => "ctrl-c",
        else => null,
    };
}

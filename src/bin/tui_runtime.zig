const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;
const render = tui.render;
const terminal = tui.terminal;
const input = tui.input;
const tree = tui.tree;

const query_id = "query";
const results_id = "results";

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

    var focused_id: ?[]const u8 = null;
    var input_value: std.ArrayList(u8) = .empty;
    defer input_value.deinit(allocator);
    var input_cursor: usize = 0;

    var list_selected: std.ArrayList(u8) = .empty;
    defer list_selected.deinit(allocator);
    var list_scroll: usize = 0;

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
                    if (e == error.UnknownPatchMode) {
                        std.debug.print("PATCH_ERR reason=unknown_mode\n", .{});
                    } else {
                        std.debug.print("PATCH_ERR reason={s}\n", .{@errorName(e)});
                    }
                    continue;
                };

                switch (msg) {
                    .patch => |p| {
                        switch (p) {
                            .full => |f| {
                                current_arena.deinit();
                                current_arena = next_arena;
                                current_root = f.root;
                                accepted = true;
                                std.debug.print("PATCH_OK kind=full\n", .{});

                                if (focused_id == null and tree.treeContainsId(current_root.?, query_id)) {
                                    focused_id = query_id;
                                    std.debug.print("EVENT_TX name=focus id={s}\n", .{query_id});
                                    try protocol.writeFocusEventJsonl(child_in, query_id);
                                    try child_in.flush();
                                }
                                if (focused_id) |fid| {
                                    if (!tree.treeContainsId(current_root.?, fid)) {
                                        focused_id = null;
                                        std.debug.print("EVENT_TX name=focus id=\n", .{});
                                        try protocol.writeFocusEventJsonl(child_in, "");
                                        try child_in.flush();
                                    }
                                }

                                try syncListStateAfterPatch(
                                    allocator,
                                    child_in,
                                    &list_selected,
                                    &list_scroll,
                                    focused_id,
                                    current_root.?,
                                );
                                try child_in.flush();

                                try render.render(&term, current_root.?, .{
                                    .focused_id = focused_id,
                                    .input_id = query_id,
                                    .input_value = input_value.items,
                                    .input_cursor = input_cursor,
                                    .list_id = results_id,
                                    .list_selected_id = list_selected.items,
                                    .list_scroll = list_scroll,
                                });
                            },
                            .target => |t| {
                                if (current_root == null) {
                                    std.debug.print("PATCH_WARN kind=target id={s} found=false reason=no_root\n", .{t.target});
                                    continue;
                                }

                                const cloned = try cloneNodeLeaky(current_arena.allocator(), t.node);
                                var found: bool = false;
                                switch (t.mode) {
                                    .replace => {
                                        found = tree.applyPatchById(&current_root.?, t.target, cloned);
                                        std.debug.print(
                                            "PATCH_{s} kind=target mode=replace id={s} found={s}\n",
                                            .{ if (found) "OK" else "WARN", t.target, if (found) "true" else "false" },
                                        );
                                    },
                                    .morph => {
                                        var stats: tree.MorphStats = .{};
                                        found = tree.morphPatchByIdLeaky(
                                            current_arena.allocator(),
                                            &current_root.?,
                                            t.target,
                                            cloned,
                                            &stats,
                                        ) catch |e| {
                                            std.debug.print("PATCH_ERR reason={s}\n", .{@errorName(e)});
                                            continue;
                                        };

                                        std.debug.print(
                                            "PATCH_{s} kind=target mode=morph id={s} found={s} reused={d} inserted={d} removed={d}\n",
                                            .{
                                                if (found) "OK" else "WARN",
                                                t.target,
                                                if (found) "true" else "false",
                                                stats.reused,
                                                stats.inserted,
                                                stats.removed,
                                            },
                                        );
                                        if (stats.type_mismatch > 0) {
                                            std.debug.print(
                                                "MORPH_WARN type_mismatch replaced=true count={d}\n",
                                                .{stats.type_mismatch},
                                            );
                                        }
                                    },
                                }

                                if (!found) continue;

                                if (focused_id) |fid| {
                                    if (!tree.treeContainsId(current_root.?, fid)) {
                                        focused_id = null;
                                        std.debug.print("EVENT_TX name=focus id=\n", .{});
                                        try protocol.writeFocusEventJsonl(child_in, "");
                                        try child_in.flush();
                                    }
                                }

                                try syncListStateAfterPatch(
                                    allocator,
                                    child_in,
                                    &list_selected,
                                    &list_scroll,
                                    focused_id,
                                    current_root.?,
                                );
                                try child_in.flush();

                                try render.render(&term, current_root.?, .{
                                    .focused_id = focused_id,
                                    .input_id = query_id,
                                    .input_value = input_value.items,
                                    .input_cursor = input_cursor,
                                    .list_id = results_id,
                                    .list_selected_id = list_selected.items,
                                    .list_scroll = list_scroll,
                                });
                            },
                        }
                    },
                    else => {},
                }
            }
        }

        if ((fds[1].revents & std.posix.POLL.IN) != 0) {
            const b = try term.readByte();
            if (b == '\t' or (b == 0x1b and try readShiftTab(&term))) {
                focused_id = cycleFocus(focused_id);
                std.debug.print("EVENT_TX name=focus id={s}\n", .{focused_id orelse ""});
                try protocol.writeFocusEventJsonl(child_in, focused_id orelse "");

                if (current_root != null) {
                    try syncListStateAfterPatch(
                        allocator,
                        child_in,
                        &list_selected,
                        &list_scroll,
                        focused_id,
                        current_root.?,
                    );
                }
                try child_in.flush();

                if (current_root != null) {
                    try render.render(&term, current_root.?, .{
                        .focused_id = focused_id,
                        .input_id = query_id,
                        .input_value = input_value.items,
                        .input_cursor = input_cursor,
                        .list_id = results_id,
                        .list_selected_id = list_selected.items,
                        .list_scroll = list_scroll,
                    });
                }
                continue;
            }

            // Always allow exit keys.
            if (b == 3) {
                std.debug.print("EVENT_TX name=key key=ctrl-c\n", .{});
                try protocol.writeKeyEventJsonl(child_in, "ctrl-c");
                try child_in.flush();
                break;
            }
            if (b == 'x') {
                std.debug.print("EVENT_TX name=key key=x\n", .{});
                try protocol.writeKeyEventJsonl(child_in, "x");
                try child_in.flush();
                break;
            }

            if (b == 'q') {
                std.debug.print("EVENT_TX name=key key=q\n", .{});
                try protocol.writeKeyEventJsonl(child_in, "q");
                try child_in.flush();
                continue;
            }

            if (focused_id != null and std.mem.eql(u8, focused_id.?, results_id)) {
                if (b == 'j' or b == 'k') {
                    if (current_root != null) {
                        const delta: isize = if (b == 'j') 1 else -1;
                        const changed = try moveListSelection(
                            allocator,
                            child_in,
                            &list_selected,
                            &list_scroll,
                            current_root.?,
                            delta,
                        );
                        if (changed) try child_in.flush();

                        try render.render(&term, current_root.?, .{
                            .focused_id = focused_id,
                            .input_id = query_id,
                            .input_value = input_value.items,
                            .input_cursor = input_cursor,
                            .list_id = results_id,
                            .list_selected_id = list_selected.items,
                            .list_scroll = list_scroll,
                        });
                    }
                    continue;
                }

                if (b == '\r' or b == '\n') {
                    if (list_selected.items.len > 0) {
                        std.debug.print(
                            "EVENT_TX name=activate id={s} item={s}\n",
                            .{ results_id, list_selected.items },
                        );
                        try protocol.writeActivateEventJsonl(child_in, results_id, list_selected.items);
                        try child_in.flush();
                    }
                    continue;
                }
            }

            if (focused_id != null and std.mem.eql(u8, focused_id.?, query_id)) {
                const changed = input.handleInputByte(allocator, &input_value, &input_cursor, b) catch |e| blk: {
                    std.debug.print("INPUT_ERR reason={s}\n", .{@errorName(e)});
                    break :blk false;
                };
                if (!changed) continue;

                std.debug.print(
                    "EVENT_TX name=input id={s} len={d} cursor={d}\n",
                    .{ query_id, input_value.items.len, input_cursor },
                );
                try protocol.writeInputEventJsonl(child_in, query_id, input_value.items, input_cursor);
                try child_in.flush();

                if (current_root != null) {
                    try render.render(&term, current_root.?, .{
                        .focused_id = focused_id,
                        .input_id = query_id,
                        .input_value = input_value.items,
                        .input_cursor = input_cursor,
                        .list_id = results_id,
                        .list_selected_id = list_selected.items,
                        .list_scroll = list_scroll,
                    });
                }
                continue;
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

fn readShiftTab(term: *terminal.Terminal) !bool {
    // Common sequence: ESC [ Z
    const b2 = try readByteIfReady(term) orelse return false;
    if (b2 != '[') return false;
    const b3 = try readByteIfReady(term) orelse return false;
    return b3 == 'Z';
}

fn readByteIfReady(term: *terminal.Terminal) !?u8 {
    var fds = [_]std.posix.pollfd{
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const rc = try std.posix.poll(fds[0..], 0);
    if (rc == 0) return null;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) return null;
    return try term.readByte();
}

fn cloneNodeLeaky(allocator: std.mem.Allocator, node: protocol.Node) !protocol.Node {
    return switch (node) {
        .text => |t| .{ .text = .{
            .id = try allocator.dupe(u8, t.id),
            .text = try allocator.dupe(u8, t.text),
        } },
        .input => |i| .{ .input = .{
            .id = try allocator.dupe(u8, i.id),
            .placeholder = if (i.placeholder) |p| try allocator.dupe(u8, p) else null,
        } },
        .vbox => |v| blk: {
            var children = try allocator.alloc(protocol.Node, v.children.len);
            for (v.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .vbox = .{ .id = try allocator.dupe(u8, v.id), .children = children } };
        },
        .list => |l| blk: {
            var children = try allocator.alloc(protocol.Node, l.children.len);
            for (l.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .list = .{
                .id = try allocator.dupe(u8, l.id),
                .height = l.height,
                .children = children,
            } };
        },
    };
}

fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .text => |t| t.id,
        .input => |i| i.id,
        .list => |l| l.id,
    };
}

fn cycleFocus(current: ?[]const u8) ?[]const u8 {
    if (current == null) return query_id;
    if (std.mem.eql(u8, current.?, query_id)) return results_id;
    if (std.mem.eql(u8, current.?, results_id)) return null;
    return query_id;
}

const ListInfo = struct {
    height: usize,
    children: []const protocol.Node,
};

fn findList(root: protocol.Node, id: []const u8) ?ListInfo {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .list => |l| .{
                .height = l.height orelse 0,
                .children = l.children,
            },
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findList(child, id)) |info| break :blk info;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findList(child, id)) |info| break :blk info;
            }
            break :blk null;
        },
        else => null,
    };
}

fn syncListStateAfterPatch(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    list_selected: *std.ArrayList(u8),
    list_scroll: *usize,
    focused_id: ?[]const u8,
    root: protocol.Node,
) !void {
    const info = findList(root, results_id) orelse return;
    if (info.children.len == 0) {
        list_selected.clearRetainingCapacity();
        list_scroll.* = 0;
        return;
    }

    var selected_index: ?usize = null;
    if (list_selected.items.len > 0) {
        for (info.children, 0..) |child, idx| {
            if (std.mem.eql(u8, nodeId(child), list_selected.items)) {
                selected_index = idx;
                break;
            }
        }
    }

    var selection_changed = false;
    if (selected_index == null) {
        const new_id = nodeId(info.children[0]);
        list_selected.clearRetainingCapacity();
        try list_selected.appendSlice(allocator, new_id);
        selected_index = 0;
        selection_changed = true;
    }

    const height = if (info.height == 0) info.children.len else info.height;
    const idx = selected_index.?;
    if (idx < list_scroll.*) list_scroll.* = idx;
    if (idx >= list_scroll.* + height) list_scroll.* = idx - height + 1;

    const is_focused = focused_id != null and std.mem.eql(u8, focused_id.?, results_id);
    if (selection_changed or is_focused) {
        std.debug.print(
            "LIST_SELECT item={s} index={d} scroll={d}\n",
            .{ list_selected.items, idx, list_scroll.* },
        );
    }
    if (selection_changed) {
        std.debug.print(
            "EVENT_TX name=select id={s} item={s}\n",
            .{ results_id, list_selected.items },
        );
        try protocol.writeSelectEventJsonl(backend_in, results_id, list_selected.items);
    }
}

fn moveListSelection(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    list_selected: *std.ArrayList(u8),
    list_scroll: *usize,
    root: protocol.Node,
    delta: isize,
) !bool {
    const info = findList(root, results_id) orelse return false;
    if (info.children.len == 0) return false;

    var current_idx: usize = 0;
    if (list_selected.items.len > 0) {
        for (info.children, 0..) |child, idx| {
            if (std.mem.eql(u8, nodeId(child), list_selected.items)) {
                current_idx = idx;
                break;
            }
        }
    }

    const len: isize = @as(isize, @intCast(info.children.len));
    const next_idx_signed = @min(@max(@as(isize, @intCast(current_idx)) + delta, 0), len - 1);
    const next_idx: usize = @as(usize, @intCast(next_idx_signed));
    const next_id = nodeId(info.children[next_idx]);
    if (list_selected.items.len > 0 and std.mem.eql(u8, list_selected.items, next_id)) return false;

    list_selected.clearRetainingCapacity();
    try list_selected.appendSlice(allocator, next_id);

    const height = if (info.height == 0) info.children.len else info.height;
    if (next_idx < list_scroll.*) list_scroll.* = next_idx;
    if (next_idx >= list_scroll.* + height) list_scroll.* = next_idx - height + 1;

    std.debug.print("LIST_SELECT item={s} index={d} scroll={d}\n", .{ next_id, next_idx, list_scroll.* });
    std.debug.print("EVENT_TX name=select id={s} item={s}\n", .{ results_id, next_id });
    try protocol.writeSelectEventJsonl(backend_in, results_id, next_id);
    return true;
}

const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;
const render = tui.render;
const terminal = tui.terminal;
const input = tui.input;
const tree = tui.tree;

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
    var auto_focus_done: bool = false;
    var widgets: std.ArrayList(WidgetEntry) = .empty;
    defer deinitWidgetEntries(allocator, &widgets);
    var render_inputs: std.ArrayList(render.InputState) = .empty;
    defer render_inputs.deinit(allocator);
    var render_lists: std.ArrayList(render.ListState) = .empty;
    defer render_lists.deinit(allocator);

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

                                try syncUiAfterPatch(allocator, child_in, &widgets, &focused_id, &auto_focus_done, current_root.?);
                                try child_in.flush();

                                const rs = try buildRenderState(allocator, widgets.items, &render_inputs, &render_lists, focused_id);
                                try render.render(&term, current_root.?, rs);
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

                                try syncUiAfterPatch(allocator, child_in, &widgets, &focused_id, &auto_focus_done, current_root.?);
                                try child_in.flush();

                                const rs = try buildRenderState(allocator, widgets.items, &render_inputs, &render_lists, focused_id);
                                try render.render(&term, current_root.?, rs);
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
                if (current_root != null) {
                    focused_id = try cycleFocusInTree(allocator, current_root.?, focused_id);
                } else {
                    focused_id = null;
                }
                std.debug.print("EVENT_TX name=focus id={s}\n", .{focused_id orelse ""});
                try protocol.writeFocusEventJsonl(child_in, focused_id orelse "");

                if (current_root != null) {
                    try syncUiAfterPatch(allocator, child_in, &widgets, &focused_id, &auto_focus_done, current_root.?);
                    const rs = try buildRenderState(allocator, widgets.items, &render_inputs, &render_lists, focused_id);
                    try render.render(&term, current_root.?, rs);
                }
                try child_in.flush();
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

            if (current_root == null or focused_id == null) continue;
            const fk = try focusedKindInTree(allocator, current_root.?, focused_id.?);
            if (fk == null) continue;

            switch (fk.?) {
                .list => {
                    if (b == 'j' or b == 'k') {
                        const delta: isize = if (b == 'j') 1 else -1;
                        const changed = try moveListSelectionForId(
                            allocator,
                            child_in,
                            &widgets,
                            current_root.?,
                            focused_id.?,
                            delta,
                        );
                        if (changed) {
                            try child_in.flush();
                            const rs = try buildRenderState(allocator, widgets.items, &render_inputs, &render_lists, focused_id);
                            try render.render(&term, current_root.?, rs);
                        }
                        continue;
                    }

                    if (b == '\r' or b == '\n') {
                        try activateListForId(child_in, widgets.items, focused_id.?);
                        try child_in.flush();
                        continue;
                    }
                },
                .input => {
                    const changed = handleFocusedInputByte(allocator, &widgets, focused_id.?, b) catch |e| blk: {
                        std.debug.print("INPUT_ERR reason={s}\n", .{@errorName(e)});
                        break :blk false;
                    };
                    if (!changed) continue;
                    try emitInputEventForId(child_in, widgets.items, focused_id.?);
                    try child_in.flush();

                    const rs = try buildRenderState(allocator, widgets.items, &render_inputs, &render_lists, focused_id);
                    try render.render(&term, current_root.?, rs);
                    continue;
                },
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

const FocusKind = enum {
    input,
    list,
};

const Focusable = struct {
    id: []const u8,
    kind: FocusKind,
};

const InputWidgetState = struct {
    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
};

const ListWidgetState = struct {
    selected_id: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
};

const WidgetState = union(enum) {
    input: InputWidgetState,
    list: ListWidgetState,
};

const WidgetEntry = struct {
    id: std.ArrayList(u8) = .empty,
    state: WidgetState,
};

fn deinitWidgetEntries(allocator: std.mem.Allocator, widgets: *std.ArrayList(WidgetEntry)) void {
    for (widgets.items) |*e| {
        e.id.deinit(allocator);
        switch (e.state) {
            .input => |*s| s.value.deinit(allocator),
            .list => |*s| s.selected_id.deinit(allocator),
        }
    }
    widgets.deinit(allocator);
}

fn buildRenderState(
    allocator: std.mem.Allocator,
    widgets: []const WidgetEntry,
    render_inputs: *std.ArrayList(render.InputState),
    render_lists: *std.ArrayList(render.ListState),
    focused_id: ?[]const u8,
) !render.RenderState {
    render_inputs.clearRetainingCapacity();
    render_lists.clearRetainingCapacity();

    for (widgets) |e| {
        switch (e.state) {
            .input => |s| {
                try render_inputs.append(allocator, .{
                    .id = e.id.items,
                    .value = s.value.items,
                    .cursor = s.cursor,
                });
            },
            .list => |s| {
                try render_lists.append(allocator, .{
                    .id = e.id.items,
                    .selected_id = s.selected_id.items,
                    .scroll = s.scroll,
                });
            },
        }
    }

    return .{
        .focused_id = focused_id,
        .inputs = render_inputs.items,
        .lists = render_lists.items,
    };
}

fn collectFocusables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList(Focusable) {
    var out: std.ArrayList(Focusable) = .empty;
    errdefer out.deinit(allocator);
    try collectFocusablesInto(allocator, &out, root);
    return out;
}

fn collectFocusablesInto(allocator: std.mem.Allocator, out: *std.ArrayList(Focusable), node: protocol.Node) !void {
    switch (node) {
        .input => |i| {
            try out.append(allocator, .{ .id = i.id, .kind = .input });
        },
        .list => |l| {
            try out.append(allocator, .{ .id = l.id, .kind = .list });
            for (l.children) |child| try collectFocusablesInto(allocator, out, child);
        },
        .vbox => |v| {
            for (v.children) |child| try collectFocusablesInto(allocator, out, child);
        },
        .text => {},
    }
}

fn cycleFocusInTree(allocator: std.mem.Allocator, root: protocol.Node, current: ?[]const u8) !?[]const u8 {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    if (focusables.items.len == 0) return null;
    if (current == null) return focusables.items[0].id;

    var current_idx: ?usize = null;
    for (focusables.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f.id, current.?)) {
            current_idx = idx;
            break;
        }
    }

    if (current_idx == null) return focusables.items[0].id;
    const idx = current_idx.?;
    if (idx + 1 < focusables.items.len) return focusables.items[idx + 1].id;
    return null;
}

fn focusedKindInTree(allocator: std.mem.Allocator, root: protocol.Node, id: []const u8) !?FocusKind {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);
    for (focusables.items) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.kind;
    }
    return null;
}

fn syncUiAfterPatch(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id: *?[]const u8,
    auto_focus_done: *bool,
    root: protocol.Node,
) !void {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    pruneWidgetsNotInFocusables(allocator, widgets, focusables.items);
    try ensureWidgetsForFocusables(allocator, widgets, focusables.items);

    if (focused_id.* == null) {
        if (!auto_focus_done.* and focusables.items.len > 0) {
            focused_id.* = focusables.items[0].id;
            auto_focus_done.* = true;
            std.debug.print("EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
            try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
        }
    } else {
        if (!focusablesContainsId(focusables.items, focused_id.*.?)) {
            focused_id.* = if (focusables.items.len > 0) focusables.items[0].id else null;
            std.debug.print("EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
            try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
        }
    }

    for (focusables.items) |f| {
        if (f.kind != .list) continue;
        try syncListForId(allocator, backend_in, widgets, root, f.id);
    }
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn pruneWidgetsNotInFocusables(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    focusables: []const Focusable,
) void {
    var i: usize = widgets.items.len;
    while (i > 0) {
        i -= 1;
        const id = widgets.items[i].id.items;
        if (focusablesContainsId(focusables, id)) continue;
        deinitWidgetEntry(allocator, &widgets.items[i]);
        _ = widgets.swapRemove(i);
    }
}

fn deinitWidgetEntry(allocator: std.mem.Allocator, e: *WidgetEntry) void {
    e.id.deinit(allocator);
    switch (e.state) {
        .input => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
    }
}

fn focusablesContainsId(focusables: []const Focusable, id: []const u8) bool {
    for (focusables) |f| {
        if (std.mem.eql(u8, f.id, id)) return true;
    }
    return false;
}

fn ensureWidgetsForFocusables(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    focusables: []const Focusable,
) !void {
    for (focusables) |f| {
        _ = try ensureWidgetKind(allocator, widgets, f.id, f.kind);
    }
}

fn ensureWidgetKind(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    id: []const u8,
    kind: FocusKind,
) !usize {
    if (findWidgetIndex(widgets.items, id)) |idx| {
        switch (widgets.items[idx].state) {
            .input => if (kind == .input) return idx else {},
            .list => if (kind == .list) return idx else {},
        }
        // Type changed: reset state.
        deinitWidgetEntryState(allocator, &widgets.items[idx]);
        widgets.items[idx].state = initWidgetState(kind);
        return idx;
    }

    var id_buf: std.ArrayList(u8) = .empty;
    errdefer id_buf.deinit(allocator);
    try id_buf.appendSlice(allocator, id);
    try widgets.append(allocator, .{ .id = id_buf, .state = initWidgetState(kind) });
    return widgets.items.len - 1;
}

fn deinitWidgetEntryState(allocator: std.mem.Allocator, e: *WidgetEntry) void {
    switch (e.state) {
        .input => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
    }
}

fn initWidgetState(kind: FocusKind) WidgetState {
    return switch (kind) {
        .input => .{ .input = .{} },
        .list => .{ .list = .{} },
    };
}

fn findWidgetIndex(widgets: []const WidgetEntry, id: []const u8) ?usize {
    for (widgets, 0..) |e, idx| {
        if (std.mem.eql(u8, e.id.items, id)) return idx;
    }
    return null;
}

fn findListNodeById(root: protocol.Node, id: []const u8) ?protocol.ListNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .list => |l| l,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findListNodeById(child, id)) |ll| break :blk ll;
            }
            break :blk null;
        },
        else => null,
    };
}

fn syncListForId(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
) !void {
    const l = findListNodeById(root, list_id) orelse return;
    if (l.children.len == 0) {
        if (findWidgetIndex(widgets.items, list_id)) |idx| {
            const st = &widgets.items[idx].state.list;
            st.selected_id.clearRetainingCapacity();
            st.scroll = 0;
        }
        return;
    }

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var selected_index: ?usize = null;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    var selection_changed = false;
    if (selected_index == null) {
        const new_id = nodeId(l.children[0]);
        st.selected_id.clearRetainingCapacity();
        try st.selected_id.appendSlice(allocator, new_id);
        selected_index = 0;
        selection_changed = true;
    }

    const height = l.height orelse l.children.len;
    const effective_height = if (height == 0) l.children.len else height;

    const sel_idx = selected_index.?;
    const max_scroll = if (l.children.len > effective_height) l.children.len - effective_height else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;
    if (sel_idx < st.scroll) st.scroll = sel_idx;
    if (sel_idx >= st.scroll + effective_height) st.scroll = sel_idx - effective_height + 1;

    std.debug.print(
        "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
        .{ list_id, st.selected_id.items, sel_idx, st.scroll },
    );
    if (selection_changed) {
        std.debug.print("EVENT_TX name=select id={s} item={s}\n", .{ list_id, st.selected_id.items });
        try protocol.writeSelectEventJsonl(backend_in, list_id, st.selected_id.items);
    }
}

fn moveListSelectionForId(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
    delta: isize,
) !bool {
    const l = findListNodeById(root, list_id) orelse return false;
    if (l.children.len == 0) return false;

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var current_idx: usize = 0;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                current_idx = child_idx;
                break;
            }
        }
    }

    const len: isize = @as(isize, @intCast(l.children.len));
    const next_idx_signed = @min(@max(@as(isize, @intCast(current_idx)) + delta, 0), len - 1);
    const next_idx: usize = @as(usize, @intCast(next_idx_signed));
    const next_id = nodeId(l.children[next_idx]);
    if (st.selected_id.items.len > 0 and std.mem.eql(u8, st.selected_id.items, next_id)) return false;

    st.selected_id.clearRetainingCapacity();
    try st.selected_id.appendSlice(allocator, next_id);

    const height = l.height orelse l.children.len;
    const effective_height = if (height == 0) l.children.len else height;
    const max_scroll = if (l.children.len > effective_height) l.children.len - effective_height else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;
    if (next_idx < st.scroll) st.scroll = next_idx;
    if (next_idx >= st.scroll + effective_height) st.scroll = next_idx - effective_height + 1;

    std.debug.print(
        "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
        .{ list_id, next_id, next_idx, st.scroll },
    );
    std.debug.print("EVENT_TX name=select id={s} item={s}\n", .{ list_id, next_id });
    try protocol.writeSelectEventJsonl(backend_in, list_id, next_id);
    return true;
}

fn activateListForId(backend_in: anytype, widgets: []const WidgetEntry, list_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, list_id) orelse return;
    const st = widgets[idx].state.list;
    if (st.selected_id.items.len == 0) return;
    std.debug.print("EVENT_TX name=activate id={s} item={s}\n", .{ list_id, st.selected_id.items });
    try protocol.writeActivateEventJsonl(backend_in, list_id, st.selected_id.items);
}

fn handleFocusedInputByte(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    input_id: []const u8,
    b: u8,
) !bool {
    const idx = try ensureWidgetKind(allocator, widgets, input_id, .input);
    var st = &widgets.items[idx].state.input;
    return try input.handleInputByte(allocator, &st.value, &st.cursor, b);
}

fn emitInputEventForId(backend_in: anytype, widgets: []const WidgetEntry, input_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, input_id) orelse return;
    const st = widgets[idx].state.input;
    std.debug.print(
        "EVENT_TX name=input id={s} len={d} cursor={d}\n",
        .{ input_id, st.value.items.len, st.cursor },
    );
    try protocol.writeInputEventJsonl(backend_in, input_id, st.value.items, st.cursor);
}

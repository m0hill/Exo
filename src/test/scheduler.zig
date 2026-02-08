const prelude = @import("prelude.zig");
const std = prelude.std;
const tui = prelude.tui;
const protocol = prelude.protocol;
const Frame = prelude.Frame;
const render = prelude.render;
const renderer_mod = prelude.renderer_mod;
const testing_terminal = prelude.testing_terminal;
const input = prelude.input;
const unicode = prelude.unicode;
const state = prelude.state;
const tree = prelude.tree;
const scheduler_mod = prelude.scheduler_mod;
const mouse = prelude.mouse;
const style = prelude.style;
const markdown = prelude.markdown;
const hover = prelude.hover;
const keys = prelude.keys;
const kd = prelude.kd;
const termcaps = prelude.termcaps;
const clipboard = prelude.clipboard;
const runtime_ui = prelude.runtime_ui;
const pointer = prelude.pointer;

const cellByte = prelude.cellByte;
const cellText = prelude.cellText;
const keyEventMatchesNamed = prelude.keyEventMatchesNamed;

test "scheduler: target patch preserves style fields" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 32);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var root_children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .text = "old" } },
    };
    var current_root: ?protocol.Node = .{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    var next_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer next_arena.deinit();

    const red: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const patched: protocol.Node = .{ .text = .{ .id = "t", .h = 1, .style = red, .text = "new" } };

    _ = try sched.putTargetLeaky(&next_arena, "t", patched, .replace);
    _ = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);

    const root = current_root orelse return error.TestUnexpectedResult;
    const child = root.vbox.children[0].text;
    try std.testing.expectEqualStrings("new", child.text);
    try std.testing.expect(child.style != null);
    const st = child.style.?;
    try std.testing.expect(st.fg == .rgb);
}

test "scheduler: coalesces targets (latest wins)" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 8);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };
    var current_root: ?protocol.Node = root;

    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: 1" } }, .replace);
    }
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: 2" } }, .replace);
    }

    const c = sched.counts();
    try std.testing.expectEqual(@as(usize, 1), c.pending_targets);
    try std.testing.expectEqual(@as(u64, 1), c.coalesced_targets);

    const res = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);
    try std.testing.expectEqual(@as(usize, 1), res.targets_applied);
    try std.testing.expectEqual(@as(usize, 1), res.targets_found);

    const v = current_root.?.vbox;
    try std.testing.expectEqualStrings("Tick: 2", v.children[0].text.text);
}

test "scheduler: full patch supersedes earlier targets and flush applies full then targets" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 8);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var old_children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: old" } },
    };
    var current_root: ?protocol.Node = .{ .vbox = .{ .id = "root", .children = old_children[0..] } };

    // Target patch that should be dropped by the full snapshot.
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: stale" } }, .replace);
    }

    // Full snapshot replaces root.
    var full_children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: full" } },
    };
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        try sched.putFullLeakyWithSeq(&a, .{ .vbox = .{ .id = "root", .children = full_children[0..] } }, 10);
    }

    const after_full = sched.counts();
    try std.testing.expect(after_full.pending_full);
    try std.testing.expectEqual(@as(usize, 0), after_full.pending_targets);

    // Target patch after full should win.
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeakyWithSeq(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: after" } }, .replace, 11);
    }

    const res = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);
    try std.testing.expect(res.full_applied);
    try std.testing.expectEqual(@as(usize, 1), res.targets_applied);
    try std.testing.expectEqual(@as(usize, 2), res.applied_seqs.len);
    try std.testing.expectEqual(@as(u64, 10), res.applied_seqs[0]);
    try std.testing.expectEqual(@as(u64, 11), res.applied_seqs[1]);

    const v = current_root.?.vbox;
    try std.testing.expectEqualStrings("Tick: after", v.children[0].text.text);
}

test "scheduler: target seq is tracked when target id is not found" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 8);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
    };
    var current_root: ?protocol.Node = .{ .vbox = .{ .id = "root", .children = children[0..] } };

    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeakyWithSeq(&a, "missing", .{ .text = .{ .id = "missing", .text = "Tick: 1" } }, .replace, 22);
    }

    const res = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);
    try std.testing.expectEqual(@as(usize, 1), res.targets_not_found);
    try std.testing.expectEqual(@as(usize, 1), res.not_found_seqs.len);
    try std.testing.expectEqual(@as(u64, 22), res.not_found_seqs[0]);
}

test "scheduler: tracks max applied seq and supports drop_oldest overflow" {
    var sched = scheduler_mod.Scheduler.initWithOptions(std.testing.allocator, .{
        .max_pending_targets = 2,
        .overflow_policy = .drop_oldest,
    });
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .text = "A" } },
        .{ .text = .{ .id = "b", .text = "B" } },
        .{ .text = .{ .id = "c", .text = "C" } },
    };
    var current_root: ?protocol.Node = .{ .vbox = .{ .id = "root", .children = children[0..] } };

    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeakyWithSeq(&a, "a", .{ .text = .{ .id = "a", .text = "A1" } }, .replace, 1);
    }
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeakyWithSeq(&a, "b", .{ .text = .{ .id = "b", .text = "B2" } }, .replace, 2);
    }
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeakyWithSeq(&a, "c", .{ .text = .{ .id = "c", .text = "C3" } }, .replace, 3);
    }

    const res = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);
    try std.testing.expectEqual(@as(?u64, 3), res.max_seq_applied);
    try std.testing.expect(res.dropped_targets >= 1);
}

test "scheduler: dropped overflow emits dropped_overflow ack payload" {
    var sched = scheduler_mod.Scheduler.initWithOptions(std.testing.allocator, .{
        .max_pending_targets = 1,
        .overflow_policy = .drop_newest,
    });
    defer sched.deinit();

    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeakyWithSeq(&a, "a", .{ .text = .{ .id = "a", .text = "A1" } }, .replace, 1);
    }
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        const put_res = try sched.putTargetLeakyWithSeq(&a, "b", .{ .text = .{ .id = "b", .text = "B2" } }, .replace, 2);
        try std.testing.expectEqual(scheduler_mod.PutResult.dropped_overflow, put_res);
    }

    try std.testing.expectEqual(@as(u64, 1), sched.counts().dropped_targets);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try protocol.writeAckEventJsonl(out.writer(std.testing.allocator), 2, "dropped_overflow", "queue_overflow");

    const ack_msg = try protocol.parseMsgLeaky(arena.allocator(), out.items);
    switch (ack_msg) {
        .event => |ev| switch (ev) {
            .ack => |ack| {
                try std.testing.expectEqual(@as(u64, 2), ack.seq);
                try std.testing.expectEqual(protocol.AckStatus.dropped_overflow, ack.status);
                try std.testing.expectEqualStrings("queue_overflow", ack.detail orelse return error.TestUnexpectedResult);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

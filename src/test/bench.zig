const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const renderer_mod = tui.renderer;
const scheduler_mod = tui.scheduler;
const markdown = tui.markdown;
const testing_terminal = @import("testing_terminal.zig");

const BenchRow = struct {
    name: []const u8,
    target_ms: f64,
    iters: usize,
    total_ns: u64,

    fn avgMs(self: BenchRow) f64 {
        if (self.iters == 0) return 0;
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iters)) / @as(f64, std.time.ns_per_ms);
    }

    fn fps(self: BenchRow) f64 {
        const avg_ms = self.avgMs();
        if (avg_ms <= 0.0) return 0;
        return 1000.0 / avg_ms;
    }

    fn meetsTarget(self: BenchRow) bool {
        return self.avgMs() <= self.target_ms;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const iters = parseIterationsArg(args[1..]) orelse 120;
    const warmup = @max(@as(usize, 4), iters / 10);

    var rows: [5]BenchRow = undefined;
    rows[0] = try benchFullTreePatch30Fps(allocator, iters, warmup);
    rows[1] = try benchSmallTargetPatches(allocator, iters, warmup);
    rows[2] = try benchHugeListTargetPatches(allocator, iters, warmup);
    rows[3] = try benchHeavyMarkdown(allocator, iters, warmup);
    rows[4] = try benchLargePatchParse(allocator, iters, warmup);

    std.debug.print("bench workloads={d} iters={d} warmup={d}\n", .{ rows.len, iters, warmup });
    for (rows) |r| {
        std.debug.print(
            "BENCH name={s} avg_ms={d:.3} target_ms={d:.3} fps={d:.1} status={s}\n",
            .{
                r.name,
                r.avgMs(),
                r.target_ms,
                r.fps(),
                if (r.meetsTarget()) "ok" else "regression",
            },
        );
    }
}

fn parseIterationsArg(args: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--iters")) continue;
        if (i + 1 >= args.len) return null;
        return std.fmt.parseUnsigned(usize, args[i + 1], 10) catch null;
    }
    return null;
}

fn allocIds(allocator: std.mem.Allocator, comptime prefix: []const u8, n: usize) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, n);
    errdefer allocator.free(out);
    for (out, 0..) |*slot, idx| {
        slot.* = try std.fmt.allocPrint(allocator, "{s}{d}", .{ prefix, idx });
    }
    return out;
}

fn freeIds(allocator: std.mem.Allocator, ids: []const []const u8) void {
    for (ids) |id| allocator.free(id);
    allocator.free(ids);
}

fn buildFullTreeLeaky(allocator: std.mem.Allocator, ids: []const []const u8, tick: usize) !protocol.Node {
    const children = try allocator.alloc(protocol.Node, ids.len);
    for (ids, 0..) |id, idx| {
        if (idx == 0) {
            const line = try std.fmt.allocPrint(allocator, "tick={d}", .{tick});
            children[idx] = .{ .text = .{ .id = id, .text = line } };
        } else {
            children[idx] = .{ .text = .{ .id = id, .text = "xxxxxxxxxxxxxxxxxxxxxxxx" } };
        }
    }

    return .{ .vbox = .{
        .id = "root",
        .gap = 0,
        .children = children,
    } };
}

fn buildHugeListRootLeaky(allocator: std.mem.Allocator, ids: []const []const u8) !protocol.Node {
    const items = try allocator.alloc(protocol.Node, ids.len);
    for (ids, 0..) |id, idx| {
        const line = try std.fmt.allocPrint(allocator, "row {d}", .{idx});
        items[idx] = .{ .text = .{ .id = id, .text = line } };
    }

    const list_node: protocol.Node = .{ .list = .{
        .id = "huge-list",
        .height = 20,
        .children = items,
    } };
    const outer_children = try allocator.alloc(protocol.Node, 1);
    outer_children[0] = list_node;

    return .{ .vbox = .{
        .id = "root",
        .children = outer_children,
    } };
}

fn benchFullTreePatch30Fps(allocator: std.mem.Allocator, iters: usize, warmup: usize) !BenchRow {
    const ids = try allocIds(allocator, "full-", 420);
    defer freeIds(allocator, ids);

    var term = testing_terminal.Terminal.init(allocator, .{ .rows = 36, .cols = 120 });
    defer term.deinit();
    var renderer = renderer_mod.Renderer.init(allocator);
    defer renderer.deinit();
    var sched = scheduler_mod.Scheduler.init(allocator, 512);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = null;

    var iter: usize = 0;
    while (iter < warmup) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = try buildFullTreeLeaky(arena.allocator(), ids, iter);
        try sched.putFullLeaky(&arena, root);
        _ = try sched.flushApplyLeaky(allocator, &current_arena, &current_root);
        term.reset();
        try renderer.draw(&term, current_root.?, .{});
    }

    var timer = try std.time.Timer.start();
    iter = 0;
    while (iter < iters) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = try buildFullTreeLeaky(arena.allocator(), ids, warmup + iter);
        try sched.putFullLeaky(&arena, root);
        _ = try sched.flushApplyLeaky(allocator, &current_arena, &current_root);
        term.reset();
        try renderer.draw(&term, current_root.?, .{});
    }

    return .{
        .name = "full_tree_patch_30fps",
        .target_ms = 33.0,
        .iters = iters,
        .total_ns = timer.read(),
    };
}

fn benchSmallTargetPatches(allocator: std.mem.Allocator, iters: usize, warmup: usize) !BenchRow {
    const ids = try allocIds(allocator, "row-", 1800);
    defer freeIds(allocator, ids);

    var term = testing_terminal.Terminal.init(allocator, .{ .rows = 40, .cols = 120 });
    defer term.deinit();
    var renderer = renderer_mod.Renderer.init(allocator);
    defer renderer.deinit();
    var sched = scheduler_mod.Scheduler.init(allocator, 512);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = try buildFullTreeLeaky(current_arena.allocator(), ids, 0);

    const target_id = ids[ids.len / 2];

    var iter: usize = 0;
    while (iter < warmup) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const text = try std.fmt.allocPrint(arena.allocator(), "hot={d}", .{iter});
        const node: protocol.Node = .{ .text = .{ .id = target_id, .text = text } };
        _ = try sched.putTargetLeaky(&arena, target_id, node, .replace);
        _ = try sched.flushApplyLeaky(allocator, &current_arena, &current_root);
        term.reset();
        try renderer.draw(&term, current_root.?, .{});
    }

    var timer = try std.time.Timer.start();
    iter = 0;
    while (iter < iters) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const text = try std.fmt.allocPrint(arena.allocator(), "hot={d}", .{warmup + iter});
        const node: protocol.Node = .{ .text = .{ .id = target_id, .text = text } };
        _ = try sched.putTargetLeaky(&arena, target_id, node, .replace);
        _ = try sched.flushApplyLeaky(allocator, &current_arena, &current_root);
        term.reset();
        try renderer.draw(&term, current_root.?, .{});
    }

    return .{
        .name = "small_target_patch",
        .target_ms = 4.0,
        .iters = iters,
        .total_ns = timer.read(),
    };
}

fn benchHugeListTargetPatches(allocator: std.mem.Allocator, iters: usize, warmup: usize) !BenchRow {
    const ids = try allocIds(allocator, "item-", 5000);
    defer freeIds(allocator, ids);

    var term = testing_terminal.Terminal.init(allocator, .{ .rows = 30, .cols = 100 });
    defer term.deinit();
    var renderer = renderer_mod.Renderer.init(allocator);
    defer renderer.deinit();
    var sched = scheduler_mod.Scheduler.init(allocator, 1024);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = try buildHugeListRootLeaky(current_arena.allocator(), ids);

    var iter: usize = 0;
    while (iter < warmup) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const idx = iter % 48;
        const line = try std.fmt.allocPrint(arena.allocator(), "hot row {d}", .{iter});
        const node: protocol.Node = .{ .text = .{ .id = ids[idx], .text = line } };
        _ = try sched.putTargetLeaky(&arena, ids[idx], node, .replace);
        _ = try sched.flushApplyLeaky(allocator, &current_arena, &current_root);
        term.reset();
        try renderer.draw(&term, current_root.?, .{});
    }

    var timer = try std.time.Timer.start();
    iter = 0;
    while (iter < iters) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const idx = iter % 48;
        const line = try std.fmt.allocPrint(arena.allocator(), "hot row {d}", .{warmup + iter});
        const node: protocol.Node = .{ .text = .{ .id = ids[idx], .text = line } };
        _ = try sched.putTargetLeaky(&arena, ids[idx], node, .replace);
        _ = try sched.flushApplyLeaky(allocator, &current_arena, &current_root);
        term.reset();
        try renderer.draw(&term, current_root.?, .{});
    }

    return .{
        .name = "huge_list_target_patch",
        .target_ms = 8.0,
        .iters = iters,
        .total_ns = timer.read(),
    };
}

fn buildMarkdownPayload(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < 220) : (i += 1) {
        try buf.writer(allocator).print(
            "## Heading {d}\n- item {d}\n- item {d}\n`inline code` with **bold** and _italic_ text\n\n",
            .{ i, i, i + 1 },
        );
    }

    return try buf.toOwnedSlice(allocator);
}

fn benchHeavyMarkdown(allocator: std.mem.Allocator, iters: usize, warmup: usize) !BenchRow {
    const md = try buildMarkdownPayload(allocator);
    defer allocator.free(md);

    var term = testing_terminal.Terminal.init(allocator, .{ .rows = 42, .cols = 120 });
    defer term.deinit();
    var renderer = renderer_mod.Renderer.init(allocator);
    defer renderer.deinit();

    var iter: usize = 0;
    while (iter < warmup) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = try markdown.compileLeaky(arena.allocator(), md, .{});
        term.reset();
        try renderer.draw(&term, root, .{});
    }

    var timer = try std.time.Timer.start();
    iter = 0;
    while (iter < iters) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = try markdown.compileLeaky(arena.allocator(), md, .{});
        term.reset();
        try renderer.draw(&term, root, .{});
    }

    return .{
        .name = "heavy_markdown",
        .target_ms = 20.0,
        .iters = iters,
        .total_ns = timer.read(),
    };
}

fn buildLargePatchJson(allocator: std.mem.Allocator, node_count: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"type\":\"patch\",\"root\":{\"type\":\"vbox\",\"id\":\"root\",\"children\":[");
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        if (i != 0) try buf.append(allocator, ',');
        try buf.writer(allocator).print(
            "{{\"type\":\"text\",\"id\":\"n{d}\",\"text\":\"row {d}\"}}",
            .{ i, i },
        );
    }
    try buf.appendSlice(allocator, "]}}\n");

    return try buf.toOwnedSlice(allocator);
}

fn benchLargePatchParse(allocator: std.mem.Allocator, iters: usize, warmup: usize) !BenchRow {
    const line = try buildLargePatchJson(allocator, 900);
    defer allocator.free(line);

    var iter: usize = 0;
    while (iter < warmup) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try protocol.parseMsgLeaky(arena.allocator(), line);
    }

    var timer = try std.time.Timer.start();
    iter = 0;
    while (iter < iters) : (iter += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try protocol.parseMsgLeaky(arena.allocator(), line);
    }

    return .{
        .name = "protocol_parse_large_patch",
        .target_ms = 6.0,
        .iters = iters,
        .total_ns = timer.read(),
    };
}

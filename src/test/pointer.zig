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

test "pointer: click count + capture + leave" {
    var engine: pointer.PointerEngine = .{};
    defer engine.deinit(std.testing.allocator);

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .h = 1, .mouseable = true, .text = "hi" } },
        .{ .text = .{ .id = "u", .h = 1, .text = "pad" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };
    const widgets = [_]pointer.widgets.WidgetEntry{};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Hover over the target so leave can be observed later.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .move, .x = 0, .y = 0 },
        0,
    );

    // Click down.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .down, .x = 0, .y = 0, .button = .left },
        1,
    );

    // Drag outside the rect; capture should keep routing.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .move, .x = 0, .y = 2 },
        2,
    );

    // Release.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .up, .x = 0, .y = 2, .button = .left },
        3,
    );

    // Second click within double-click window.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .down, .x = 0, .y = 0, .button = .left },
        200 * std.time.ns_per_ms,
    );

    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .up, .x = 0, .y = 0, .button = .left },
        201 * std.time.ns_per_ms,
    );

    // Move off any target: emits leave (id="") exactly once.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .move, .x = 0, .y = 2 },
        202 * std.time.ns_per_ms,
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var got_move_over: bool = false;
    var got_down_1: bool = false;
    var got_drag: bool = false;
    var got_up: bool = false;
    var got_down_2: bool = false;
    var got_leave: bool = false;

    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
        const ev = switch (msg) {
            .event => |e| e,
            else => return error.TestUnexpectedResult,
        };
        const p = switch (ev) {
            .pointer => |pp| pp,
            else => continue,
        };
        switch (p.kind) {
            .move => {
                if (std.mem.eql(u8, p.id, "t")) got_move_over = true;
                if (p.id.len == 0) got_leave = true;
            },
            .down => {
                if (p.clicks == 1) got_down_1 = true;
                if (p.clicks == 2) got_down_2 = true;
                try std.testing.expectEqual(protocol.PointerButton.left, p.button);
            },
            .drag => {
                got_drag = true;
                try std.testing.expect(p.captured);
                try std.testing.expectEqualStrings("t", p.id);
            },
            .up => {
                got_up = true;
                try std.testing.expect(p.captured);
                try std.testing.expectEqualStrings("t", p.id);
            },
            else => {},
        }
    }

    try std.testing.expect(got_move_over);
    try std.testing.expect(got_down_1);
    try std.testing.expect(got_drag);
    try std.testing.expect(got_up);
    try std.testing.expect(got_down_2);
    try std.testing.expect(got_leave);
}

test "pointer: ui scrollbar drag suppresses pointer emission" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(std.testing.allocator);
    var focused_id: ?[]const u8 = null;
    var hover_id_buf: std.ArrayList(u8) = .empty;
    defer hover_id_buf.deinit(std.testing.allocator);
    var hover_id: ?[]const u8 = null;
    var hover_item_buf: std.ArrayList(u8) = .empty;
    defer hover_item_buf.deinit(std.testing.allocator);
    var hover_item: ?[]const u8 = null;
    var auto_focus_done = true;
    var edit_drag: runtime_ui.EditDragState = .{};
    defer edit_drag.deinit(std.testing.allocator);
    var scroll_drag: runtime_ui.ScrollbarDrag = .{};
    defer scroll_drag.deinit(std.testing.allocator);

    var log_sink = runtime_ui.makeNoopLogSink();
    var backend_out: std.ArrayList(u8) = .empty;
    defer backend_out.deinit(std.testing.allocator);
    const backend_writer = backend_out.writer(std.testing.allocator);

    var items = [_]protocol.Node{
        .{ .text = .{ .id = "r0", .text = "0" } },
        .{ .text = .{ .id = "r1", .text = "1" } },
        .{ .text = .{ .id = "r2", .text = "2" } },
        .{ .text = .{ .id = "r3", .text = "3" } },
        .{ .text = .{ .id = "r4", .text = "4" } },
        .{ .text = .{ .id = "r5", .text = "5" } },
    };
    const root = protocol.Node{ .list = .{ .id = "l", .mouseable = true, .w = 6, .height = 3, .children = items[0..] } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        backend_writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        6,
        6,
    );

    var engine: pointer.PointerEngine = .{};
    defer engine.deinit(std.testing.allocator);
    var pointer_out: std.ArrayList(u8) = .empty;
    defer pointer_out.deinit(std.testing.allocator);
    const pointer_writer = pointer_out.writer(std.testing.allocator);

    const events = [_]mouse.MouseEvent{
        .{ .kind = .down, .button = .left, .x = 5, .y = 0 },
        .{ .kind = .move, .x = 5, .y = 20 },
        .{ .kind = .up, .button = .left, .x = 5, .y = 20 },
    };
    for (events, 0..) |ev, idx| {
        const res = try runtime_ui.handleMouseEvent(
            std.testing.allocator,
            &log_sink,
            backend_writer,
            &widgets,
            &edit_drag,
            &scroll_drag,
            &focused_id_buf,
            &focused_id,
            &hover_id_buf,
            &hover_id,
            &hover_item_buf,
            &hover_item,
            root,
            6,
            6,
            "> ",
            .{},
            idx + 1,
            ev,
        );
        if (!res.suppress_pointer) {
            _ = try engine.handleMouseEvent(
                std.testing.allocator,
                pointer_writer,
                widgets.items,
                root,
                6,
                6,
                ev,
                idx + 1,
            );
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, pointer_out.items, "\"name\":\"pointer\"") == null);
}

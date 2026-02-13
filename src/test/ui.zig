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

fn findWidget(widgets: []const runtime_ui.WidgetEntry, id: []const u8) ?runtime_ui.WidgetEntry {
    for (widgets) |w| {
        if (std.mem.eql(u8, w.id.items, id)) return w;
    }
    return null;
}

test "ui: hover hit-test list item" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "results-0", .text = "0" } },
        .{ .text = .{ .id = "results-1", .text = "1" } },
        .{ .text = .{ .id = "results-2", .text = "2" } },
        .{ .text = .{ .id = "results-3", .text = "3" } },
    };

    const root = protocol.Node{ .list = .{ .id = "results", .height = 3, .hoverable = true, .children = children[0..] } };
    const list_states = [_]render.ListState{.{ .id = "results", .selected_id = "", .scroll = 0 }};
    const vlist_states = [_]render.VListState{};
    const empty_scrolls = [_]render.ScrollState{};
    const hit = try hover.hoverHitTestLeaky(std.testing.allocator, root, 10, 10, 0, 1, empty_scrolls[0..], list_states[0..], vlist_states[0..]);
    try std.testing.expectEqualStrings("results", hit.id orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("results-1", hit.item orelse return error.TestUnexpectedResult);
}

test "ui: textarea scroll_y keeps cursor visible" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    const enter_ev: keys.KeyEvent = .{ .key = .{ .named = .enter } };
    _ = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        false,
        2,
        10,
    );
    _ = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        false,
        2,
        10,
    );
    _ = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        false,
        2,
        10,
    );

    var scroll_y: ?usize = null;
    for (widgets.items) |w| {
        if (!std.mem.eql(u8, w.id.items, "ta")) continue;
        scroll_y = w.state.textarea.scroll_y;
        break;
    }
    try std.testing.expect(scroll_y != null);
    try std.testing.expectEqual(@as(usize, 2), scroll_y.?);

    const changed = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        true,
        2,
        10,
    );
    try std.testing.expect(!changed);
}

test "ui: textarea selection and undo redo" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    const ev_a: keys.KeyEvent = .{ .key = .{ .text = "a" } };
    const ev_b: keys.KeyEvent = .{ .key = .{ .text = "b" } };
    const ev_c: keys.KeyEvent = .{ .key = .{ .text = "c" } };
    _ = try runtime_ui.handleFocusedTextareaKey(std.testing.allocator, &widgets, "ta", ev_a, false, 4, 20);
    _ = try runtime_ui.handleFocusedTextareaKey(std.testing.allocator, &widgets, "ta", ev_b, false, 4, 20);
    _ = try runtime_ui.handleFocusedTextareaKey(std.testing.allocator, &widgets, "ta", ev_c, false, 4, 20);

    _ = try runtime_ui.applyTextareaAction(std.testing.allocator, &widgets, "ta", .textarea_select_left, false, 4, 20);
    _ = try runtime_ui.applyTextareaAction(std.testing.allocator, &widgets, "ta", .textarea_select_left, false, 4, 20);

    const selected = try runtime_ui.textareaSelectedTextAlloc(std.testing.allocator, widgets.items, "ta");
    defer if (selected) |s| std.testing.allocator.free(s);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("bc", selected.?);

    _ = try runtime_ui.applyTextareaAction(std.testing.allocator, &widgets, "ta", .textarea_newline, false, 4, 20);
    _ = try runtime_ui.applyTextareaAction(std.testing.allocator, &widgets, "ta", .textarea_undo, false, 4, 20);
    _ = try runtime_ui.applyTextareaAction(std.testing.allocator, &widgets, "ta", .textarea_redo, false, 4, 20);

    var got: []const u8 = "";
    for (widgets.items) |w| {
        if (!std.mem.eql(u8, w.id.items, "ta")) continue;
        got = w.state.textarea.value.items;
        break;
    }
    try std.testing.expectEqualStrings("a\n", got);
}

test "ui: input selection and undo redo" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    const ev_a: keys.KeyEvent = .{ .key = .{ .text = "a" } };
    const ev_b: keys.KeyEvent = .{ .key = .{ .text = "b" } };
    const ev_c: keys.KeyEvent = .{ .key = .{ .text = "c" } };
    _ = try runtime_ui.handleFocusedInputKey(std.testing.allocator, &widgets, "in", ev_a, false, 20);
    _ = try runtime_ui.handleFocusedInputKey(std.testing.allocator, &widgets, "in", ev_b, false, 20);
    _ = try runtime_ui.handleFocusedInputKey(std.testing.allocator, &widgets, "in", ev_c, false, 20);

    _ = try runtime_ui.applyInputAction(std.testing.allocator, &widgets, "in", .input_select_left, false, 20);
    _ = try runtime_ui.applyInputAction(std.testing.allocator, &widgets, "in", .input_select_left, false, 20);

    const selected = try runtime_ui.inputSelectedTextAlloc(std.testing.allocator, widgets.items, "in");
    defer if (selected) |s| std.testing.allocator.free(s);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("bc", selected.?);

    const ev_x: keys.KeyEvent = .{ .key = .{ .text = "x" } };
    _ = try runtime_ui.handleFocusedInputKey(std.testing.allocator, &widgets, "in", ev_x, false, 20);
    _ = try runtime_ui.applyInputAction(std.testing.allocator, &widgets, "in", .input_undo, false, 20);
    _ = try runtime_ui.applyInputAction(std.testing.allocator, &widgets, "in", .input_redo, false, 20);

    var got: []const u8 = "";
    for (widgets.items) |w| {
        if (!std.mem.eql(u8, w.id.items, "in")) continue;
        got = w.state.input.value.items;
        break;
    }
    try std.testing.expectEqualStrings("ax", got);
}

test "ui: focus cycling is trapped within scope" {
    var panel_a_children = [_]protocol.Node{
        .{ .input = .{ .id = "a-1" } },
        .{ .input = .{ .id = "a-2" } },
    };
    var panel_b_children = [_]protocol.Node{
        .{ .input = .{ .id = "b-1" } },
    };
    var root_children = [_]protocol.Node{
        .{ .vbox = .{ .id = "panel-a", .focus_scope = "a", .children = panel_a_children[0..] } },
        .{ .vbox = .{ .id = "panel-b", .focus_scope = "b", .children = panel_b_children[0..] } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    const next_a = try runtime_ui.cycleFocusInTreeDir(std.testing.allocator, root, "a-1", 1);
    try std.testing.expectEqualStrings("a-2", next_a orelse return error.TestUnexpectedResult);

    const wrap_a = try runtime_ui.cycleFocusInTreeDir(std.testing.allocator, root, "a-2", 1);
    try std.testing.expectEqualStrings("a-1", wrap_a orelse return error.TestUnexpectedResult);
}

test "ui: focus scope jump moves between zones" {
    var panel_a_children = [_]protocol.Node{
        .{ .input = .{ .id = "a-1" } },
        .{ .input = .{ .id = "a-2" } },
    };
    var panel_b_children = [_]protocol.Node{
        .{ .input = .{ .id = "b-1" } },
    };
    var root_children = [_]protocol.Node{
        .{ .vbox = .{ .id = "panel-a", .focus_scope = "a", .children = panel_a_children[0..] } },
        .{ .vbox = .{ .id = "panel-b", .focus_scope = "b", .children = panel_b_children[0..] } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    const next_scope = try runtime_ui.cycleFocusScopeInTreeDir(std.testing.allocator, root, "a-1", 1);
    try std.testing.expectEqualStrings("b-1", next_scope orelse return error.TestUnexpectedResult);

    const prev_scope = try runtime_ui.cycleFocusScopeInTreeDir(std.testing.allocator, root, "b-1", -1);
    try std.testing.expectEqualStrings("a-2", prev_scope orelse return error.TestUnexpectedResult);
}

test "ui: sync preserves focusable action widget entries" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(std.testing.allocator);
    var focused_id: ?[]const u8 = null;
    var auto_focus_done = true;

    var log_sink = runtime_ui.makeNoopLogSink();
    var backend_out: std.ArrayList(u8) = .empty;
    defer backend_out.deinit(std.testing.allocator);

    const root = protocol.Node{ .text = .{
        .id = "action-text",
        .text = "Click me",
        .focusable = true,
        .mouseable = true,
    } };

    const backend_writer = backend_out.writer(std.testing.allocator);
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        backend_writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        5,
        20,
    );

    const action_widget = findWidget(widgets.items, "action-text") orelse return error.TestUnexpectedResult;
    try std.testing.expect(action_widget.state == .action);
}

test "ui: patch applies controlled state without emitting events" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(std.testing.allocator);
    var focused_id: ?[]const u8 = null;
    var auto_focus_done = true;

    var log_sink = runtime_ui.makeNoopLogSink();
    var backend_out: std.ArrayList(u8) = .empty;
    defer backend_out.deinit(std.testing.allocator);

    var list_children = [_]protocol.Node{
        .{ .text = .{ .id = "row-1", .text = "one" } },
        .{ .text = .{ .id = "row-2", .text = "two" } },
    };
    var scroll_child = protocol.Node{ .text = .{ .id = "scroll-body", .text = "a\nb\nc\nd" } };
    var children = [_]protocol.Node{
        .{ .input = .{
            .id = "in",
            .focusable = false,
            .state_mode = .controlled,
            .value = "abc",
            .cursor = 2,
            .scroll_x = 1,
            .selection_start = 0,
            .selection_end = 2,
        } },
        .{ .textarea = .{
            .id = "ta",
            .focusable = false,
            .state_mode = .controlled,
            .value = "x\ny\nz",
            .cursor = 2,
            .scroll_y = 10,
            .selection_start = 0,
            .selection_end = 2,
        } },
        .{ .list = .{
            .id = "list",
            .focusable = false,
            .state_mode = .controlled,
            .selected_id = "row-2",
            .scroll = 99,
            .children = list_children[0..],
        } },
        .{ .scroll = .{
            .id = "sv",
            .focusable = false,
            .state_mode = .controlled,
            .scroll_y = 99,
            .child = &scroll_child,
        } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    const backend_writer = backend_out.writer(std.testing.allocator);
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        backend_writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        10,
        20,
    );

    try std.testing.expectEqual(@as(usize, 0), backend_out.items.len);

    const input_widget = findWidget(widgets.items, "in") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abc", input_widget.state.input.value.items);
    try std.testing.expectEqual(@as(usize, 2), input_widget.state.input.cursor);
    try std.testing.expectEqual(@as(usize, 0), input_widget.state.input.selection_anchor.?);

    const textarea_widget = findWidget(widgets.items, "ta") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x\ny\nz", textarea_widget.state.textarea.value.items);
    try std.testing.expectEqual(@as(usize, 2), textarea_widget.state.textarea.cursor);
    try std.testing.expect(textarea_widget.state.textarea.scroll_y <= 10);

    const list_widget = findWidget(widgets.items, "list") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("row-2", list_widget.state.list.selected_id.items);
    try std.testing.expect(list_widget.state.list.scroll <= 1);

    const scroll_widget = findWidget(widgets.items, "sv") orelse return error.TestUnexpectedResult;
    try std.testing.expect(scroll_widget.state.scroll.scroll_y <= 3);
}

test "ui: controlled list does not auto-select on patch" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(std.testing.allocator);
    var focused_id: ?[]const u8 = null;
    var auto_focus_done = true;

    var log_sink = runtime_ui.makeNoopLogSink();
    var backend_out: std.ArrayList(u8) = .empty;
    defer backend_out.deinit(std.testing.allocator);

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "row-1", .text = "one" } },
        .{ .text = .{ .id = "row-2", .text = "two" } },
    };
    const root = protocol.Node{ .list = .{
        .id = "results",
        .focusable = false,
        .state_mode = .controlled,
        .children = children[0..],
    } };

    const backend_writer = backend_out.writer(std.testing.allocator);
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        backend_writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        10,
        20,
    );

    try std.testing.expectEqual(@as(usize, 0), backend_out.items.len);

    const list_widget = findWidget(widgets.items, "results") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), list_widget.state.list.selected_id.items.len);
}

test "ui: vlist emits init range request and coalesces identical request" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(std.testing.allocator);
    var focused_id: ?[]const u8 = null;
    var auto_focus_done = true;

    var log_sink = runtime_ui.makeNoopLogSink();
    var backend_out: std.ArrayList(u8) = .empty;
    defer backend_out.deinit(std.testing.allocator);
    const writer = backend_out.writer(std.testing.allocator);

    const root = protocol.Node{ .vlist = .{
        .id = "results",
        .focusable = true,
        .hoverable = true,
        .mouseable = true,
        .total = 1_000_000,
        .window_start = 0,
        .item_id_prefix = "row-",
        .children = &.{},
    } };

    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        20,
        40,
    );
    try std.testing.expectEqual(@as(usize, 0), backend_out.items.len);

    const changed_first = try runtime_ui.maybeRequestVListRanges(
        std.testing.allocator,
        writer,
        &widgets,
        root,
        20,
        40,
        .init,
    );
    try std.testing.expect(changed_first);
    const first_len = backend_out.items.len;
    try std.testing.expect(std.mem.indexOf(u8, backend_out.items, "\"name\":\"vlist_range\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend_out.items, "\"id\":\"results\"") != null);

    const changed_second = try runtime_ui.maybeRequestVListRanges(
        std.testing.allocator,
        writer,
        &widgets,
        root,
        20,
        40,
        .init,
    );
    try std.testing.expect(!changed_second);
    try std.testing.expectEqual(first_len, backend_out.items.len);
}

test "ui: vlist key navigation emits select with deterministic item and index" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(std.testing.allocator);
    var focused_id: ?[]const u8 = null;
    var auto_focus_done = true;

    var log_sink = runtime_ui.makeNoopLogSink();
    var backend_out: std.ArrayList(u8) = .empty;
    defer backend_out.deinit(std.testing.allocator);
    const writer = backend_out.writer(std.testing.allocator);

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "row-0", .text = "0" } },
        .{ .text = .{ .id = "row-1", .text = "1" } },
        .{ .text = .{ .id = "row-2", .text = "2" } },
    };
    const root = protocol.Node{ .vlist = .{
        .id = "results",
        .focusable = true,
        .total = 100,
        .window_start = 0,
        .item_id_prefix = "row-",
        .children = children[0..],
    } };

    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        10,
        40,
    );

    const changed = try runtime_ui.applyVListAction(
        std.testing.allocator,
        writer,
        &widgets,
        root,
        10,
        40,
        "results",
        .list_next,
    );
    try std.testing.expect(changed);
    try std.testing.expect(std.mem.indexOf(u8, backend_out.items, "\"name\":\"select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend_out.items, "\"item\":\"row-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend_out.items, "\"index\":1") != null);
}

test "ui: mouse click in input places cursor by column" {
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
    const writer = backend_out.writer(std.testing.allocator);

    const root = protocol.Node{ .input = .{ .id = "in", .mouseable = true, .w = 12 } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        4,
        20,
    );
    _ = try runtime_ui.handleFocusedInputPaste(std.testing.allocator, &widgets, "in", "hello", false, 10);

    _ = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        4,
        20,
        "> ",
        .{},
        1,
        .{ .kind = .down, .button = .left, .x = 4, .y = 0 },
    );

    const in_widget = findWidget(widgets.items, "in") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), in_widget.state.input.cursor);
}

test "ui: mouse drag in input updates selection anchor and cursor" {
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
    const writer = backend_out.writer(std.testing.allocator);

    const root = protocol.Node{ .input = .{ .id = "in", .mouseable = true, .w = 12 } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        4,
        20,
    );
    _ = try runtime_ui.handleFocusedInputPaste(std.testing.allocator, &widgets, "in", "hello", false, 10);

    _ = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        4,
        20,
        "> ",
        .{},
        1,
        .{ .kind = .down, .button = .left, .x = 3, .y = 0 },
    );
    _ = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        4,
        20,
        "> ",
        .{},
        2,
        .{ .kind = .move, .x = 6, .y = 0 },
    );

    const in_widget = findWidget(widgets.items, "in") orelse return error.TestUnexpectedResult;
    try std.testing.expect(in_widget.state.input.selection_anchor != null);
    try std.testing.expectEqual(@as(usize, 1), in_widget.state.input.selection_anchor.?);
    try std.testing.expect(in_widget.state.input.cursor > in_widget.state.input.selection_anchor.?);
}

test "ui: mouse click and drag in textarea updates wrapped cursor and selection" {
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
    const writer = backend_out.writer(std.testing.allocator);

    const root = protocol.Node{ .textarea = .{ .id = "ta", .mouseable = true, .w = 4, .h = 3 } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        2,
        5,
    );
    _ = try runtime_ui.handleFocusedTextareaPaste(std.testing.allocator, &widgets, "ta", "abcdef", false, 3, 4);

    _ = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        2,
        5,
        "> ",
        .{},
        1,
        .{ .kind = .down, .button = .left, .x = 1, .y = 1 },
    );
    _ = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        10,
        "> ",
        .{},
        2,
        .{ .kind = .move, .x = 0, .y = 0 },
    );

    const ta_widget = findWidget(widgets.items, "ta") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), ta_widget.state.textarea.cursor);
    try std.testing.expect(ta_widget.state.textarea.selection_anchor != null);
    try std.testing.expect(ta_widget.state.textarea.selection_anchor.? > 0);
}

test "ui: mouse wheel over textarea updates local scroll_y" {
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
    const writer = backend_out.writer(std.testing.allocator);

    const root = protocol.Node{ .textarea = .{ .id = "ta", .mouseable = true, .w = 5, .h = 2 } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        6,
        10,
    );
    _ = try runtime_ui.handleFocusedTextareaPaste(std.testing.allocator, &widgets, "ta", "abcdefghijklmnop", false, 2, 5);
    const ta_idx = for (widgets.items, 0..) |w, idx| {
        if (std.mem.eql(u8, w.id.items, "ta")) break idx;
    } else return error.TestUnexpectedResult;
    widgets.items[ta_idx].state.textarea.scroll_y = 2;

    const res = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        10,
        "> ",
        .{},
        1,
        .{ .kind = .wheel, .x = 2, .y = 0, .wheel_dy = -1 },
    );
    try std.testing.expect(res.suppress_pointer);

    const ta_widget = findWidget(widgets.items, "ta") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ta_widget.state.textarea.scroll_y < 2);
}

test "ui: scrollbar track click jumps list scroll" {
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
    const writer = backend_out.writer(std.testing.allocator);

    var items = [_]protocol.Node{
        .{ .text = .{ .id = "r0", .text = "0" } },
        .{ .text = .{ .id = "r1", .text = "1" } },
        .{ .text = .{ .id = "r2", .text = "2" } },
        .{ .text = .{ .id = "r3", .text = "3" } },
        .{ .text = .{ .id = "r4", .text = "4" } },
        .{ .text = .{ .id = "r5", .text = "5" } },
        .{ .text = .{ .id = "r6", .text = "6" } },
        .{ .text = .{ .id = "r7", .text = "7" } },
    };
    const root = protocol.Node{ .list = .{ .id = "l", .mouseable = true, .w = 6, .height = 3, .children = items[0..] } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        6,
        6,
    );

    const res = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        1,
        .{ .kind = .down, .button = .left, .x = 5, .y = 2 },
    );
    try std.testing.expect(res.changed);
    try std.testing.expect(res.suppress_pointer);

    const list_widget = findWidget(widgets.items, "l") orelse return error.TestUnexpectedResult;
    try std.testing.expect(list_widget.state.list.scroll > 0);
}

test "ui: scrollbar thumb drag updates and clamps list scroll" {
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
    const writer = backend_out.writer(std.testing.allocator);

    var items = [_]protocol.Node{
        .{ .text = .{ .id = "r0", .text = "0" } },
        .{ .text = .{ .id = "r1", .text = "1" } },
        .{ .text = .{ .id = "r2", .text = "2" } },
        .{ .text = .{ .id = "r3", .text = "3" } },
        .{ .text = .{ .id = "r4", .text = "4" } },
        .{ .text = .{ .id = "r5", .text = "5" } },
        .{ .text = .{ .id = "r6", .text = "6" } },
        .{ .text = .{ .id = "r7", .text = "7" } },
    };
    const root = protocol.Node{ .list = .{ .id = "l", .mouseable = true, .w = 6, .height = 3, .children = items[0..] } };
    try runtime_ui.syncUiAfterPatch(
        std.testing.allocator,
        &log_sink,
        writer,
        &widgets,
        &focused_id_buf,
        &focused_id,
        &auto_focus_done,
        root,
        6,
        6,
    );

    const down_res = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        1,
        .{ .kind = .down, .button = .left, .x = 5, .y = 0 },
    );
    try std.testing.expect(down_res.suppress_pointer);

    const move_res = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        2,
        .{ .kind = .move, .x = 5, .y = 20 },
    );
    try std.testing.expect(move_res.suppress_pointer);
    try std.testing.expect(move_res.changed);

    const up_res = try runtime_ui.handleMouseEvent(
        std.testing.allocator,
        &log_sink,
        writer,
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
        3,
        .{ .kind = .up, .button = .left, .x = 5, .y = 20 },
    );
    try std.testing.expect(up_res.suppress_pointer);

    const list_widget = findWidget(widgets.items, "l") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 5), list_widget.state.list.scroll);
}

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

test "ui: hover hit-test list item" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "results-0", .text = "0" } },
        .{ .text = .{ .id = "results-1", .text = "1" } },
        .{ .text = .{ .id = "results-2", .text = "2" } },
        .{ .text = .{ .id = "results-3", .text = "3" } },
    };

    const root = protocol.Node{ .list = .{ .id = "results", .height = 3, .hoverable = true, .children = children[0..] } };
    const list_states = [_]render.ListState{.{ .id = "results", .selected_id = "", .scroll = 0 }};
    const empty_scrolls = [_]render.ScrollState{};
    const hit = try hover.hoverHitTestLeaky(std.testing.allocator, root, 10, 10, 0, 1, empty_scrolls[0..], list_states[0..]);
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

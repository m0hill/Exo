const prelude = @import("prelude.zig");
const std = prelude.std;
const protocol = prelude.protocol;
const runtime_ui = prelude.runtime_ui;
const keys = prelude.keys;

test "keybindings: defaults and precedence" {
    var keymap = try runtime_ui.KeymapState.initDefaults(std.testing.allocator);
    defer keymap.deinit();

    try std.testing.expectEqual(protocol.KeyAction.focus_next, keymap.resolve(.global, "Tab", 0) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.focus_prev, keymap.resolve(.global, "Tab", 1) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.list_next, keymap.resolve(.list, "j", 0) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.input_word_left, keymap.resolve(.input, "b", 4) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.input_select_left, keymap.resolve(.input, "ArrowLeft", 1) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.input_select_all, keymap.resolve(.input, "a", 2) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.textarea_select_left, keymap.resolve(.textarea, "ArrowLeft", 1) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.textarea_select_all, keymap.resolve(.textarea, "a", 2) orelse return error.TestUnexpectedResult);

    var global_rules = [_]protocol.KeybindingRule{
        .{ .key = "j", .action = .focus_next },
    };
    var list_rules = [_]protocol.KeybindingRule{
        .{ .key = "j", .action = .list_prev },
    };
    const cfg = protocol.KeybindingsConfig{
        .global = global_rules[0..],
        .list = list_rules[0..],
    };
    try keymap.applyConfigReplace(cfg);
    try std.testing.expectEqual(protocol.KeyAction.list_prev, keymap.resolve(.list, "j", 0) orelse return error.TestUnexpectedResult);
}

test "keybindings: noop and replace semantics" {
    var keymap = try runtime_ui.KeymapState.initDefaults(std.testing.allocator);
    defer keymap.deinit();

    var list_rules = [_]protocol.KeybindingRule{
        .{ .key = "x", .action = .noop },
    };
    try keymap.applyConfigReplace(.{
        .list = list_rules[0..],
    });

    try std.testing.expectEqual(protocol.KeyAction.noop, keymap.resolve(.list, "x", 0) orelse return error.TestUnexpectedResult);
    try std.testing.expect(keymap.resolve(.list, "j", 0) == null);
    try std.testing.expectEqual(protocol.KeyAction.focus_next, keymap.resolve(.global, "Tab", 0) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(protocol.KeyAction.input_left, keymap.resolve(.input, "ArrowLeft", 0) orelse return error.TestUnexpectedResult);
}

test "keybindings: explicit empty context clears defaults" {
    var keymap = try runtime_ui.KeymapState.initDefaults(std.testing.allocator);
    defer keymap.deinit();

    var empty_rules = [_]protocol.KeybindingRule{};
    try keymap.applyConfigReplace(.{
        .list = empty_rules[0..],
    });
    try std.testing.expect(keymap.resolve(.list, "j", 0) == null);
}

test "keybindings: invalid config parse leaves previous bindings" {
    var keymap = try runtime_ui.KeymapState.initDefaults(std.testing.allocator);
    defer keymap.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = keymap.resolve(.global, "Tab", 0) orelse return error.TestUnexpectedResult;
    const invalid =
        "{\"type\":\"config\",\"keybindings\":{\"global\":[{\"key\":\"Tab\",\"action\":\"unknown_action\"}]}}";
    try std.testing.expectError(error.UnknownKeyAction, protocol.parseMsgLeaky(arena.allocator(), invalid));
    try std.testing.expectEqual(before, keymap.resolve(.global, "Tab", 0) orelse return error.TestUnexpectedResult);
}

test "runtime config reject emits ack and error events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try runtime_ui.writeConfigRejectAckAndErrorEvents(
        out.writer(std.testing.allocator),
        error.InvalidKeybindingRule,
        false,
    );

    var lines = std.mem.tokenizeScalar(u8, out.items, '\n');
    const ack_line = lines.next() orelse return error.TestUnexpectedResult;
    const err_line = lines.next() orelse return error.TestUnexpectedResult;

    const ack_msg = try protocol.parseMsgLeaky(arena.allocator(), ack_line);
    switch (ack_msg) {
        .event => |ev| switch (ev) {
            .config_ack => |ack| {
                try std.testing.expectEqual(@as(usize, 0), ack.applied.len);
                try std.testing.expectEqual(@as(usize, 1), ack.rejected.len);
                try std.testing.expectEqualStrings("keybindings", ack.rejected[0].key);
                try std.testing.expectEqualStrings("InvalidKeybindingRule", ack.rejected[0].reason);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const err_msg = try protocol.parseMsgLeaky(arena.allocator(), err_line);
    switch (err_msg) {
        .event => |ev| switch (ev) {
            .@"error" => |err_ev| {
                try std.testing.expectEqualStrings("config_rejected", err_ev.code);
                try std.testing.expectEqualStrings("backend config rejected", err_ev.message);
                try std.testing.expectEqualStrings("InvalidKeybindingRule", err_ev.context orelse return error.TestUnexpectedResult);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "runtime config reject includes theme_spec when keybindings fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try runtime_ui.writeConfigRejectAckAndErrorEvents(
        out.writer(std.testing.allocator),
        error.InvalidKeybindingRule,
        true,
    );

    var lines = std.mem.tokenizeScalar(u8, out.items, '\n');
    const ack_line = lines.next() orelse return error.TestUnexpectedResult;
    _ = lines.next() orelse return error.TestUnexpectedResult;

    const ack_msg = try protocol.parseMsgLeaky(arena.allocator(), ack_line);
    switch (ack_msg) {
        .event => |ev| switch (ev) {
            .config_ack => |ack| {
                try std.testing.expectEqual(@as(usize, 2), ack.rejected.len);
                try std.testing.expectEqualStrings("keybindings", ack.rejected[0].key);
                try std.testing.expectEqualStrings("theme_spec", ack.rejected[1].key);
                try std.testing.expectEqualStrings("keybindings_rejected", ack.rejected[1].reason);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "ui key actions: input and textarea action handlers" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    const type_a: keys.KeyEvent = .{ .key = .{ .text = "a" } };
    const type_b: keys.KeyEvent = .{ .key = .{ .text = "b" } };
    _ = try runtime_ui.handleFocusedInputKey(std.testing.allocator, &widgets, "in", type_a, false, 10);
    _ = try runtime_ui.handleFocusedInputKey(std.testing.allocator, &widgets, "in", type_b, false, 10);
    var before_backspace_len: usize = 0;
    for (widgets.items) |w| {
        if (!std.mem.eql(u8, w.id.items, "in")) continue;
        before_backspace_len = w.state.input.value.items.len;
        break;
    }
    _ = try runtime_ui.applyInputAction(std.testing.allocator, &widgets, "in", .input_left, false, 10);
    _ = try runtime_ui.applyInputAction(std.testing.allocator, &widgets, "in", .input_backspace, false, 10);
    var after_backspace_len: usize = 0;
    for (widgets.items) |w| {
        if (!std.mem.eql(u8, w.id.items, "in")) continue;
        after_backspace_len = w.state.input.value.items.len;
        break;
    }
    try std.testing.expect(after_backspace_len < before_backspace_len);

    const enter_ev: keys.KeyEvent = .{ .key = .{ .named = .enter } };
    _ = try runtime_ui.handleFocusedTextareaKey(std.testing.allocator, &widgets, "ta", enter_ev, false, 3, 10);
    const ta_changed = try runtime_ui.applyTextareaAction(std.testing.allocator, &widgets, "ta", .textarea_newline, false, 3, 10);
    try std.testing.expect(ta_changed);
}

test "ui key actions: list, scroll, action widget handlers" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    var list_children = [_]protocol.Node{
        .{ .text = .{ .id = "item-1", .text = "one" } },
        .{ .text = .{ .id = "item-2", .text = "two" } },
    };
    var scroll_child_children = [_]protocol.Node{
        .{ .text = .{ .id = "ln-1", .text = "1" } },
        .{ .text = .{ .id = "ln-2", .text = "2" } },
        .{ .text = .{ .id = "ln-3", .text = "3" } },
        .{ .text = .{ .id = "ln-4", .text = "4" } },
        .{ .text = .{ .id = "ln-5", .text = "5" } },
    };
    var scroll_inner = protocol.Node{ .vbox = .{ .id = "inner", .children = scroll_child_children[0..] } };
    const scroll_node = protocol.Node{ .scroll = .{ .id = "sv", .child = &scroll_inner } };

    var root_children = [_]protocol.Node{
        .{ .list = .{ .id = "lst", .children = list_children[0..] } },
        scroll_node,
        .{ .box = .{ .id = "btn", .focusable = true, .child = &scroll_inner } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const writer = buf.writer(std.testing.allocator);

    const list_changed = try runtime_ui.applyListAction(std.testing.allocator, writer, &widgets, root, 6, 20, "lst", .list_next);
    try std.testing.expect(list_changed);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"select\"") != null);

    buf.clearRetainingCapacity();
    const scroll_changed = try runtime_ui.applyScrollAction(std.testing.allocator, writer, &widgets, root, 3, 20, "sv", .scroll_line_down);
    try std.testing.expect(scroll_changed);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"scroll\"") != null);

    buf.clearRetainingCapacity();
    const action_changed = try runtime_ui.applyActionWidgetAction(writer, "btn", .action_activate);
    try std.testing.expect(action_changed);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"activate\"") != null);
}

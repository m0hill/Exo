const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const style = tui.style;
const markdown = tui.markdown;
const widget_kit = tui.widget_kit;

const state = @import("state.zig");
const DEMO_PROTOCOL_VERSION: u32 = 1;

pub fn emitInitialFull(
    allocator: std.mem.Allocator,
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    md_stream_node: protocol.Node,
    md_stream_title: []const u8,
    md_stream_hint: []const u8,
    md_speed_faster_label: []const u8,
    md_speed_slower_label: []const u8,
    md_speed_chunk_smaller_label: []const u8,
    md_speed_chunk_larger_label: []const u8,
    inputs: []const state.InputSlot,
    lists: []const state.ListSlot,
    list_height: usize,
    popups: state.PopupInfo,
    widgets: state.WidgetsState,
    tick: u64,
) !void {
    try writer.print("{{\"type\":\"patch\",\"v\":{d},\"root\":", .{DEMO_PROTOCOL_VERSION});
    try writeRootNode(
        allocator,
        writer,
        tick_text,
        status_text,
        md_stream_node,
        md_stream_title,
        md_stream_hint,
        md_speed_faster_label,
        md_speed_slower_label,
        md_speed_chunk_smaller_label,
        md_speed_chunk_larger_label,
        inputs,
        lists,
        false,
        list_height,
        popups,
        widgets,
        tick,
    );
    try writer.writeAll("}\n");
}

pub fn emitRootMorphPatch(
    allocator: std.mem.Allocator,
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    md_stream_node: protocol.Node,
    md_stream_title: []const u8,
    md_stream_hint: []const u8,
    md_speed_faster_label: []const u8,
    md_speed_slower_label: []const u8,
    md_speed_chunk_smaller_label: []const u8,
    md_speed_chunk_larger_label: []const u8,
    inputs: []const state.InputSlot,
    lists: []const state.ListSlot,
    layout_alt: bool,
    list_height: usize,
    popups: state.PopupInfo,
    widgets: state.WidgetsState,
    tick: u64,
) !void {
    try writer.print("{{\"type\":\"patch\",\"v\":{d},\"target\":\"root\",\"mode\":\"morph\",\"node\":", .{DEMO_PROTOCOL_VERSION});
    try writeRootNode(
        allocator,
        writer,
        tick_text,
        status_text,
        md_stream_node,
        md_stream_title,
        md_stream_hint,
        md_speed_faster_label,
        md_speed_slower_label,
        md_speed_chunk_smaller_label,
        md_speed_chunk_larger_label,
        inputs,
        lists,
        layout_alt,
        list_height,
        popups,
        widgets,
        tick,
    );
    try writer.writeAll("}\n");
}

fn writeTextNode(writer: anytype, id: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeByte('}');
}

const SpanSpec = struct {
    text: []const u8,
    style_json: ?[]const u8 = null,
};

fn writeSpan(writer: anytype, sp: SpanSpec) !void {
    try writer.writeAll("{\"text\":");
    try protocol.writeJsonString(writer, sp.text);
    if (sp.style_json) |sj| {
        try writer.writeAll(",\"style\":");
        try writer.writeAll(sj);
    }
    try writer.writeByte('}');
}

fn writeStyledTextNodeLayoutStyled(
    writer: anytype,
    id: []const u8,
    spans: []const SpanSpec,
    w: ?usize,
    h: ?usize,
    flex: usize,
    style_json: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"styled_text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
    if (style_json) |sj| {
        try writer.writeAll(",\"style\":");
        try writer.writeAll(sj);
    }
    try writer.writeAll(",\"spans\":[");
    for (spans, 0..) |sp, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeSpan(writer, sp);
    }
    try writer.writeAll("]}");
}

fn writeTextNodeLayout(
    writer: anytype,
    id: []const u8,
    text: []const u8,
    w: ?usize,
    h: ?usize,
    flex: usize,
) !void {
    try writeTextNodeLayoutStyled(writer, id, text, w, h, flex, null);
}

fn writeTextNodeLayoutStyled(
    writer: anytype,
    id: []const u8,
    text: []const u8,
    w: ?usize,
    h: ?usize,
    flex: usize,
    style_json: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
    if (style_json) |sj| {
        try writer.writeAll(",\"style\":");
        try writer.writeAll(sj);
    }
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeByte('}');
}

fn writeInputNode(writer: anytype, id: []const u8, placeholder: []const u8) !void {
    try writer.writeAll("{\"type\":\"input\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"placeholder\":");
    try protocol.writeJsonString(writer, placeholder);
    try writer.writeByte('}');
}

fn writeInputNodeLayout(
    writer: anytype,
    id: []const u8,
    placeholder: []const u8,
    w: ?usize,
    h: ?usize,
    flex: usize,
) !void {
    try writeInputNodeLayoutStyled(writer, id, placeholder, w, h, flex, null, null, false, false);
}

fn writeInputNodeLayoutStyled(
    writer: anytype,
    id: []const u8,
    placeholder: []const u8,
    w: ?usize,
    h: ?usize,
    flex: usize,
    style_json: ?[]const u8,
    placeholder_style_json: ?[]const u8,
    hoverable: bool,
    mouseable: bool,
) !void {
    try writer.writeAll("{\"type\":\"input\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
    if (style_json) |sj| {
        try writer.writeAll(",\"style\":");
        try writer.writeAll(sj);
    }
    if (placeholder_style_json) |sj| {
        try writer.writeAll(",\"placeholder_style\":");
        try writer.writeAll(sj);
    }
    if (hoverable) try writer.writeAll(",\"hoverable\":true");
    if (mouseable) try writer.writeAll(",\"mouseable\":true");
    try writer.writeAll(",\"placeholder\":");
    try protocol.writeJsonString(writer, placeholder);
    try writer.writeByte('}');
}

fn writeListNode(
    writer: anytype,
    id: []const u8,
    height: usize,
    items: []const u64,
    style_json: ?[]const u8,
    hoverable: bool,
    mouseable: bool,
) !void {
    try writer.writeAll("{\"type\":\"list\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (style_json) |sj| {
        try writer.writeAll(",\"style\":");
        try writer.writeAll(sj);
    }
    if (hoverable) try writer.writeAll(",\"hoverable\":true");
    if (mouseable) try writer.writeAll(",\"mouseable\":true");
    try writer.print(",\"height\":{d},\"children\":[", .{height});
    for (items, 0..) |it, idx| {
        if (idx != 0) try writer.writeByte(',');
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "Item {d}", .{it});
        var item_id_buf: [64]u8 = undefined;
        const item_id = try std.fmt.bufPrint(&item_id_buf, "{s}-{d}", .{ id, it });
        try writeTextNode(writer, item_id, text);
    }
    try writer.writeAll("]}");
}

pub fn emitListMorphPatch(writer: anytype, list_id: []const u8, items: []const u64, height: usize) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, list_id);
    try writer.writeAll(",\"mode\":\"morph\",\"node\":");
    try writeListNode(writer, list_id, height, items, null, true, true);
    try writer.writeAll("}\n");
}

pub fn emitMarkdownMorphPatch(
    allocator: std.mem.Allocator,
    writer: anytype,
    target: []const u8,
    md: []const u8,
) !void {
    var node = try markdown.compileLeaky(allocator, md, .{
        .id = target,
        .id_prefix = target,
        .own_text = false,
    });
    // Preserve the host layout contract: keep the streamed subtree flexible and clipped.
    switch (node) {
        .vbox => |*v| {
            v.flex = 1;
            v.clip = true;
        },
        else => {},
    }

    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"mode\":\"morph\",\"node\":");
    try protocol.writeNodeJson(writer, node);
    try writer.writeAll("}\n");
}

pub fn emitNodeMorphPatch(writer: anytype, target: []const u8, node: protocol.Node) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"mode\":\"morph\",\"node\":");
    try protocol.writeNodeJson(writer, node);
    try writer.writeAll("}\n");
}

pub fn emitNodePatchById(writer: anytype, target: []const u8, node: protocol.Node) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"node\":");
    try protocol.writeNodeJson(writer, node);
    try writer.writeAll("}\n");
}

pub fn emitTextPatchById(writer: anytype, target: []const u8, text: []const u8) !void {
    return emitTextPatchByIdStyled(writer, target, text, null);
}

pub fn emitTextPatchByIdStyled(
    writer: anytype,
    target: []const u8,
    text: []const u8,
    style_json: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"node\":{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"h\":1");
    if (style_json) |sj| {
        try writer.writeAll(",\"style\":");
        try writer.writeAll(sj);
    }
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeAll("}}\n");
}

fn writePanelNode(
    writer: anytype,
    id: []const u8,
    focus_scope: []const u8,
    title: []const u8,
    accent_fg: []const u8,
    input_id: []const u8,
    list_id: []const u8,
    list_height: usize,
    items: []const u64,
) !void {
    var body_buf: [128]u8 = undefined;
    const body_id = try std.fmt.bufPrint(&body_buf, "{s}-body", .{id});

    try writer.writeAll("{\"type\":\"box\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"focus_scope\":");
    try protocol.writeJsonString(writer, focus_scope);
    try writer.writeAll(",\"flex\":1,\"pad\":1,\"clip\":true");
    try writer.writeAll(",\"style\":{\"bg\":\"#0b1220\",\"fg\":");
    try protocol.writeJsonString(writer, accent_fg);
    try writer.writeAll("}");
    try writer.writeAll(",\"title\":");
    try protocol.writeJsonString(writer, title);
    try writer.writeAll(",\"child\":");
    try writer.writeAll("{\"type\":\"vbox\",\"id\":");
    try protocol.writeJsonString(writer, body_id);
    try writer.writeAll(",\"clip\":true,\"style\":{\"fg\":\"#e5e7eb\"},\"children\":[");
    try writeInputNodeLayoutStyled(
        writer,
        input_id,
        "Type here…",
        null,
        1,
        0,
        "{\"fg\":\"#f9fafb\"}",
        "{\"fg\":\"gray\",\"dim\":true}",
        true,
        true,
    );
    try writer.writeByte(',');
    try writeListNode(writer, list_id, list_height, items, "{\"fg\":\"#e5e7eb\"}", true, true);
    try writer.writeAll("]}");
    try writer.writeByte('}');
}

fn writeAlignmentPanelNode(writer: anytype, focus_scope: []const u8) !void {
    const panel_style: style.StyleOverride = .{
        .bg = .{ .rgb = .{ .r = 0x0B, .g = 0x12, .b = 0x20 } },
        .fg = .{ .rgb = .{ .r = 0xFB, .g = 0x71, .b = 0x85 } },
    };

    const body_style: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0xE5, .g = 0xE7, .b = 0xEB } },
    };

    const dim_style: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0x94, .g = 0xA3, .b = 0xB8 } },
        .attrs_set = style.ATTR_DIM,
        .attrs_values = style.ATTR_DIM,
    };

    const label_style: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0xF9, .g = 0xFA, .b = 0xFB } },
        .attrs_set = style.ATTR_BOLD,
        .attrs_values = style.ATTR_BOLD,
    };

    var hbox_children = [_]protocol.Node{
        .{ .text = .{ .id = "align-hbox-a", .w = 6, .h = 1, .ext_align = .center, .text = "A" } },
        .{ .text = .{ .id = "align-hbox-b", .w = 6, .h = 1, .ext_align = .center, .text = "B" } },
        .{ .text = .{ .id = "align-hbox-c", .w = 6, .h = 1, .ext_align = .center, .text = "C" } },
    };
    const demo_hbox = protocol.Node{ .hbox = .{
        .id = "align-hbox",
        .h = 3,
        .gap = 1,
        .justify_content = .space_between,
        .align_items = .end,
        .children = hbox_children[0..],
    } };

    var justify_children = [_]protocol.Node{
        .{ .text = .{
            .id = "align-justify-item",
            .w = 18,
            .ext_align = .center,
            .style = label_style,
            .text = "justify=center",
        } },
    };
    const justify_block = protocol.Node{ .vbox = .{
        .id = "align-justify",
        .h = 5,
        .justify_content = .center,
        .align_items = .center,
        .children = justify_children[0..],
    } };

    const text_block = protocol.Node{ .text = .{
        .id = "align-text",
        .w = 24,
        .h = 3,
        .align_self = .center,
        .ext_align = .right,
        .v_align = .center,
        .style = label_style,
        .text = "ext_align=right",
    } };

    const input_block = protocol.Node{ .input = .{
        .id = "align-input",
        .w = 24,
        .align_self = .center,
        .hoverable = true,
        .mouseable = true,
        .content_align = .right,
        .placeholder = "content_align=right",
        .placeholder_style = dim_style,
    } };

    var body_children = [_]protocol.Node{
        .{ .text = .{ .id = "align-title", .h = 1, .style = label_style, .text = "Alignment showcase" } },
        .{ .text = .{ .id = "align-gap", .h = 1, .style = dim_style, .text = "gap=1 + align_self + justify_content" } },
        justify_block,
        text_block,
        input_block,
        .{ .text = .{ .id = "align-hbox-hint", .h = 1, .style = dim_style, .text = "hbox: space_between + align_items=end" } },
        demo_hbox,
    };
    var body = protocol.Node{ .vbox = .{
        .id = "panel-align-body",
        .gap = 1,
        .clip = true,
        .style = body_style,
        .children = body_children[0..],
    } };

    const box = protocol.Node{ .box = .{
        .id = "panel-align",
        .flex = 1,
        .pad = 1,
        .clip = true,
        .focus_scope = focus_scope,
        .style = panel_style,
        .title = "Alignment",
        .child = &body,
    } };

    try protocol.writeNodeJson(writer, box);
}

fn writeWidgetsPanelNode(
    allocator: std.mem.Allocator,
    writer: anytype,
    focus_scope: []const u8,
    widgets: state.WidgetsState,
    tick: u64,
) !void {
    const panel_style: style.StyleOverride = .{
        .bg = .{ .rgb = .{ .r = 0x0B, .g = 0x12, .b = 0x20 } },
        .fg = .{ .rgb = .{ .r = 0x34, .g = 0xD3, .b = 0x99 } },
    };

    const body_style: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0xE5, .g = 0xE7, .b = 0xEB } },
    };

    const dim_style: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0x94, .g = 0xA3, .b = 0xB8 } },
        .attrs_set = style.ATTR_DIM,
        .attrs_values = style.ATTR_DIM,
    };

    const active_menu_style: style.StyleOverride = .{
        .attrs_set = style.ATTR_BOLD | style.ATTR_UNDERLINE,
        .attrs_values = style.ATTR_BOLD | style.ATTR_UNDERLINE,
    };

    const common_interactive: widget_kit.Common = .{ .hoverable = true, .mouseable = true };

    var children: std.ArrayList(protocol.Node) = .empty;

    const menu_file_style: ?style.StyleOverride = if (widgets.menu_open and widgets.menu_anchor == .file) active_menu_style else null;
    const menu_help_style: ?style.StyleOverride = if (widgets.menu_open and widgets.menu_anchor == .help) active_menu_style else null;
    const menu_bar = protocol.Node{ .hbox = .{
        .id = "w-menubar",
        .gap = 1,
        .children = blk: {
            var menu_children = try allocator.alloc(protocol.Node, 2);
            menu_children[0] = try widget_kit.button(allocator, "w-menu-file", "File", false, .{
                .hoverable = true,
                .mouseable = true,
                .style = menu_file_style,
            });
            menu_children[1] = try widget_kit.button(allocator, "w-menu-help", "Help", false, .{
                .hoverable = true,
                .mouseable = true,
                .style = menu_help_style,
            });
            break :blk menu_children;
        },
    } };
    try children.append(allocator, .{ .text = .{ .id = "w-sec-menu", .h = 1, .style = dim_style, .text = "Menu (opens modal overlay):" } });
    try children.append(allocator, menu_bar);

    var btn_label_buf: [64]u8 = undefined;
    const btn_label = try std.fmt.bufPrint(&btn_label_buf, "Button (clicks={d})", .{widgets.button_clicks});
    var btn_children = try allocator.alloc(protocol.Node, 3);
    btn_children[0] = try widget_kit.button(allocator, "w-btn", btn_label, true, common_interactive);
    btn_children[1] = try widget_kit.button(allocator, "w-btn-disabled", "Disabled (skips tab)", true, .{
        .disabled = true,
        .hoverable = true,
        .mouseable = true,
    });
    btn_children[2] = try widget_kit.button(allocator, "w-btn-error", "Validation error", true, .{
        .validation = .@"error",
        .hoverable = true,
        .mouseable = true,
    });
    try children.append(allocator, .{ .text = .{ .id = "w-sec-buttons", .h = 1, .style = dim_style, .text = "Buttons / action focus targets:" } });
    try children.append(allocator, .{ .hbox = .{ .id = "w-buttons", .gap = 1, .children = btn_children } });

    const checkbox_node = try widget_kit.checkbox(allocator, "w-checkbox", "Checkbox", widgets.checkbox_checked, common_interactive);
    const toggle_node = try widget_kit.toggle(allocator, "w-toggle", "Toggle", widgets.toggle_on, .{
        .hoverable = true,
        .mouseable = true,
        .validation = .success,
    });
    var ct_children = try allocator.alloc(protocol.Node, 2);
    ct_children[0] = checkbox_node;
    ct_children[1] = toggle_node;
    try children.append(allocator, .{ .text = .{ .id = "w-sec-check", .h = 1, .style = dim_style, .text = "Checkbox / toggle:" } });
    try children.append(allocator, .{ .hbox = .{ .id = "w-check-row", .gap = 2, .children = ct_children } });

    const radio_opts = [_]widget_kit.ListOption{
        .{ .id = "w-radio-a", .label = "Alpha" },
        .{ .id = "w-radio-b", .label = "Beta" },
        .{ .id = "w-radio-c", .label = "Gamma" },
    };
    const selected_radio_id: []const u8 = switch (widgets.radio_choice) {
        .alpha => "w-radio-a",
        .beta => "w-radio-b",
        .gamma => "w-radio-c",
    };
    var radio_node = try widget_kit.radioGroupList(
        allocator,
        "w-radio",
        radio_opts[0..],
        selected_radio_id,
        .none,
        common_interactive,
    );
    switch (radio_node) {
        .list => |*l| l.height = radio_opts.len,
        else => {},
    }
    try children.append(allocator, .{ .text = .{ .id = "w-sec-radio", .h = 1, .style = dim_style, .text = "Radio group (list-based):" } });
    try children.append(allocator, radio_node);

    const tabs_spec = [_]widget_kit.Tab{
        .{ .id = "w-tab-one", .label = "One" },
        .{ .id = "w-tab-two", .label = "Two" },
        .{ .id = "w-tab-three", .label = "Three" },
    };
    const active_tab_id: []const u8 = switch (widgets.active_tab) {
        .one => "w-tab-one",
        .two => "w-tab-two",
        .three => "w-tab-three",
    };
    const tab_text: []const u8 = switch (widgets.active_tab) {
        .one => "Tab one content",
        .two => "Tab two content",
        .three => "Tab three content",
    };
    var tab_body_children = [_]protocol.Node{.{ .text = .{ .id = "w-tab-body-text", .text = tab_text } }};
    const tab_body = protocol.Node{ .vbox = .{ .id = "w-tab-body", .clip = true, .children = tab_body_children[0..] } };
    const tabs_node = try widget_kit.tabs(allocator, "w-tabs", tabs_spec[0..], active_tab_id, tab_body);
    try children.append(allocator, .{ .text = .{ .id = "w-sec-tabs", .h = 1, .style = dim_style, .text = "Tabs (buttons + content):" } });
    try children.append(allocator, tabs_node);

    const table_cols = [_]widget_kit.TableColumn{
        .{ .id = "w-table-col-id", .label = "ID", .width = 4 },
        .{ .id = "w-table-col-name", .label = "Name", .width = 10 },
        .{ .id = "w-table-col-status", .label = "Status", .width = 8 },
    };
    const row1_cells = [_][]const u8{ "1", "Alpha", "ok" };
    const row2_cells = [_][]const u8{ "2", "Beta", "warn" };
    const row3_cells = [_][]const u8{ "3", "Gamma", "err" };
    const table_rows = [_]widget_kit.TableRow{
        .{ .id = "w-table-row-1", .cells = row1_cells[0..] },
        .{ .id = "w-table-row-2", .cells = row2_cells[0..] },
        .{ .id = "w-table-row-3", .cells = row3_cells[0..] },
    };
    const table_node = try widget_kit.table(allocator, "w-table", table_cols[0..], table_rows[0..], 4, common_interactive);
    try children.append(allocator, .{ .text = .{ .id = "w-sec-table", .h = 1, .style = dim_style, .text = "Table (header + scroll->list):" } });
    try children.append(allocator, table_node);

    var tree_rows: std.ArrayList(widget_kit.TreeRow) = .empty;
    try tree_rows.append(allocator, .{
        .id = "w-tree-root",
        .depth = 0,
        .has_children = true,
        .expanded = widgets.tree_root_expanded,
        .label = "project",
    });
    if (widgets.tree_root_expanded) {
        try tree_rows.append(allocator, .{
            .id = "w-tree-src",
            .depth = 1,
            .has_children = true,
            .expanded = widgets.tree_src_expanded,
            .label = "src/",
        });
        if (widgets.tree_src_expanded) {
            try tree_rows.append(allocator, .{ .id = "w-tree-src-main", .depth = 2, .label = "main.zig" });
            try tree_rows.append(allocator, .{ .id = "w-tree-src-ui", .depth = 2, .label = "ui/mod.zig" });
        }
        try tree_rows.append(allocator, .{
            .id = "w-tree-lib",
            .depth = 1,
            .has_children = true,
            .expanded = widgets.tree_lib_expanded,
            .label = "src/lib/",
        });
        if (widgets.tree_lib_expanded) {
            try tree_rows.append(allocator, .{ .id = "w-tree-lib-protocol", .depth = 2, .label = "protocol/" });
        }
        try tree_rows.append(allocator, .{
            .id = "w-tree-tests",
            .depth = 1,
            .has_children = true,
            .expanded = widgets.tree_tests_expanded,
            .label = "src/test/",
        });
        if (widgets.tree_tests_expanded) {
            try tree_rows.append(allocator, .{ .id = "w-tree-tests-tests", .depth = 2, .label = "tests.zig" });
        }
    }
    const tree_node = try widget_kit.tree(allocator, "w-tree", tree_rows.items, 6, common_interactive);
    try children.append(allocator, .{ .text = .{ .id = "w-sec-tree", .h = 1, .style = dim_style, .text = "Tree (scroll->list, activate toggles expand):" } });
    try children.append(allocator, tree_node);

    var textarea_node = widget_kit.textarea("w-textarea", "Textarea (multiline)…", .{
        .hoverable = true,
        .mouseable = true,
        .validation = .success,
    });
    switch (textarea_node) {
        .textarea => |*t| t.h = 5,
        else => {},
    }
    var textarea_ro = widget_kit.textarea("w-textarea-ro", "Readonly textarea…", .{
        .hoverable = true,
        .mouseable = true,
        .readonly = true,
        .validation = .warning,
    });
    switch (textarea_ro) {
        .textarea => |*t| t.h = 3,
        else => {},
    }
    try children.append(allocator, .{ .text = .{ .id = "w-sec-textarea", .h = 1, .style = dim_style, .text = "Textarea (runtime state):" } });
    try children.append(allocator, textarea_node);
    try children.append(allocator, textarea_ro);

    var controlled_input_buf: [96]u8 = undefined;
    const controlled_input_value = try std.fmt.bufPrint(
        &controlled_input_buf,
        "backend controlled tick={d}",
        .{tick},
    );
    const controlled_selected_id: []const u8 = if ((tick % 2) == 0) "w-ctl-item-a" else "w-ctl-item-b";

    var controlled_list_children = [_]protocol.Node{
        .{ .text = .{ .id = "w-ctl-item-a", .text = "Controlled item A" } },
        .{ .text = .{ .id = "w-ctl-item-b", .text = "Controlled item B" } },
    };
    const controlled_list = protocol.Node{ .list = .{
        .id = "w-controlled-list",
        .hoverable = true,
        .mouseable = true,
        .height = 2,
        .state_mode = .controlled,
        .selected_id = controlled_selected_id,
        .scroll = 0,
        .children = controlled_list_children[0..],
    } };

    var controlled_scroll_text_buf: [160]u8 = undefined;
    const controlled_scroll_text = try std.fmt.bufPrint(
        &controlled_scroll_text_buf,
        "line 1\nline 2\nline 3\nline 4\nline 5\ny={d}",
        .{@as(usize, @intCast((tick / 2) % 4))},
    );
    const controlled_scroll_child = try allocator.create(protocol.Node);
    controlled_scroll_child.* = .{
        .text = .{
            .id = "w-controlled-scroll-body",
            .text = controlled_scroll_text,
        },
    };
    const controlled_scroll = protocol.Node{ .scroll = .{
        .id = "w-controlled-scroll",
        .h = 3,
        .mouseable = true,
        .state_mode = .controlled,
        .scroll_y = @as(usize, @intCast((tick / 2) % 4)),
        .child = controlled_scroll_child,
    } };

    var controlled_row_children = try allocator.alloc(protocol.Node, 3);
    controlled_row_children[0] = .{ .input = .{
        .id = "w-controlled-input",
        .state_mode = .controlled,
        .value = controlled_input_value,
        .cursor = controlled_input_value.len,
        .placeholder = "backend controlled",
        .hoverable = true,
        .mouseable = true,
    } };
    controlled_row_children[1] = controlled_list;
    controlled_row_children[2] = controlled_scroll;
    try children.append(allocator, .{
        .text = .{
            .id = "w-sec-controlled",
            .h = 1,
            .style = dim_style,
            .text = "Controlled state demo (state_mode=controlled): backend drives input/list/scroll each tick",
        },
    });
    try children.append(allocator, .{ .hbox = .{ .id = "w-controlled-row", .gap = 1, .children = controlled_row_children } });

    const percent: usize = @intCast(tick % 101);
    const progress = try widget_kit.progressBar(allocator, "w-progress", 12, percent, .{});
    const spin = widget_kit.spinner("w-spinner", @intCast(tick), .{});
    var prog_children = try allocator.alloc(protocol.Node, 3);
    prog_children[0] = spin;
    prog_children[1] = progress;
    var prog_label_buf: [64]u8 = undefined;
    const prog_label = try std.fmt.bufPrint(&prog_label_buf, " tick={d}", .{tick});
    prog_children[2] = .{ .text = .{ .id = "w-progress-label", .text = prog_label, .style = dim_style } };
    try children.append(allocator, .{ .text = .{ .id = "w-sec-progress", .h = 1, .style = dim_style, .text = "Progress / spinner:" } });
    try children.append(allocator, .{ .hbox = .{ .id = "w-progress-row", .gap = 1, .children = prog_children } });

    const body_children = try children.toOwnedSlice(allocator);
    const body = protocol.Node{ .vbox = .{
        .id = "panel-widgets-body",
        .gap = 1,
        .clip = true,
        .style = body_style,
        .children = body_children,
    } };

    const body_ptr = try allocator.create(protocol.Node);
    body_ptr.* = body;

    const scroll = protocol.Node{ .scroll = .{
        .id = "panel-widgets-scroll",
        .flex = 1,
        .mouseable = true,
        .focusable = false,
        .child = body_ptr,
    } };
    const scroll_ptr = try allocator.create(protocol.Node);
    scroll_ptr.* = scroll;

    const box = protocol.Node{ .box = .{
        .id = "panel-widgets",
        .flex = 1,
        .pad = 1,
        .clip = true,
        .focus_scope = focus_scope,
        .style = panel_style,
        .title = "Widgets",
        .child = scroll_ptr,
    } };

    try protocol.writeNodeJson(writer, box);
}

fn writeRootNode(
    allocator: std.mem.Allocator,
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    md_stream_node: protocol.Node,
    md_stream_title: []const u8,
    md_stream_hint: []const u8,
    md_speed_faster_label: []const u8,
    md_speed_slower_label: []const u8,
    md_speed_chunk_smaller_label: []const u8,
    md_speed_chunk_larger_label: []const u8,
    inputs: []const state.InputSlot,
    lists: []const state.ListSlot,
    layout_alt: bool,
    list_height: usize,
    popups: state.PopupInfo,
    widgets: state.WidgetsState,
    tick: u64,
) !void {
    try writer.writeAll("{\"type\":\"overlay\",\"id\":\"root\",\"base\":");
    try writer.writeAll("{\"type\":\"vbox\",\"id\":\"root-base\",\"style\":{\"bg\":\"#020617\",\"fg\":\"#e2e8f0\"},\"children\":[");
    try writeTextNodeLayoutStyled(writer, "title", "Tracer Demo", null, 1, 0, "{\"bold\":true,\"fg\":\"brightwhite\"}");
    try writer.writeByte(',');
    try writeTextNodeLayoutStyled(
        writer,
        "hint",
        "Unicode demo: e\u{0301} 漢 🇯🇵 👩‍👩‍👧‍👦 🧑‍💻\nTabs expand to configured stops (TUI_TAB_WIDTH, default 4). Ambiguous-width policy: TUI_UNICODE_AMBIGUOUS_WIDTH=narrow|wide.\nTab/Shift-Tab cycle within the current focus scope. '[' and ']' jump across scopes.\nMouse: click input/list to focus; click list row to select; wheel over list scrolls.\nArrows/Home/End edit inputs. Alt-b/Alt-f word jump. j/k moves list. Enter activates. q toggles. x or Ctrl-C exits.\nEmergency exit chord: Ctrl-G then Ctrl-G (restores terminal and exits immediately).\nMake the terminal narrow to see this line soft-wrap on typical widths without any backend changes.",
        null,
        3,
        0,
        "{\"fg\":\"#94a3b8\",\"dim\":true}",
    );
    try writer.writeByte(',');
    try writeTextNodeLayoutStyled(writer, "clock", tick_text, null, 1, 0, "{\"fg\":\"#22c55e\",\"bold\":true}");
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"popups\",\"mouseable\":true,\"height\":3,\"children\":[");
    try writeTextNode(writer, "popup-open-modal", "Popups: open modal");
    try writer.writeByte(',');
    try writeTextNode(writer, "popup-open-dropdown", "Popups: open dropdown");
    try writer.writeByte(',');
    try writeTextNode(writer, "popup-toggle-tooltip", "Popups: toggle tooltip");
    try writer.writeAll("]}");
    try writer.writeByte(',');
    const rich_md =
        "Status: **Connected**  (latency `42ms`)  — inline spans wrap across style boundaries when narrow";
    const rich_style: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 0xE5, .g = 0xE7, .b = 0xEB } } };
    const rich_spans = try markdown.compileInlineSpansLeaky(allocator, rich_md, .{ .own_text = false });
    try protocol.writeNodeJson(writer, .{
        .styled_text = .{
            .id = "rich",
            .h = 1,
            .style = rich_style,
            .spans = rich_spans,
        },
    });
    try writer.writeByte(',');
    const md_demo =
        "# Markdown demo\n" ++
        "- Tab cycles focus\n" ++
        "- Mouse: click to focus; wheel to scroll\n" ++
        "> Tip: Try **bold**, *italic*, and `code`.";
    const md_doc = try markdown.compileLeaky(
        allocator,
        md_demo,
        .{ .id = "md-demo", .id_prefix = "md-demo", .own_text = false },
    );
    var md_wrap_children = try allocator.alloc(protocol.Node, 1);
    md_wrap_children[0] = md_doc;
    try protocol.writeNodeJson(writer, .{
        .vbox = .{
            .id = "md-demo-wrap",
            .h = 5,
            .clip = true,
            .focus_scope = "scope-md",
            .children = md_wrap_children,
        },
    });
    try writer.writeByte(',');
    try writeGridPlacementPrecedenceDemoNode(writer);
    try writer.writeByte(',');

    // Placeholder container for Tracer 18 (backend-streamed markdown).
    // Use flex so the streaming output gets real vertical space.
    try writer.writeAll("{\"type\":\"box\",\"id\":\"md-stream-wrap\",\"focus_scope\":\"scope-md\",\"flex\":1,\"pad\":1,\"clip\":true");
    try writer.writeAll(",\"style\":{\"bg\":\"#0b1220\",\"fg\":\"#34d399\"}");
    try writer.writeAll(",\"title\":");
    try protocol.writeJsonString(writer, md_stream_title);
    try writer.writeAll(",\"child\":{\"type\":\"vbox\",\"id\":\"md-stream-body\",\"clip\":true,\"style\":{\"fg\":\"#e5e7eb\"},\"children\":[");
    try writeTextNodeLayoutStyled(
        writer,
        "md-stream-hint",
        md_stream_hint,
        null,
        1,
        0,
        "{\"fg\":\"#94a3b8\",\"dim\":true}",
    );
    try writer.writeByte(',');
    try writeInputNodeLayoutStyled(
        writer,
        "md-prompt",
        "Type markdown here (single line)…",
        null,
        1,
        0,
        "{\"fg\":\"#f9fafb\"}",
        "{\"fg\":\"gray\",\"dim\":true}",
        false,
        true,
    );
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"md-actions\",\"mouseable\":true,\"height\":3,\"children\":[");
    try writeTextNode(writer, "md-actions-start", "Start streaming");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-actions-pause", "Pause / resume");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-actions-reset", "Reset");
    try writer.writeAll("]}");
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"md-mode\",\"mouseable\":true,\"height\":3,\"children\":[");
    try writeTextNode(writer, "md-mode-18", "Mode: Tracer 18 (full recompile)");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-mode-19a", "Mode: Tracer 19A (finalize blocks)");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-mode-19b", "Mode: Tracer 19B (inline tail)");
    try writer.writeAll("]}");
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"md-speed\",\"mouseable\":true,\"height\":4,\"children\":[");
    try writeTextNode(writer, "md-speed-faster", md_speed_faster_label);
    try writer.writeByte(',');
    try writeTextNode(writer, "md-speed-slower", md_speed_slower_label);
    try writer.writeByte(',');
    try writeTextNode(writer, "md-speed-chunk-smaller", md_speed_chunk_smaller_label);
    try writer.writeByte(',');
    try writeTextNode(writer, "md-speed-chunk-larger", md_speed_chunk_larger_label);
    try writer.writeAll("]}");
    try writer.writeByte(',');

    // Streaming subtree is owned by the backend, and is also patched independently.
    var md_stream_node_local = md_stream_node;
    switch (md_stream_node_local) {
        .vbox => |*v| {
            v.flex = 0;
            v.clip = false;
        },
        else => {},
    }
    try writer.writeAll("{\"type\":\"scroll\",\"id\":\"md-scroll\",\"mouseable\":true,\"flex\":1,\"child\":");
    try protocol.writeNodeJson(writer, md_stream_node_local);
    try writer.writeByte('}');
    try writer.writeAll("]}}");
    try writer.writeByte(',');

    try writer.writeAll("{\"type\":\"hbox\",\"id\":\"body\",\"flex\":2,\"pad\":1,\"clip\":true,\"children\":[");
    if (!layout_alt) {
        try writePanelNode(
            writer,
            "panel-a",
            "scope-left",
            "Panel A",
            "#93c5fd",
            inputs[0].id,
            lists[0].id,
            list_height,
            lists[0].items.items,
        );
        try writer.writeByte(',');
        try writePanelNode(
            writer,
            "panel-b",
            "scope-right",
            "Panel B",
            "#c4b5fd",
            inputs[1].id,
            lists[1].id,
            list_height,
            lists[1].items.items,
        );
    } else {
        try writePanelNode(
            writer,
            "panel-b",
            "scope-right",
            "Panel B",
            "#c4b5fd",
            inputs[1].id,
            lists[1].id,
            list_height,
            lists[1].items.items,
        );
        try writer.writeByte(',');
        try writePanelNode(
            writer,
            "panel-a",
            "scope-left",
            "Panel A",
            "#93c5fd",
            inputs[0].id,
            lists[0].id,
            list_height,
            lists[0].items.items,
        );
    }
    try writer.writeByte(',');
    try writeAlignmentPanelNode(writer, "scope-align");
    try writer.writeByte(',');
    try writeWidgetsPanelNode(allocator, writer, "scope-widgets", widgets, tick);
    try writer.writeAll("]}");

    try writer.writeByte(',');
    try writeTextNodeLayoutStyled(writer, "status", status_text, null, 1, 0, "{\"fg\":\"#fbbf24\"}");
    try writer.writeAll("]}"); // end base

    try writer.writeAll(",\"layers\":[");
    var wrote_any: bool = false;

    if (popups.dropdown_open) {
        wrote_any = true;
        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"box\",\"id\":\"dropdown-box\",\"shadow\":true,\"hoverable\":true,\"mouseable\":true");
        try writer.writeAll(",\"style\":{\"bg\":\"#111827\",\"fg\":\"#fbbf24\"}");
        try writer.writeAll(",\"child\":");
        try writer.writeAll("{\"type\":\"list\",\"id\":\"dropdown\",\"hoverable\":true,\"mouseable\":true,\"marker\":\"none\",\"height\":4,\"style\":{\"fg\":\"#e5e7eb\"},\"children\":[");
        try writeTextNode(writer, "dropdown-a", "Dropdown: option A");
        try writer.writeByte(',');
        try writeTextNode(writer, "dropdown-b", "Dropdown: option B");
        try writer.writeByte(',');
        try writeTextNode(writer, "dropdown-c", "Dropdown: option C");
        try writer.writeByte(',');
        try writeTextNode(writer, "dropdown-close", "Close dropdown");
        try writer.writeAll("]}");
        try writer.writeAll("}");
        try writer.writeAll(",\"anchor\":\"query-a\",\"placement\":\"below\",\"align\":\"start\",\"w\":28,\"modal\":true}");
    }

    if (widgets.menu_open) {
        if (wrote_any) try writer.writeByte(',') else wrote_any = true;

        const anchor_id: []const u8 = switch (widgets.menu_anchor) {
            .file => "w-menu-file",
            .help => "w-menu-help",
        };

        var item_nodes: [4]protocol.Node = undefined;
        var item_count: usize = 0;
        if (widgets.menu_anchor == .file) {
            item_nodes[item_count] = .{ .text = .{ .id = "w-menu-new", .text = "New" } };
            item_count += 1;
            item_nodes[item_count] = .{ .text = .{ .id = "w-menu-open", .text = "Open" } };
            item_count += 1;
            item_nodes[item_count] = .{ .text = .{ .id = "w-menu-quit", .text = "Quit" } };
            item_count += 1;
            item_nodes[item_count] = .{ .text = .{ .id = "w-menu-close", .text = "Close menu" } };
            item_count += 1;
        } else {
            item_nodes[item_count] = .{ .text = .{ .id = "w-menu-about", .text = "About" } };
            item_count += 1;
            item_nodes[item_count] = .{ .text = .{ .id = "w-menu-close", .text = "Close menu" } };
            item_count += 1;
        }

        const menu_list_style: style.StyleOverride = .{
            .fg = .{ .rgb = .{ .r = 0xE5, .g = 0xE7, .b = 0xEB } },
        };
        const menu_box_style: style.StyleOverride = .{
            .bg = .{ .rgb = .{ .r = 0x11, .g = 0x18, .b = 0x27 } },
            .fg = .{ .rgb = .{ .r = 0xFB, .g = 0xBF, .b = 0x24 } },
        };

        var menu_list = protocol.Node{ .list = .{
            .id = "w-menu-list",
            .height = item_count,
            .hoverable = true,
            .mouseable = true,
            .marker = .none,
            .style = menu_list_style,
            .children = item_nodes[0..item_count],
        } };
        const menu_box = protocol.Node{ .box = .{
            .id = "w-menu-box",
            .pad = 1,
            .shadow = true,
            .style = menu_box_style,
            .child = &menu_list,
        } };

        try writer.writeAll("{\"node\":");
        try protocol.writeNodeJson(writer, menu_box);
        try writer.writeAll(",\"anchor\":");
        try protocol.writeJsonString(writer, anchor_id);
        try writer.writeAll(",\"placement\":\"below\",\"align\":\"start\",\"w\":24,\"modal\":true}");
    }

    if (popups.tooltip_on) {
        if (wrote_any) try writer.writeByte(',') else wrote_any = true;
        const anchor = if (popups.tooltip_anchor.len > 0) popups.tooltip_anchor else "title";
        var tip_buf: [128]u8 = undefined;
        const tip_text = try std.fmt.bufPrint(&tip_buf, "Tooltip for: {s}", .{anchor});
        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"box\",\"id\":\"tooltip-box\",\"shadow\":true");
        try writer.writeAll(",\"style\":{\"bg\":\"#111827\",\"fg\":\"#fbbf24\"}");
        try writer.writeAll(",\"child\":");
        try writer.writeAll("{\"type\":\"text\",\"id\":\"tooltip\",\"style\":{\"fg\":\"#e5e7eb\"},\"text\":");
        try protocol.writeJsonString(writer, tip_text);
        try writer.writeAll("}}");
        try writer.writeAll(",\"anchor\":");
        try protocol.writeJsonString(writer, anchor);
        try writer.writeAll(",\"placement\":\"right\",\"align\":\"center\",\"offset_x\":1,\"w\":26}");
    }

    if (popups.hover_id.len > 0) {
        if (wrote_any) try writer.writeByte(',') else wrote_any = true;
        var hovered_buf: [192]u8 = undefined;
        const hovered_text = try std.fmt.bufPrint(&hovered_buf, "Hovered: {s}", .{popups.hover_id});
        var item_buf: [192]u8 = undefined;
        const item_text: ?[]const u8 = if (popups.hover_item.len > 0)
            try std.fmt.bufPrint(&item_buf, "Item: {s}", .{popups.hover_item})
        else
            null;

        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"box\",\"id\":\"hover-tip-box\",\"shadow\":true");
        try writer.writeAll(",\"style\":{\"bg\":\"#111827\",\"fg\":\"#fbbf24\"}");
        try writer.writeAll(",\"child\":");
        try writer.writeAll("{\"type\":\"vbox\",\"id\":\"hover-tip\",\"clip\":true,\"children\":[");
        try writer.writeAll("{\"type\":\"text\",\"id\":\"hover-tip-hovered\",\"h\":1");
        try writer.writeAll(",\"style\":{\"fg\":\"#e5e7eb\"},\"text\":");
        try protocol.writeJsonString(writer, hovered_text);
        try writer.writeAll("}");
        if (item_text) |it| {
            try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"text\",\"id\":\"hover-tip-item\",\"h\":1");
            try writer.writeAll(",\"style\":{\"fg\":\"#94a3b8\",\"dim\":true},\"text\":");
            try protocol.writeJsonString(writer, it);
            try writer.writeAll("}");
        }
        try writer.writeAll("]}}");
        try writer.writeAll(",\"anchor\":");
        try protocol.writeJsonString(writer, popups.hover_id);
        try writer.writeAll(",\"placement\":\"right\",\"align\":\"center\",\"offset_x\":1,\"w\":34}");
    }

    if (popups.modal_open) {
        if (wrote_any) try writer.writeByte(',') else wrote_any = true;
        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"box\",\"id\":\"modal\",\"pad\":1,\"clip\":true,\"shadow\":true");
        try writer.writeAll(",\"style\":{\"bg\":\"#111827\",\"fg\":\"#fbbf24\"}");
        try writer.writeAll(",\"title\":");
        try protocol.writeJsonString(writer, "Modal dialog (focus is trapped)");
        try writer.writeAll(",\"child\":{\"type\":\"vbox\",\"id\":\"modal-body\",\"clip\":true,\"style\":{\"fg\":\"#e5e7eb\"},\"children\":[");
        try writeInputNodeLayoutStyled(
            writer,
            "modal-input",
            "Type in modal…",
            null,
            1,
            0,
            "{\"fg\":\"#f9fafb\"}",
            "{\"fg\":\"gray\",\"dim\":true}",
            false,
            true,
        );
        try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"list\",\"id\":\"modal-actions\",\"mouseable\":true,\"height\":1,\"style\":{\"fg\":\"#e5e7eb\"},\"children\":[");
        try writeTextNode(writer, "modal-close", "Close modal");
        try writer.writeAll("]}");
        try writer.writeAll("]}}");
        try writer.writeAll(",\"placement\":\"center\",\"modal\":true,\"w\":56}");
    }

    try writer.writeAll("]}"); // end overlay
}

fn writeGridPlacementPrecedenceDemoNode(writer: anytype) !void {
    try writer.writeAll("{\"type\":\"box\",\"id\":\"grid-precedence-wrap\",\"h\":6,\"pad\":1");
    try writer.writeAll(",\"title\":\"Grid precedence (explicit row/col > area)\"");
    try writer.writeAll(",\"style\":{\"fg\":\"#a7f3d0\"}");
    try writer.writeAll(",\"child\":");
    try writer.writeAll("{\"type\":\"grid\",\"id\":\"grid-precedence\",\"rows\":[1,1],\"cols\":[20,20],");
    try writer.writeAll("\"areas\":[\"left right\",\"left right\"],\"gap_x\":1,\"children\":[");
    try writer.writeAll("{\"type\":\"text\",\"id\":\"grid-area-left\",\"grid_area\":\"left\",\"text\":\"area:left\"},");
    try writer.writeAll("{\"type\":\"text\",\"id\":\"grid-area-right\",\"grid_area\":\"right\",\"text\":\"area:right\"},");
    try writer.writeAll(
        "{\"type\":\"text\",\"id\":\"grid-explicit-overrides-area\",\"grid_area\":\"left\",\"grid_row\":1,\"grid_col\":1,\"text\":\"explicit row=1,col=1\"}",
    );
    try writer.writeAll("]}}");
}

const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const style = tui.style;
const markdown = tui.markdown;

const state = @import("state.zig");

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
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"root\":");
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
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":\"root\",\"mode\":\"morph\",\"node\":");
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
    try writeInputNodeLayoutStyled(writer, id, placeholder, w, h, flex, null, null);
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
    try writer.writeAll(",\"placeholder\":");
    try protocol.writeJsonString(writer, placeholder);
    try writer.writeByte('}');
}

fn writeListNode(writer: anytype, id: []const u8, height: usize, items: []const u64) !void {
    try writer.writeAll("{\"type\":\"list\",\"id\":");
    try protocol.writeJsonString(writer, id);
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
    try writeListNode(writer, list_id, height, items);
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
    title_id: []const u8,
    title: []const u8,
    input_id: []const u8,
    list_id: []const u8,
    list_height: usize,
    items: []const u64,
) !void {
    try writer.writeAll("{\"type\":\"vbox\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"flex\":1,\"pad\":1,\"clip\":true");
    try writer.writeAll(",\"style\":{\"bg\":\"#0b1220\",\"fg\":\"#e5e7eb\"}");
    try writer.writeAll(",\"children\":[");
    try writeTextNodeLayoutStyled(writer, title_id, title, null, 1, 0, "{\"bold\":true,\"fg\":\"brightwhite\"}");
    try writer.writeByte(',');
    try writeInputNodeLayoutStyled(
        writer,
        input_id,
        "Type here…",
        null,
        1,
        0,
        "{\"fg\":\"#f9fafb\"}",
        "{\"fg\":\"gray\",\"dim\":true}",
    );
    try writer.writeByte(',');
    try writeListNode(writer, list_id, list_height, items);
    try writer.writeAll("]}");
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
) !void {
    try writer.writeAll("{\"type\":\"overlay\",\"id\":\"root\",\"base\":");
    try writer.writeAll("{\"type\":\"vbox\",\"id\":\"root-base\",\"children\":[");
    try writeTextNodeLayoutStyled(writer, "title", "Tracer Demo", null, 1, 0, "{\"bold\":true,\"fg\":\"brightwhite\"}");
    try writer.writeByte(',');
    try writeTextNodeLayout(
        writer,
        "hint",
        "Unicode demo: e\u{0301} 漢 🇯🇵 👩‍👩‍👧‍👦\nTab cycles focus by tree order. Mouse: click input/list to focus; click list row to select; wheel over list scrolls.\nArrows/Home/End edit inputs. Alt-b/Alt-f word jump. j/k moves list. Enter activates. q toggles. x or Ctrl-C exits.\nEmergency exit chord: Ctrl-G then Ctrl-G (restores terminal and exits immediately).\nMake the terminal narrow to see this line soft-wrap on typical widths without any backend changes.",
        null,
        3,
        0,
    );
    try writer.writeByte(',');
    try writeTextNodeLayoutStyled(writer, "clock", tick_text, null, 1, 0, "{\"fg\":\"#22c55e\",\"bold\":true}");
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"popups\",\"height\":3,\"children\":[");
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
            .children = md_wrap_children,
        },
    });
    try writer.writeByte(',');

    // Placeholder container for Tracer 18 (backend-streamed markdown).
    // Use flex so the streaming output gets real vertical space.
    try writer.writeAll("{\"type\":\"vbox\",\"id\":\"md-stream-wrap\",\"flex\":1,\"pad\":1,\"clip\":true,\"children\":[");
    try writeTextNodeLayoutStyled(writer, "md-stream-title", md_stream_title, null, 1, 0, "{\"bold\":true}");
    try writer.writeByte(',');
    try writeTextNodeLayout(
        writer,
        "md-stream-hint",
        md_stream_hint,
        null,
        1,
        0,
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
    );
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"md-actions\",\"height\":3,\"children\":[");
    try writeTextNode(writer, "md-actions-start", "Start streaming");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-actions-pause", "Pause / resume");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-actions-reset", "Reset");
    try writer.writeAll("]}");
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"md-mode\",\"height\":3,\"children\":[");
    try writeTextNode(writer, "md-mode-18", "Mode: Tracer 18 (full recompile)");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-mode-19a", "Mode: Tracer 19A (finalize blocks)");
    try writer.writeByte(',');
    try writeTextNode(writer, "md-mode-19b", "Mode: Tracer 19B (inline tail)");
    try writer.writeAll("]}");
    try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"list\",\"id\":\"md-speed\",\"height\":4,\"children\":[");
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
    try writer.writeAll("{\"type\":\"scroll\",\"id\":\"md-scroll\",\"flex\":1,\"child\":");
    try protocol.writeNodeJson(writer, md_stream_node_local);
    try writer.writeByte('}');
    try writer.writeAll("]}");
    try writer.writeByte(',');

    try writer.writeAll("{\"type\":\"hbox\",\"id\":\"body\",\"flex\":2,\"pad\":1,\"clip\":true,\"children\":[");
    if (!layout_alt) {
        try writePanelNode(
            writer,
            "panel-a",
            "panel-a-title",
            "Panel A",
            inputs[0].id,
            lists[0].id,
            list_height,
            lists[0].items.items,
        );
        try writer.writeByte(',');
        try writePanelNode(
            writer,
            "panel-b",
            "panel-b-title",
            "Panel B",
            inputs[1].id,
            lists[1].id,
            list_height,
            lists[1].items.items,
        );
    } else {
        try writePanelNode(
            writer,
            "panel-b",
            "panel-b-title",
            "Panel B",
            inputs[1].id,
            lists[1].id,
            list_height,
            lists[1].items.items,
        );
        try writer.writeByte(',');
        try writePanelNode(
            writer,
            "panel-a",
            "panel-a-title",
            "Panel A",
            inputs[0].id,
            lists[0].id,
            list_height,
            lists[0].items.items,
        );
    }
    try writer.writeAll("]}");

    try writer.writeByte(',');
    try writeTextNodeLayoutStyled(writer, "status", status_text, null, 1, 0, "{\"fg\":\"#fbbf24\"}");
    try writer.writeAll("]}"); // end base

    try writer.writeAll(",\"layers\":[");
    var wrote_any: bool = false;

    if (popups.dropdown_open) {
        wrote_any = true;
        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"list\",\"id\":\"dropdown\",\"height\":4,\"children\":[");
        try writeTextNode(writer, "dropdown-a", "Dropdown: option A");
        try writer.writeByte(',');
        try writeTextNode(writer, "dropdown-b", "Dropdown: option B");
        try writer.writeByte(',');
        try writeTextNode(writer, "dropdown-c", "Dropdown: option C");
        try writer.writeByte(',');
        try writeTextNode(writer, "dropdown-close", "Close dropdown");
        try writer.writeAll("]}");
        try writer.writeAll(",\"anchor\":\"query-a\",\"placement\":\"below\",\"align\":\"start\",\"w\":28}");
    }

    if (popups.tooltip_on) {
        if (wrote_any) try writer.writeByte(',') else wrote_any = true;
        const anchor = if (popups.tooltip_anchor.len > 0) popups.tooltip_anchor else "title";
        var tip_buf: [128]u8 = undefined;
        const tip_text = try std.fmt.bufPrint(&tip_buf, "Tooltip for: {s}", .{anchor});
        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"text\",\"id\":\"tooltip\",\"text\":");
        try protocol.writeJsonString(writer, tip_text);
        try writer.writeAll("}");
        try writer.writeAll(",\"anchor\":");
        try protocol.writeJsonString(writer, anchor);
        try writer.writeAll(",\"placement\":\"right\",\"align\":\"center\",\"offset_x\":1,\"w\":26}");
    }

    if (popups.modal_open) {
        if (wrote_any) try writer.writeByte(',') else wrote_any = true;
        try writer.writeAll("{\"node\":");
        try writer.writeAll("{\"type\":\"vbox\",\"id\":\"modal\",\"pad\":1,\"clip\":true,\"style\":{\"bg\":\"#111827\",\"fg\":\"#e5e7eb\"},\"children\":[");
        try writeTextNodeLayoutStyled(writer, "modal-title", "Modal dialog (focus is trapped)", null, 1, 0, "{\"bold\":true}");
        try writer.writeByte(',');
        try writeInputNodeLayoutStyled(
            writer,
            "modal-input",
            "Type in modal…",
            null,
            1,
            0,
            "{\"fg\":\"#f9fafb\"}",
            "{\"fg\":\"gray\",\"dim\":true}",
        );
        try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"list\",\"id\":\"modal-actions\",\"height\":1,\"children\":[");
        try writeTextNode(writer, "modal-close", "Close modal");
        try writer.writeAll("]}");
        try writer.writeAll("]}");
        try writer.writeAll(",\"placement\":\"center\",\"modal\":true,\"w\":56}");
    }

    try writer.writeAll("]}"); // end overlay
}

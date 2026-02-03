const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;

const state = @import("state.zig");

pub fn emitInitialFull(
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    inputs: []const state.InputSlot,
    lists: []const state.ListSlot,
    list_height: usize,
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"root\":");
    try writeRootNode(writer, tick_text, status_text, inputs, lists, false, list_height);
    try writer.writeAll("}\n");
}

pub fn emitRootMorphPatch(
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    inputs: []const state.InputSlot,
    lists: []const state.ListSlot,
    layout_alt: bool,
    list_height: usize,
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":\"root\",\"mode\":\"morph\",\"node\":");
    try writeRootNode(writer, tick_text, status_text, inputs, lists, layout_alt, list_height);
    try writer.writeAll("}\n");
}

fn writeTextNode(writer: anytype, id: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeByte('}');
}

fn writeTextNodeLayout(
    writer: anytype,
    id: []const u8,
    text: []const u8,
    w: ?usize,
    h: ?usize,
    flex: usize,
) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
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
    try writer.writeAll("{\"type\":\"input\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
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

pub fn emitTextPatchById(writer: anytype, target: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"node\":{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"h\":1");
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
    try writer.writeAll(",\"flex\":1,\"pad\":1,\"clip\":true,\"children\":[");
    try writeTextNodeLayout(writer, title_id, title, null, 1, 0);
    try writer.writeByte(',');
    try writeInputNodeLayout(writer, input_id, "Type here…", null, 1, 0);
    try writer.writeByte(',');
    try writeListNode(writer, list_id, list_height, items);
    try writer.writeAll("]}");
}

fn writeRootNode(
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    inputs: []const state.InputSlot,
    lists: []const state.ListSlot,
    layout_alt: bool,
    list_height: usize,
) !void {
    try writer.writeAll("{\"type\":\"vbox\",\"id\":\"root\",\"children\":[");
    try writeTextNodeLayout(writer, "title", "Tracer Demo", null, 1, 0);
    try writer.writeByte(',');
    try writeTextNodeLayout(
        writer,
        "hint",
        "Unicode demo: e\u{0301} 漢 🇯🇵 👩‍👩‍👧‍👦\nTab cycles focus by tree order. Mouse: click input/list to focus; click list row to select; wheel over list scrolls.\nArrows/Home/End edit inputs. Alt-b/Alt-f word jump. j/k moves list. Enter activates. q toggles. x exits.\nMake the terminal narrow to see this line soft-wrap on typical widths without any backend changes.",
        null,
        3,
        0,
    );
    try writer.writeByte(',');
    try writeTextNodeLayout(writer, "clock", tick_text, null, 1, 0);
    try writer.writeByte(',');

    try writer.writeAll("{\"type\":\"hbox\",\"id\":\"body\",\"flex\":1,\"pad\":1,\"clip\":true,\"children\":[");
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
    try writeTextNodeLayout(writer, "status", status_text, null, 1, 0);
    try writer.writeAll("]}");
}

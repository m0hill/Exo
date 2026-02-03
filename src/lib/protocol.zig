const std = @import("std");
const style = @import("style.zig");

pub const Msg = union(enum) {
    patch: PatchMsg,
    event: EventMsg,
};

pub const PatchMsg = union(enum) {
    full: struct { root: Node },
    target: struct { target: []const u8, node: Node, mode: PatchMode = .replace },
};

pub const PatchMode = enum {
    replace,
    morph,
};

pub const EventMsg = union(enum) {
    key: struct { key: []const u8 },
    focus: struct { id: []const u8 },
    input: struct { id: []const u8, value: []const u8, cursor: usize },
    select: struct { id: []const u8, item: []const u8 },
    activate: struct { id: []const u8, item: []const u8 },
    resize: struct { rows: usize, cols: usize },
};

pub const Node = union(enum) {
    vbox: VBoxNode,
    hbox: HBoxNode,
    text: TextNode,
    styled_text: StyledTextNode,
    input: InputNode,
    list: ListNode,
};

pub const VBoxNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const HBoxNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const TextNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    style: ?style.StyleOverride = null,
    text: []const u8,
};

pub const Span = struct {
    text: []const u8,
    style: ?style.StyleOverride = null,
};

pub const StyledTextNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    style: ?style.StyleOverride = null,
    spans: []Span,
};

pub const InputNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    style: ?style.StyleOverride = null,
    placeholder_style: ?style.StyleOverride = null,
    placeholder: ?[]const u8 = null,
};

pub const ListNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    height: ?usize = null,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const ParseMsgError = error{
    InvalidJson,
    MissingField,
    WrongType,
    UnknownMsgType,
    UnknownNodeType,
    InvalidPatchShape,
    UnknownPatchMode,
    UnknownEventName,
    InvalidColor,
} || std.mem.Allocator.Error;

pub fn parseMsgLeaky(allocator: std.mem.Allocator, line: []const u8) ParseMsgError!Msg {
    const json = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch {
        return error.InvalidJson;
    };
    return parseMsgValueLeaky(allocator, json);
}

fn parseMsgValueLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!Msg {
    const obj = try asObject(v);
    const type_str = try getRequiredString(obj, "type");
    if (std.mem.eql(u8, type_str, "patch")) {
        if (obj.get("root")) |root_val| {
            if (obj.get("target") != null or obj.get("node") != null) return error.InvalidPatchShape;
            const root = try parseNodeLeaky(allocator, root_val);
            return .{ .patch = .{ .full = .{ .root = root } } };
        }

        if (obj.get("target") == null and obj.get("node") == null) return error.MissingField;
        if (obj.get("target") == null or obj.get("node") == null) return error.InvalidPatchShape;

        const target = try getRequiredString(obj, "target");
        const mode = try parsePatchMode(obj);
        const node_val = try getRequired(obj, "node");
        const node = try parseNodeLeaky(allocator, node_val);
        return .{ .patch = .{ .target = .{ .target = target, .node = node, .mode = mode } } };
    } else if (std.mem.eql(u8, type_str, "event")) {
        const name = try getRequiredString(obj, "name");
        if (std.mem.eql(u8, name, "key")) {
            const key = try getRequiredString(obj, "key");
            return .{ .event = .{ .key = .{ .key = key } } };
        } else if (std.mem.eql(u8, name, "focus")) {
            const id = try getRequiredString(obj, "id");
            return .{ .event = .{ .focus = .{ .id = id } } };
        } else if (std.mem.eql(u8, name, "input")) {
            const id = try getRequiredString(obj, "id");
            const value = try getRequiredString(obj, "value");
            const cursor_val = try getRequired(obj, "cursor");
            const cursor = switch (cursor_val) {
                .integer => |n| if (n < 0) return error.WrongType else @as(usize, @intCast(n)),
                else => return error.WrongType,
            };
            return .{ .event = .{ .input = .{ .id = id, .value = value, .cursor = cursor } } };
        } else if (std.mem.eql(u8, name, "select")) {
            const id = try getRequiredString(obj, "id");
            const item = try getRequiredString(obj, "item");
            return .{ .event = .{ .select = .{ .id = id, .item = item } } };
        } else if (std.mem.eql(u8, name, "activate")) {
            const id = try getRequiredString(obj, "id");
            const item = try getRequiredString(obj, "item");
            return .{ .event = .{ .activate = .{ .id = id, .item = item } } };
        } else if (std.mem.eql(u8, name, "resize")) {
            const rows = try getRequiredUsize(obj, "rows");
            const cols = try getRequiredUsize(obj, "cols");
            return .{ .event = .{ .resize = .{ .rows = rows, .cols = cols } } };
        } else {
            return error.UnknownEventName;
        }
    } else {
        return error.UnknownMsgType;
    }
}

fn parsePatchMode(obj: std.json.ObjectMap) ParseMsgError!PatchMode {
    const mode_val = obj.get("mode") orelse return .replace;
    const mode_str = switch (mode_val) {
        .string => |s| s,
        else => return error.WrongType,
    };
    if (std.mem.eql(u8, mode_str, "replace")) return .replace;
    if (std.mem.eql(u8, mode_str, "morph")) return .morph;
    return error.UnknownPatchMode;
}

fn parseNodeLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!Node {
    const obj = try asObject(v);
    const type_str = try getRequiredString(obj, "type");
    if (std.mem.eql(u8, type_str, "vbox")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const pad = try getOptionalUsize(obj, "pad") orelse 0;
        const clip = try getOptionalBool(obj, "clip") orelse false;
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .vbox = .{ .id = id, .w = w, .h = h, .flex = flex, .pad = pad, .clip = clip, .style = st, .children = out } };
    } else if (std.mem.eql(u8, type_str, "hbox")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const pad = try getOptionalUsize(obj, "pad") orelse 0;
        const clip = try getOptionalBool(obj, "clip") orelse false;
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .hbox = .{ .id = id, .w = w, .h = h, .flex = flex, .pad = pad, .clip = clip, .style = st, .children = out } };
    } else if (std.mem.eql(u8, type_str, "text")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const st = try getOptionalStyleOverride(obj, "style");
        const text = try getRequiredString(obj, "text");
        return .{ .text = .{ .id = id, .w = w, .h = h, .flex = flex, .style = st, .text = text } };
    } else if (std.mem.eql(u8, type_str, "styled_text")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const st = try getOptionalStyleOverride(obj, "style");
        const spans_val = try getRequired(obj, "spans");
        const spans_arr = try asArray(spans_val);
        var spans_out = try allocator.alloc(Span, spans_arr.items.len);
        for (spans_arr.items, 0..) |span_val, i| {
            spans_out[i] = try parseSpanLeaky(allocator, span_val);
        }
        return .{ .styled_text = .{ .id = id, .w = w, .h = h, .flex = flex, .style = st, .spans = spans_out } };
    } else if (std.mem.eql(u8, type_str, "input")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const st = try getOptionalStyleOverride(obj, "style");
        const ph_st = try getOptionalStyleOverride(obj, "placeholder_style");
        const placeholder = try getOptionalString(obj, "placeholder");
        return .{ .input = .{ .id = id, .w = w, .h = h, .flex = flex, .style = st, .placeholder_style = ph_st, .placeholder = placeholder } };
    } else if (std.mem.eql(u8, type_str, "list")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const height = try getOptionalUsize(obj, "height");
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .list = .{ .id = id, .w = w, .h = h, .flex = flex, .height = height, .style = st, .children = out } };
    } else {
        return error.UnknownNodeType;
    }
}

fn parseSpanLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!Span {
    _ = allocator;
    const obj = try asObject(v);
    const text = try getRequiredString(obj, "text");
    const st = try getOptionalStyleOverride(obj, "style");
    return .{ .text = text, .style = st };
}

fn asObject(v: std.json.Value) ParseMsgError!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.WrongType,
    };
}

fn asArray(v: std.json.Value) ParseMsgError!std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => error.WrongType,
    };
}

fn getOptionalStyleOverride(obj: std.json.ObjectMap, key: []const u8) ParseMsgError!?style.StyleOverride {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .object => |o| try parseStyleOverride(o),
        else => error.WrongType,
    };
}

fn parseStyleOverride(obj: std.json.ObjectMap) ParseMsgError!style.StyleOverride {
    var out: style.StyleOverride = .{};

    if (obj.get("fg")) |v| {
        out.fg = switch (v) {
            .null => .clear,
            .string => |s| .{ .rgb = style.parseColorSpec(s) catch return error.InvalidColor },
            else => return error.WrongType,
        };
    }

    if (obj.get("bg")) |v| {
        out.bg = switch (v) {
            .null => .clear,
            .string => |s| .{ .rgb = style.parseColorSpec(s) catch return error.InvalidColor },
            else => return error.WrongType,
        };
    }

    try parseOptionalBoolAttr(obj, "bold", &out, .bold);
    try parseOptionalBoolAttr(obj, "dim", &out, .dim);
    try parseOptionalBoolAttr(obj, "italic", &out, .italic);
    try parseOptionalBoolAttr(obj, "underline", &out, .underline);
    try parseOptionalBoolAttr(obj, "blink", &out, .blink);
    try parseOptionalBoolAttr(obj, "inverse", &out, .inverse);
    try parseOptionalBoolAttr(obj, "hidden", &out, .hidden);
    try parseOptionalBoolAttr(obj, "strikethrough", &out, .strikethrough);

    return out;
}

fn parseOptionalBoolAttr(obj: std.json.ObjectMap, key: []const u8, out: *style.StyleOverride, attr: style.Attr) ParseMsgError!void {
    const v = obj.get(key) orelse return;
    const b = switch (v) {
        .bool => |bb| bb,
        else => return error.WrongType,
    };
    out.setAttr(attr, b);
}

fn getRequired(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!std.json.Value {
    return obj.get(field) orelse error.MissingField;
}

fn getRequiredString(obj: std.json.ObjectMap, field: []const u8) ParseMsgError![]const u8 {
    const v = try getRequired(obj, field);
    return switch (v) {
        .string => |s| s,
        else => error.WrongType,
    };
}

fn getRequiredUsize(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!usize {
    const v = try getRequired(obj, field);
    return switch (v) {
        .integer => |n| if (n < 0) return error.WrongType else @as(usize, @intCast(n)),
        else => error.WrongType,
    };
}

fn getOptionalString(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?[]const u8 {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => error.WrongType,
    };
}

fn getOptionalUsize(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?usize {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .integer => |n| if (n < 0) return error.WrongType else @as(usize, @intCast(n)),
        else => error.WrongType,
    };
}

fn getOptionalBool(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?bool {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => error.WrongType,
    };
}

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (b < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{b});
                } else {
                    try writer.writeByte(b);
                }
            },
        }
    }
    try writer.writeByte('"');
}

pub fn writeEventJsonl(writer: anytype, key: []const u8) !void {
    return writeKeyEventJsonl(writer, key);
}

pub fn writeKeyEventJsonl(writer: anytype, key: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"key\",\"key\":");
    try writeJsonString(writer, key);
    try writer.writeAll("}\n");
}

pub fn writeFocusEventJsonl(writer: anytype, id: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"focus\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll("}\n");
}

pub fn writeInputEventJsonl(writer: anytype, id: []const u8, value: []const u8, cursor: usize) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"input\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"value\":");
    try writeJsonString(writer, value);
    try writer.print(",\"cursor\":{d}}}\n", .{cursor});
}

pub fn writeSelectEventJsonl(writer: anytype, id: []const u8, item: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"select\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"item\":");
    try writeJsonString(writer, item);
    try writer.writeAll("}\n");
}

pub fn writeActivateEventJsonl(writer: anytype, id: []const u8, item: []const u8) !void {
    try writer.writeAll("{\"type\":\"event\",\"name\":\"activate\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"item\":");
    try writeJsonString(writer, item);
    try writer.writeAll("}\n");
}

pub fn writeResizeEventJsonl(writer: anytype, rows: usize, cols: usize) !void {
    try writer.print("{{\"type\":\"event\",\"name\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n", .{ rows, cols });
}

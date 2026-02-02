const std = @import("std");

pub const Msg = union(enum) {
    patch: PatchMsg,
    event: EventMsg,
};

pub const PatchMsg = union(enum) {
    full: struct { root: Node },
    target: struct { target: []const u8, node: Node },
};

pub const EventMsg = union(enum) {
    key: struct { key: []const u8 },
    focus: struct { id: []const u8 },
    input: struct { id: []const u8, value: []const u8, cursor: usize },
};

pub const Node = union(enum) {
    vbox: VBoxNode,
    text: TextNode,
    input: InputNode,
};

pub const VBoxNode = struct {
    id: []const u8,
    children: []Node,
};

pub const TextNode = struct {
    id: []const u8,
    text: []const u8,
};

pub const InputNode = struct {
    id: []const u8,
    placeholder: ?[]const u8 = null,
};

pub const ParseMsgError = error{
    InvalidJson,
    MissingField,
    WrongType,
    UnknownMsgType,
    UnknownNodeType,
    InvalidPatchShape,
    UnknownEventName,
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
        const node_val = try getRequired(obj, "node");
        const node = try parseNodeLeaky(allocator, node_val);
        return .{ .patch = .{ .target = .{ .target = target, .node = node } } };
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
        } else {
            return error.UnknownEventName;
        }
    } else {
        return error.UnknownMsgType;
    }
}

fn parseNodeLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!Node {
    const obj = try asObject(v);
    const type_str = try getRequiredString(obj, "type");
    if (std.mem.eql(u8, type_str, "vbox")) {
        const id = try getRequiredString(obj, "id");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .vbox = .{ .id = id, .children = out } };
    } else if (std.mem.eql(u8, type_str, "text")) {
        const id = try getRequiredString(obj, "id");
        const text = try getRequiredString(obj, "text");
        return .{ .text = .{ .id = id, .text = text } };
    } else if (std.mem.eql(u8, type_str, "input")) {
        const id = try getRequiredString(obj, "id");
        const placeholder = try getOptionalString(obj, "placeholder");
        return .{ .input = .{ .id = id, .placeholder = placeholder } };
    } else {
        return error.UnknownNodeType;
    }
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

fn getOptionalString(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?[]const u8 {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
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

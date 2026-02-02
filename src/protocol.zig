const std = @import("std");

pub const Msg = union(enum) {
    patch: PatchMsg,
    event: EventMsg,
};

pub const PatchMsg = struct {
    root: Node,
};

pub const EventMsg = struct {
    name: []const u8,
    key: []const u8,
};

pub const Node = union(enum) {
    vbox: VBoxNode,
    text: TextNode,
};

pub const VBoxNode = struct {
    id: []const u8,
    children: []Node,
};

pub const TextNode = struct {
    id: []const u8,
    text: []const u8,
};

pub const ParseMsgError = error{
    InvalidJson,
    MissingField,
    WrongType,
    UnknownMsgType,
    UnknownNodeType,
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
        const root_val = try getRequired(obj, "root");
        const root = try parseNodeLeaky(allocator, root_val);
        return .{ .patch = .{ .root = root } };
    } else if (std.mem.eql(u8, type_str, "event")) {
        const name = try getRequiredString(obj, "name");
        const key = try getRequiredString(obj, "key");
        return .{ .event = .{ .name = name, .key = key } };
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

pub fn writeEventJsonl(writer: anytype, key: []const u8) !void {
    // v0: keys are simple tokens (e.g. "q", "x", "ctrl-c"), so no escaping needed.
    try writer.print("{{\"type\":\"event\",\"name\":\"key\",\"key\":\"{s}\"}}\n", .{key});
}

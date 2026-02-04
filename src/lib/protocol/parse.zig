const std = @import("std");
const style = @import("../style.zig");

const protocol = @import("types.zig");

const Msg = protocol.Msg;
const PatchMsg = protocol.PatchMsg;
const PatchMode = protocol.PatchMode;
const EventMsg = protocol.EventMsg;
const Node = protocol.Node;
const JustifyContent = protocol.JustifyContent;
const AlignItems = protocol.AlignItems;
const HorizontalAlign = protocol.HorizontalAlign;
const VerticalAlign = protocol.VerticalAlign;
const OverlayPlacement = protocol.OverlayPlacement;
const OverlayAlign = protocol.OverlayAlign;
const OverlayLayer = protocol.OverlayLayer;
const Span = protocol.Span;
const PointerKind = protocol.PointerKind;
const PointerButton = protocol.PointerButton;
const PointerEvent = protocol.PointerEvent;
const ParseMsgError = protocol.ParseMsgError;

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
        } else if (std.mem.eql(u8, name, "scroll")) {
            const id = try getRequiredString(obj, "id");
            const scroll_y = try getRequiredUsize(obj, "scroll_y");
            return .{ .event = .{ .scroll = .{ .id = id, .scroll_y = scroll_y } } };
        } else if (std.mem.eql(u8, name, "resize")) {
            const rows = try getRequiredUsize(obj, "rows");
            const cols = try getRequiredUsize(obj, "cols");
            return .{ .event = .{ .resize = .{ .rows = rows, .cols = cols } } };
        } else if (std.mem.eql(u8, name, "hover")) {
            const id = try getRequiredString(obj, "id");
            const x = try getRequiredUsize(obj, "x");
            const y = try getRequiredUsize(obj, "y");
            const item = try getOptionalString(obj, "item");
            return .{ .event = .{ .hover = .{ .id = id, .x = x, .y = y, .item = item } } };
        } else if (std.mem.eql(u8, name, "pointer")) {
            const kind = try parsePointerKind(obj);
            const id = try getRequiredString(obj, "id");
            const x = try getRequiredUsize(obj, "x");
            const y = try getRequiredUsize(obj, "y");
            const local_x = try getRequiredUsize(obj, "local_x");
            const local_y = try getRequiredUsize(obj, "local_y");
            const button = try parsePointerButton(obj);
            const buttons = try getRequiredUsize(obj, "buttons");
            if (buttons > std.math.maxInt(u8)) return error.WrongType;
            const mods = try getRequiredUsize(obj, "mods");
            if (mods > std.math.maxInt(u8)) return error.WrongType;
            const clicks = try getRequiredUsize(obj, "clicks");
            if (clicks > std.math.maxInt(u8)) return error.WrongType;
            const scroll_dx = try getRequiredIsize(obj, "scroll_dx");
            const scroll_dy = try getRequiredIsize(obj, "scroll_dy");
            const item = try getOptionalString(obj, "item");
            const captured = try getRequiredBool(obj, "captured");
            const ev: PointerEvent = .{
                .kind = kind,
                .id = id,
                .x = x,
                .y = y,
                .local_x = local_x,
                .local_y = local_y,
                .button = button,
                .buttons = @as(u8, @intCast(buttons)),
                .mods = @as(u8, @intCast(mods)),
                .clicks = @as(u8, @intCast(clicks)),
                .scroll_dx = scroll_dx,
                .scroll_dy = scroll_dy,
                .item = item,
                .captured = captured,
            };
            return .{ .event = .{ .pointer = ev } };
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

fn parseJustifyContent(obj: std.json.ObjectMap) ParseMsgError!JustifyContent {
    const s = try getOptionalString(obj, "justify_content") orelse return .start;
    if (std.mem.eql(u8, s, "start")) return .start;
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "end")) return .end;
    if (std.mem.eql(u8, s, "space_between")) return .space_between;
    if (std.mem.eql(u8, s, "space_around")) return .space_around;
    if (std.mem.eql(u8, s, "space_evenly")) return .space_evenly;
    return error.UnknownJustifyContent;
}

fn parseAlignItemsString(s: []const u8) ParseMsgError!AlignItems {
    if (std.mem.eql(u8, s, "start")) return .start;
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "end")) return .end;
    if (std.mem.eql(u8, s, "stretch")) return .stretch;
    return error.UnknownAlignItems;
}

fn parseAlignItemsOrDefault(obj: std.json.ObjectMap, field: []const u8, default: AlignItems) ParseMsgError!AlignItems {
    const s = try getOptionalString(obj, field) orelse return default;
    return parseAlignItemsString(s);
}

fn parseAlignItemsOptional(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?AlignItems {
    const s = try getOptionalString(obj, field) orelse return null;
    return try parseAlignItemsString(s);
}

fn parseHorizontalAlignString(s: []const u8) ParseMsgError!HorizontalAlign {
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "right")) return .right;
    return error.UnknownHorizontalAlign;
}

fn parseHorizontalAlignOrDefault(obj: std.json.ObjectMap, field: []const u8, default: HorizontalAlign) ParseMsgError!HorizontalAlign {
    const s = try getOptionalString(obj, field) orelse return default;
    return parseHorizontalAlignString(s);
}

fn parseVerticalAlignString(s: []const u8) ParseMsgError!VerticalAlign {
    if (std.mem.eql(u8, s, "top")) return .top;
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "bottom")) return .bottom;
    return error.UnknownVerticalAlign;
}

fn parseVerticalAlignOrDefault(obj: std.json.ObjectMap, field: []const u8, default: VerticalAlign) ParseMsgError!VerticalAlign {
    const s = try getOptionalString(obj, field) orelse return default;
    return parseVerticalAlignString(s);
}

fn parseHoverable(obj: std.json.ObjectMap) ParseMsgError!bool {
    if (obj.get("hoverable")) |v| {
        return switch (v) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    if (obj.get("hover")) |v| {
        return switch (v) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    return false;
}

fn parseMouseable(obj: std.json.ObjectMap) ParseMsgError!bool {
    if (obj.get("mouseable")) |v| {
        return switch (v) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    return false;
}

fn parsePointerKind(obj: std.json.ObjectMap) ParseMsgError!PointerKind {
    const s = try getRequiredString(obj, "kind");
    if (std.mem.eql(u8, s, "down")) return .down;
    if (std.mem.eql(u8, s, "up")) return .up;
    if (std.mem.eql(u8, s, "move")) return .move;
    if (std.mem.eql(u8, s, "drag")) return .drag;
    if (std.mem.eql(u8, s, "scroll")) return .scroll;
    return error.UnknownPointerKind;
}

fn parsePointerButton(obj: std.json.ObjectMap) ParseMsgError!PointerButton {
    const s = try getRequiredString(obj, "button");
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "middle")) return .middle;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "none")) return .none;
    return error.UnknownPointerButton;
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
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const justify_content = try parseJustifyContent(obj);
        const align_items = try parseAlignItemsOrDefault(obj, "align_items", .stretch);
        const gap = try getOptionalUsize(obj, "gap") orelse 0;
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .vbox = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .pad = pad,
            .clip = clip,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .justify_content = justify_content,
            .align_items = align_items,
            .gap = gap,
            .align_self = align_self,
            .style = st,
            .children = out,
        } };
    } else if (std.mem.eql(u8, type_str, "hbox")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const pad = try getOptionalUsize(obj, "pad") orelse 0;
        const clip = try getOptionalBool(obj, "clip") orelse false;
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const justify_content = try parseJustifyContent(obj);
        const align_items = try parseAlignItemsOrDefault(obj, "align_items", .stretch);
        const gap = try getOptionalUsize(obj, "gap") orelse 0;
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .hbox = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .pad = pad,
            .clip = clip,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .justify_content = justify_content,
            .align_items = align_items,
            .gap = gap,
            .align_self = align_self,
            .style = st,
            .children = out,
        } };
    } else if (std.mem.eql(u8, type_str, "box")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const title = try getOptionalString(obj, "title");
        const border = try getOptionalBool(obj, "border") orelse true;
        const pad = try getOptionalUsize(obj, "pad") orelse 0;
        const clip = try getOptionalBool(obj, "clip") orelse true;
        const shadow = try getOptionalBool(obj, "shadow") orelse false;
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const st = try getOptionalStyleOverride(obj, "style");
        const child_val = try getRequired(obj, "child");
        const child_node = try parseNodeLeaky(allocator, child_val);
        const child = try allocator.create(Node);
        child.* = child_node;
        return .{ .box = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .title = title,
            .border = border,
            .pad = pad,
            .clip = clip,
            .shadow = shadow,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .align_self = align_self,
            .style = st,
            .child = child,
        } };
    } else if (std.mem.eql(u8, type_str, "scroll")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const pad = try getOptionalUsize(obj, "pad") orelse 0;
        const clip = try getOptionalBool(obj, "clip") orelse true;
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const st = try getOptionalStyleOverride(obj, "style");
        const child_val = try getRequired(obj, "child");
        const child_node = try parseNodeLeaky(allocator, child_val);
        const child = try allocator.create(Node);
        child.* = child_node;
        return .{ .scroll = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .pad = pad,
            .clip = clip,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .align_self = align_self,
            .style = st,
            .child = child,
        } };
    } else if (std.mem.eql(u8, type_str, "overlay")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const pad = try getOptionalUsize(obj, "pad") orelse 0;
        const clip = try getOptionalBool(obj, "clip") orelse false;
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const st = try getOptionalStyleOverride(obj, "style");

        const base_val = try getRequired(obj, "base");
        const base_node = try parseNodeLeaky(allocator, base_val);
        const base = try allocator.create(Node);
        base.* = base_node;

        const layers_val = try getRequired(obj, "layers");
        const layers_arr = try asArray(layers_val);
        var layers = try allocator.alloc(OverlayLayer, layers_arr.items.len);
        for (layers_arr.items, 0..) |layer_val, i| {
            layers[i] = try parseOverlayLayerLeaky(allocator, layer_val);
        }

        return .{ .overlay = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .pad = pad,
            .clip = clip,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .align_self = align_self,
            .style = st,
            .base = base,
            .layers = layers,
        } };
    } else if (std.mem.eql(u8, type_str, "text")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const ext_align = try parseHorizontalAlignOrDefault(obj, "ext_align", .left);
        const v_align = try parseVerticalAlignOrDefault(obj, "v_align", .top);
        const st = try getOptionalStyleOverride(obj, "style");
        const text = try getRequiredString(obj, "text");
        return .{ .text = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .align_self = align_self,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .ext_align = ext_align,
            .v_align = v_align,
            .style = st,
            .text = text,
        } };
    } else if (std.mem.eql(u8, type_str, "styled_text")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const ext_align = try parseHorizontalAlignOrDefault(obj, "ext_align", .left);
        const v_align = try parseVerticalAlignOrDefault(obj, "v_align", .top);
        const st = try getOptionalStyleOverride(obj, "style");
        const spans_val = try getRequired(obj, "spans");
        const spans_arr = try asArray(spans_val);
        var spans_out = try allocator.alloc(Span, spans_arr.items.len);
        for (spans_arr.items, 0..) |span_val, i| {
            spans_out[i] = try parseSpanLeaky(allocator, span_val);
        }
        return .{ .styled_text = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .align_self = align_self,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .ext_align = ext_align,
            .v_align = v_align,
            .style = st,
            .spans = spans_out,
        } };
    } else if (std.mem.eql(u8, type_str, "input")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const content_align = try parseHorizontalAlignOrDefault(obj, "content_align", .left);
        const st = try getOptionalStyleOverride(obj, "style");
        const ph_st = try getOptionalStyleOverride(obj, "placeholder_style");
        const placeholder = try getOptionalString(obj, "placeholder");
        return .{ .input = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .align_self = align_self,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .content_align = content_align,
            .style = st,
            .placeholder_style = ph_st,
            .placeholder = placeholder,
        } };
    } else if (std.mem.eql(u8, type_str, "list")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const height = try getOptionalUsize(obj, "height");
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .list = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .height = height,
            .align_self = align_self,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .style = st,
            .children = out,
        } };
    } else {
        return error.UnknownNodeType;
    }
}

fn parseOverlayLayerLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!OverlayLayer {
    const obj = try asObject(v);

    const node_val = try getRequired(obj, "node");
    const node_node = try parseNodeLeaky(allocator, node_val);
    const node = try allocator.create(Node);
    node.* = node_node;

    const anchor = try getOptionalString(obj, "anchor");
    const placement = try parseOverlayPlacement(obj);
    const align_mode = try parseOverlayAlign(obj);
    const offset_x = try getOptionalIsize(obj, "offset_x") orelse 0;
    const offset_y = try getOptionalIsize(obj, "offset_y") orelse 0;
    const w = try getOptionalUsize(obj, "w");
    const h = try getOptionalUsize(obj, "h");
    const clip = try getOptionalBool(obj, "clip") orelse true;
    const modal = try getOptionalBool(obj, "modal") orelse false;

    return .{
        .node = node,
        .anchor = anchor,
        .placement = placement,
        .align_ = align_mode,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .w = w,
        .h = h,
        .clip = clip,
        .modal = modal,
    };
}

fn parseOverlayPlacement(obj: std.json.ObjectMap) ParseMsgError!OverlayPlacement {
    const s = try getRequiredString(obj, "placement");
    if (std.mem.eql(u8, s, "below")) return .below;
    if (std.mem.eql(u8, s, "above")) return .above;
    if (std.mem.eql(u8, s, "right")) return .right;
    if (std.mem.eql(u8, s, "left")) return .left;
    if (std.mem.eql(u8, s, "center")) return .center;
    return error.UnknownOverlayPlacement;
}

fn parseOverlayAlign(obj: std.json.ObjectMap) ParseMsgError!OverlayAlign {
    const s = try getOptionalString(obj, "align") orelse return .start;
    if (std.mem.eql(u8, s, "start")) return .start;
    if (std.mem.eql(u8, s, "center")) return .center;
    if (std.mem.eql(u8, s, "end")) return .end;
    return error.UnknownOverlayAlign;
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

fn getRequiredIsize(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!isize {
    const v = try getRequired(obj, field);
    return switch (v) {
        .integer => |n| std.math.cast(isize, n) orelse return error.WrongType,
        else => error.WrongType,
    };
}

fn getRequiredBool(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!bool {
    const v = try getRequired(obj, field);
    return switch (v) {
        .bool => |b| b,
        else => error.WrongType,
    };
}

fn getOptionalString(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?[]const u8 {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => error.WrongType,
    };
}

fn getOptionalUsize(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?usize {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .null => null,
        .integer => |n| if (n < 0) return error.WrongType else @as(usize, @intCast(n)),
        else => error.WrongType,
    };
}

fn getOptionalIsize(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?isize {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .null => null,
        .integer => |n| std.math.cast(isize, n) orelse return error.WrongType,
        else => error.WrongType,
    };
}

fn getOptionalBool(obj: std.json.ObjectMap, field: []const u8) ParseMsgError!?bool {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .null => null,
        .bool => |b| b,
        else => error.WrongType,
    };
}

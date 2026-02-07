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
const ClipboardMsg = protocol.ClipboardMsg;
const ClipboardOp = protocol.ClipboardOp;
const ClipboardTarget = protocol.ClipboardTarget;
const ClipboardEvent = protocol.ClipboardEvent;
const PasteSource = protocol.PasteSource;
const PasteEvent = protocol.PasteEvent;
const ConfigMsg = protocol.ConfigMsg;
const KeybindingsConfig = protocol.KeybindingsConfig;
const KeybindingRule = protocol.KeybindingRule;
const KeyAction = protocol.KeyAction;
const ValidationState = protocol.ValidationState;
const ListMarker = protocol.ListMarker;
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
            const mods_usize = try getOptionalUsize(obj, "mods") orelse 0;
            if (mods_usize > std.math.maxInt(u8)) return error.WrongType;
            const seq = try getOptionalString(obj, "seq");
            return .{ .event = .{ .key = .{ .key = key, .mods = @as(u8, @intCast(mods_usize)), .seq = seq } } };
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
        } else if (std.mem.eql(u8, name, "clipboard")) {
            const op = try parseClipboardOp(obj);
            const ok = try getRequiredBool(obj, "ok");
            const req_usize = try getOptionalUsize(obj, "request_id") orelse 0;
            if (req_usize > std.math.maxInt(u32)) return error.WrongType;
            const request_id = @as(u32, @intCast(req_usize));
            const data = try getOptionalString(obj, "data");
            const reason = try getOptionalString(obj, "reason");
            const cev: ClipboardEvent = .{
                .op = op,
                .ok = ok,
                .request_id = request_id,
                .data = data,
                .reason = reason,
            };
            return .{ .event = .{ .clipboard = cev } };
        } else if (std.mem.eql(u8, name, "paste")) {
            const src = try parsePasteSource(obj);
            const bytes = try getRequiredUsize(obj, "bytes");
            const pev: PasteEvent = .{ .source = src, .bytes = bytes };
            return .{ .event = .{ .paste = pev } };
        } else {
            return error.UnknownEventName;
        }
    } else if (std.mem.eql(u8, type_str, "clipboard")) {
        const op = try parseClipboardOp(obj);
        const target = try parseClipboardTarget(obj);
        switch (op) {
            .write => {
                const data = try getRequiredString(obj, "data");
                return .{ .clipboard = .{ .write = .{ .data = data, .target = target } } };
            },
            .read => {
                const request_id_val = try getRequired(obj, "request_id");
                const request_id = switch (request_id_val) {
                    .integer => |n| blk: {
                        if (n < 0) return error.WrongType;
                        if (n > std.math.maxInt(u32)) return error.WrongType;
                        break :blk @as(u32, @intCast(n));
                    },
                    else => return error.WrongType,
                };
                return .{ .clipboard = .{ .read = .{ .request_id = request_id, .target = target } } };
            },
        }
    } else if (std.mem.eql(u8, type_str, "config")) {
        const cfg = try parseConfigMsg(allocator, obj);
        return .{ .config = cfg };
    } else {
        return error.UnknownMsgType;
    }
}

fn parseConfigMsg(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseMsgError!ConfigMsg {
    const keybindings_val = try getRequired(obj, "keybindings");
    const keybindings_obj = try asObject(keybindings_val);
    return .{ .keybindings = try parseKeybindingsConfig(allocator, keybindings_obj) };
}

fn parseKeybindingsConfig(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseMsgError!KeybindingsConfig {
    return .{
        .global = try parseOptionalKeybindingRuleArrayLeaky(allocator, obj, "global"),
        .input = try parseOptionalKeybindingRuleArrayLeaky(allocator, obj, "input"),
        .textarea = try parseOptionalKeybindingRuleArrayLeaky(allocator, obj, "textarea"),
        .list = try parseOptionalKeybindingRuleArrayLeaky(allocator, obj, "list"),
        .scroll = try parseOptionalKeybindingRuleArrayLeaky(allocator, obj, "scroll"),
        .action = try parseOptionalKeybindingRuleArrayLeaky(allocator, obj, "action"),
    };
}

fn parseOptionalKeybindingRuleArrayLeaky(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    field: []const u8,
) ParseMsgError!?[]KeybindingRule {
    const rules_val = obj.get(field) orelse return null;
    const arr = asArray(rules_val) catch return error.InvalidKeybindingRule;
    const parsed = try parseKeybindingRuleArrayLeaky(allocator, arr);
    return parsed;
}

fn parseKeybindingRuleArrayLeaky(allocator: std.mem.Allocator, arr: std.json.Array) ParseMsgError![]KeybindingRule {
    var out = try allocator.alloc(KeybindingRule, arr.items.len);
    for (arr.items, 0..) |item, idx| {
        out[idx] = parseKeybindingRule(item) catch |e| switch (e) {
            error.UnknownKeyAction => return error.UnknownKeyAction,
            else => return error.InvalidKeybindingRule,
        };
    }
    return out;
}

fn parseKeybindingRule(v: std.json.Value) ParseMsgError!KeybindingRule {
    const rule_obj = asObject(v) catch return error.InvalidKeybindingRule;

    const key = getRequiredString(rule_obj, "key") catch return error.InvalidKeybindingRule;
    if (key.len == 0) return error.InvalidKeybindingRule;

    const action_name = getRequiredString(rule_obj, "action") catch return error.InvalidKeybindingRule;
    const action = parseKeyAction(action_name) catch |e| switch (e) {
        error.UnknownKeyAction => return error.UnknownKeyAction,
        else => return error.InvalidKeybindingRule,
    };

    const mods = parseKeybindingMods(rule_obj) catch return error.InvalidKeybindingRule;
    return .{
        .key = key,
        .mods = mods,
        .action = action,
    };
}

fn parseKeybindingMods(obj: std.json.ObjectMap) ParseMsgError!u8 {
    const mods_val = obj.get("mods") orelse return 0;
    return switch (mods_val) {
        .integer => |n| blk: {
            if (n < 0 or n > 7) return error.InvalidKeybindingRule;
            break :blk @as(u8, @intCast(n));
        },
        else => error.InvalidKeybindingRule,
    };
}

fn parseKeyAction(s: []const u8) ParseMsgError!KeyAction {
    if (std.mem.eql(u8, s, "noop")) return .noop;
    if (std.mem.eql(u8, s, "focus_next")) return .focus_next;
    if (std.mem.eql(u8, s, "focus_prev")) return .focus_prev;
    if (std.mem.eql(u8, s, "focus_scope_next")) return .focus_scope_next;
    if (std.mem.eql(u8, s, "focus_scope_prev")) return .focus_scope_prev;
    if (std.mem.eql(u8, s, "focus_clear")) return .focus_clear;
    if (std.mem.eql(u8, s, "list_prev")) return .list_prev;
    if (std.mem.eql(u8, s, "list_next")) return .list_next;
    if (std.mem.eql(u8, s, "list_activate")) return .list_activate;
    if (std.mem.eql(u8, s, "scroll_line_up")) return .scroll_line_up;
    if (std.mem.eql(u8, s, "scroll_line_down")) return .scroll_line_down;
    if (std.mem.eql(u8, s, "scroll_page_up")) return .scroll_page_up;
    if (std.mem.eql(u8, s, "scroll_page_down")) return .scroll_page_down;
    if (std.mem.eql(u8, s, "scroll_home")) return .scroll_home;
    if (std.mem.eql(u8, s, "scroll_end")) return .scroll_end;
    if (std.mem.eql(u8, s, "action_activate")) return .action_activate;
    if (std.mem.eql(u8, s, "input_left")) return .input_left;
    if (std.mem.eql(u8, s, "input_right")) return .input_right;
    if (std.mem.eql(u8, s, "input_word_left")) return .input_word_left;
    if (std.mem.eql(u8, s, "input_word_right")) return .input_word_right;
    if (std.mem.eql(u8, s, "input_home")) return .input_home;
    if (std.mem.eql(u8, s, "input_end")) return .input_end;
    if (std.mem.eql(u8, s, "input_delete")) return .input_delete;
    if (std.mem.eql(u8, s, "input_backspace")) return .input_backspace;
    if (std.mem.eql(u8, s, "textarea_left")) return .textarea_left;
    if (std.mem.eql(u8, s, "textarea_right")) return .textarea_right;
    if (std.mem.eql(u8, s, "textarea_up")) return .textarea_up;
    if (std.mem.eql(u8, s, "textarea_down")) return .textarea_down;
    if (std.mem.eql(u8, s, "textarea_word_left")) return .textarea_word_left;
    if (std.mem.eql(u8, s, "textarea_word_right")) return .textarea_word_right;
    if (std.mem.eql(u8, s, "textarea_home")) return .textarea_home;
    if (std.mem.eql(u8, s, "textarea_end")) return .textarea_end;
    if (std.mem.eql(u8, s, "textarea_page_up")) return .textarea_page_up;
    if (std.mem.eql(u8, s, "textarea_page_down")) return .textarea_page_down;
    if (std.mem.eql(u8, s, "textarea_delete")) return .textarea_delete;
    if (std.mem.eql(u8, s, "textarea_backspace")) return .textarea_backspace;
    if (std.mem.eql(u8, s, "textarea_newline")) return .textarea_newline;
    return error.UnknownKeyAction;
}

fn parseClipboardOp(obj: std.json.ObjectMap) ParseMsgError!ClipboardOp {
    const s = try getRequiredString(obj, "op");
    if (std.mem.eql(u8, s, "write")) return .write;
    if (std.mem.eql(u8, s, "read")) return .read;
    return error.UnknownClipboardOp;
}

fn parseClipboardTarget(obj: std.json.ObjectMap) ParseMsgError!ClipboardTarget {
    const s = try getOptionalString(obj, "target") orelse return .clipboard;
    if (std.mem.eql(u8, s, "clipboard")) return .clipboard;
    return error.UnknownClipboardTarget;
}

fn parsePasteSource(obj: std.json.ObjectMap) ParseMsgError!PasteSource {
    const s = try getRequiredString(obj, "source");
    if (std.mem.eql(u8, s, "bracketed")) return .bracketed;
    if (std.mem.eql(u8, s, "clipboard")) return .clipboard;
    return error.UnknownPasteSource;
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

fn parseDisabled(obj: std.json.ObjectMap) ParseMsgError!bool {
    return try getOptionalBool(obj, "disabled") orelse false;
}

fn parseReadonly(obj: std.json.ObjectMap) ParseMsgError!bool {
    return try getOptionalBool(obj, "readonly") orelse false;
}

fn parseValidation(obj: std.json.ObjectMap) ParseMsgError!ValidationState {
    const s = try getOptionalString(obj, "validation") orelse return .none;
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "error")) return .@"error";
    if (std.mem.eql(u8, s, "warning")) return .warning;
    if (std.mem.eql(u8, s, "success")) return .success;
    return error.UnknownValidationState;
}

fn parseFocusable(obj: std.json.ObjectMap, default: bool) ParseMsgError!bool {
    if (obj.get("focusable")) |v| {
        return switch (v) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    return default;
}

fn parseFocusScope(obj: std.json.ObjectMap) ParseMsgError!?[]const u8 {
    if (try getOptionalString(obj, "focus_scope")) |scope| {
        if (scope.len == 0) return null;
        return scope;
    }
    if (try getOptionalString(obj, "focus_group")) |scope| {
        if (scope.len == 0) return null;
        return scope;
    }
    return null;
}

fn parseListMarker(obj: std.json.ObjectMap) ParseMsgError!ListMarker {
    const s = try getOptionalString(obj, "marker") orelse return .default;
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "none")) return .none;
    return error.UnknownListMarker;
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, false);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, false);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, false);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, true);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, false);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, false);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, false);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, true);
        const focus_scope = try parseFocusScope(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
            .content_align = content_align,
            .style = st,
            .placeholder_style = ph_st,
            .placeholder = placeholder,
        } };
    } else if (std.mem.eql(u8, type_str, "textarea")) {
        const id = try getRequiredString(obj, "id");
        const w = try getOptionalUsize(obj, "w");
        const h = try getOptionalUsize(obj, "h");
        const flex = try getOptionalUsize(obj, "flex") orelse 0;
        const align_self = try parseAlignItemsOptional(obj, "align_self");
        const hoverable = try parseHoverable(obj);
        const mouseable = try parseMouseable(obj);
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, true);
        const focus_scope = try parseFocusScope(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const ph_st = try getOptionalStyleOverride(obj, "placeholder_style");
        const placeholder = try getOptionalString(obj, "placeholder");
        return .{ .textarea = .{
            .id = id,
            .w = w,
            .h = h,
            .flex = flex,
            .align_self = align_self,
            .hoverable = hoverable,
            .mouseable = mouseable,
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
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
        const disabled = try parseDisabled(obj);
        const readonly = try parseReadonly(obj);
        const validation = try parseValidation(obj);
        const focusable = try parseFocusable(obj, true);
        const focus_scope = try parseFocusScope(obj);
        const marker = try parseListMarker(obj);
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
            .disabled = disabled,
            .readonly = readonly,
            .validation = validation,
            .focusable = focusable,
            .focus_scope = focus_scope,
            .marker = marker,
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

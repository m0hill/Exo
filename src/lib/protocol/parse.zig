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
const GridTrack = protocol.GridTrack;
const PointerKind = protocol.PointerKind;
const PointerButton = protocol.PointerButton;
const PointerEvent = protocol.PointerEvent;
const SelectionEvent = protocol.SelectionEvent;
const SelectionKind = protocol.SelectionKind;
const VListRangeEvent = protocol.VListRangeEvent;
const VListRangeReason = protocol.VListRangeReason;
const ClipboardMsg = protocol.ClipboardMsg;
const ClipboardOp = protocol.ClipboardOp;
const ClipboardTarget = protocol.ClipboardTarget;
const ClipboardEvent = protocol.ClipboardEvent;
const PasteSource = protocol.PasteSource;
const PasteEvent = protocol.PasteEvent;
const RuntimeErrorEvent = protocol.RuntimeErrorEvent;
const AckStatus = protocol.AckStatus;
const AckEvent = protocol.AckEvent;
const ConfigAckRejected = protocol.ConfigAckRejected;
const ConfigAckEvent = protocol.ConfigAckEvent;
const HelloCaps = protocol.HelloCaps;
const HelloLimits = protocol.HelloLimits;
const HelloEvent = protocol.HelloEvent;
const ConfigMsg = protocol.ConfigMsg;
const ScrollingConfig = protocol.ScrollingConfig;
const ThemeName = protocol.ThemeName;
const ThemeSpec = protocol.ThemeSpec;
const ThemeVarEntry = protocol.ThemeVarEntry;
const ThemeRule = protocol.ThemeRule;
const ThemeChrome = protocol.ThemeChrome;
const ThemeOverlays = protocol.ThemeOverlays;
const KeybindingsConfig = protocol.KeybindingsConfig;
const KeybindingRule = protocol.KeybindingRule;
const KeyAction = protocol.KeyAction;
const ValidationState = protocol.ValidationState;
const StateMode = protocol.StateMode;
const ListMarker = protocol.ListMarker;
const ParseMsgError = protocol.ParseMsgError;

const theme_spec_max_rules: usize = 2048;
const theme_spec_max_vars: usize = 256;
const theme_spec_max_selector_len: usize = 256;
const theme_spec_max_var_name_len: usize = 64;

pub fn parseMsgLeaky(allocator: std.mem.Allocator, line: []const u8) ParseMsgError!Msg {
    const json = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch {
        return error.InvalidJson;
    };
    return parseMsgValueLeaky(allocator, json);
}

fn parseMsgValueLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!Msg {
    const obj = try asObject(v);
    const type_str = try getRequiredString(obj, "type");
    const version = try getRequiredVersion(obj);
    if (std.mem.eql(u8, type_str, "patch")) {
        const seq = if (try getOptionalUsize(obj, "seq")) |seq_usize|
            try usizeToU64(seq_usize)
        else
            null;
        if (obj.get("root")) |root_val| {
            if (obj.get("target") != null or obj.get("node") != null) return error.InvalidPatchShape;
            try expectOnlyFields(obj, &.{ "type", "root", "seq", "v" });
            const root = try parseNodeLeaky(allocator, root_val);
            return .{ .patch = .{ .full = .{ .root = root, .seq = seq, .v = version } } };
        }

        if (obj.get("target") == null and obj.get("node") == null) return error.MissingField;
        if (obj.get("target") == null or obj.get("node") == null) return error.InvalidPatchShape;

        const target = try getRequiredString(obj, "target");
        const mode = try parsePatchMode(obj);
        const node_val = try getRequired(obj, "node");
        try expectOnlyFields(obj, &.{ "type", "target", "node", "mode", "seq", "v" });
        const node = try parseNodeLeaky(allocator, node_val);
        return .{ .patch = .{ .target = .{
            .target = target,
            .node = node,
            .mode = mode,
            .seq = seq,
            .v = version,
        } } };
    } else if (std.mem.eql(u8, type_str, "event")) {
        const name = try getRequiredString(obj, "name");
        if (std.mem.eql(u8, name, "hello")) {
            try expectOnlyFields(obj, &.{ "type", "name", "protocol_version", "caps", "limits", "v" });
            const protocol_version_u = try getRequiredUsize(obj, "protocol_version");
            if (protocol_version_u > std.math.maxInt(u32)) return error.WrongType;
            const caps_obj = try asObject(try getRequired(obj, "caps"));
            const limits_obj = try asObject(try getRequired(obj, "limits"));
            const hello: HelloEvent = .{
                .protocol_version = @as(u32, @intCast(protocol_version_u)),
                .caps = try parseHelloCaps(caps_obj),
                .limits = try parseHelloLimits(limits_obj),
                .v = version,
            };
            return .{ .event = .{ .hello = hello } };
        } else if (std.mem.eql(u8, name, "key")) {
            try expectOnlyFields(obj, &.{ "type", "name", "key", "mods", "seq", "v" });
            const key = try getRequiredString(obj, "key");
            const mods_usize = try getOptionalUsize(obj, "mods") orelse 0;
            if (mods_usize > std.math.maxInt(u8)) return error.WrongType;
            const seq = try getOptionalString(obj, "seq");
            return .{ .event = .{ .key = .{
                .key = key,
                .mods = @as(u8, @intCast(mods_usize)),
                .seq = seq,
                .v = version,
            } } };
        } else if (std.mem.eql(u8, name, "focus")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "v" });
            const id = try getRequiredString(obj, "id");
            return .{ .event = .{ .focus = .{ .id = id, .v = version } } };
        } else if (std.mem.eql(u8, name, "input")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "value", "cursor", "v" });
            const id = try getRequiredString(obj, "id");
            const value = try getRequiredString(obj, "value");
            const cursor_val = try getRequired(obj, "cursor");
            const cursor = switch (cursor_val) {
                .integer => |n| if (n < 0) return error.WrongType else @as(usize, @intCast(n)),
                else => return error.WrongType,
            };
            return .{ .event = .{ .input = .{
                .id = id,
                .value = value,
                .cursor = cursor,
                .v = version,
            } } };
        } else if (std.mem.eql(u8, name, "select")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "item", "index", "v" });
            const id = try getRequiredString(obj, "id");
            const item = try getRequiredString(obj, "item");
            const index = try getOptionalUsize(obj, "index");
            return .{ .event = .{ .select = .{ .id = id, .item = item, .index = index, .v = version } } };
        } else if (std.mem.eql(u8, name, "activate")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "item", "index", "v" });
            const id = try getRequiredString(obj, "id");
            const item = try getRequiredString(obj, "item");
            const index = try getOptionalUsize(obj, "index");
            return .{ .event = .{ .activate = .{ .id = id, .item = item, .index = index, .v = version } } };
        } else if (std.mem.eql(u8, name, "scroll")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "scroll_y", "v" });
            const id = try getRequiredString(obj, "id");
            const scroll_y = try getRequiredUsize(obj, "scroll_y");
            return .{ .event = .{ .scroll = .{ .id = id, .scroll_y = scroll_y, .v = version } } };
        } else if (std.mem.eql(u8, name, "vlist_range")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "request_id", "start", "len", "scroll", "viewport_h", "overscan", "reason", "v" });
            const id = try getRequiredString(obj, "id");
            const request_id_usize = try getRequiredUsize(obj, "request_id");
            const request_id = try usizeToU64(request_id_usize);
            const start = try getRequiredUsize(obj, "start");
            const len = try getRequiredUsize(obj, "len");
            const scroll = try getRequiredUsize(obj, "scroll");
            const viewport_h = try getRequiredUsize(obj, "viewport_h");
            const overscan = try getRequiredUsize(obj, "overscan");
            const reason = try parseVListRangeReason(obj);
            const ev: VListRangeEvent = .{
                .id = id,
                .request_id = request_id,
                .start = start,
                .len = len,
                .scroll = scroll,
                .viewport_h = viewport_h,
                .overscan = overscan,
                .reason = reason,
                .v = version,
            };
            return .{ .event = .{ .vlist_range = ev } };
        } else if (std.mem.eql(u8, name, "resize")) {
            try expectOnlyFields(obj, &.{ "type", "name", "rows", "cols", "v" });
            const rows = try getRequiredUsize(obj, "rows");
            const cols = try getRequiredUsize(obj, "cols");
            return .{ .event = .{ .resize = .{ .rows = rows, .cols = cols, .v = version } } };
        } else if (std.mem.eql(u8, name, "hover")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "x", "y", "item", "index", "v" });
            const id = try getRequiredString(obj, "id");
            const x = try getRequiredUsize(obj, "x");
            const y = try getRequiredUsize(obj, "y");
            const item = try getOptionalString(obj, "item");
            return .{ .event = .{ .hover = .{
                .id = id,
                .x = x,
                .y = y,
                .item = item,
                .index = try getOptionalUsize(obj, "index"),
                .v = version,
            } } };
        } else if (std.mem.eql(u8, name, "selection")) {
            try expectOnlyFields(obj, &.{ "type", "name", "id", "kind", "x0", "y0", "x1", "y1", "local_x0", "local_y0", "local_x1", "local_y1", "text", "bytes", "truncated", "v" });
            const id = try getRequiredString(obj, "id");
            const kind = try parseSelectionKind(obj);
            const x0 = try getRequiredUsize(obj, "x0");
            const y0 = try getRequiredUsize(obj, "y0");
            const x1 = try getRequiredUsize(obj, "x1");
            const y1 = try getRequiredUsize(obj, "y1");
            const local_x0 = try getRequiredUsize(obj, "local_x0");
            const local_y0 = try getRequiredUsize(obj, "local_y0");
            const local_x1 = try getRequiredUsize(obj, "local_x1");
            const local_y1 = try getRequiredUsize(obj, "local_y1");
            const text = try getRequiredString(obj, "text");
            const bytes = try getRequiredUsize(obj, "bytes");
            const truncated = try getOptionalBool(obj, "truncated") orelse false;
            const ev: SelectionEvent = .{
                .id = id,
                .kind = kind,
                .x0 = x0,
                .y0 = y0,
                .x1 = x1,
                .y1 = y1,
                .local_x0 = local_x0,
                .local_y0 = local_y0,
                .local_x1 = local_x1,
                .local_y1 = local_y1,
                .text = text,
                .bytes = bytes,
                .truncated = truncated,
                .v = version,
            };
            return .{ .event = .{ .selection = ev } };
        } else if (std.mem.eql(u8, name, "pointer")) {
            try expectOnlyFields(obj, &.{ "type", "name", "kind", "id", "x", "y", "local_x", "local_y", "button", "buttons", "mods", "clicks", "scroll_dx", "scroll_dy", "item", "item_index", "captured", "v" });
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
            const item_index = try getOptionalUsize(obj, "item_index");
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
                .item_index = item_index,
                .captured = captured,
                .v = version,
            };
            return .{ .event = .{ .pointer = ev } };
        } else if (std.mem.eql(u8, name, "clipboard")) {
            try expectOnlyFields(obj, &.{ "type", "name", "op", "ok", "request_id", "data", "reason", "v" });
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
                .v = version,
            };
            return .{ .event = .{ .clipboard = cev } };
        } else if (std.mem.eql(u8, name, "paste")) {
            try expectOnlyFields(obj, &.{ "type", "name", "source", "bytes", "v" });
            const src = try parsePasteSource(obj);
            const bytes = try getRequiredUsize(obj, "bytes");
            const pev: PasteEvent = .{ .source = src, .bytes = bytes, .v = version };
            return .{ .event = .{ .paste = pev } };
        } else if (std.mem.eql(u8, name, "error")) {
            try expectOnlyFields(obj, &.{ "type", "name", "code", "message", "seq", "context", "v" });
            const code = try getRequiredString(obj, "code");
            const message = try getRequiredString(obj, "message");
            const seq = if (try getOptionalUsize(obj, "seq")) |seq_usize|
                try usizeToU64(seq_usize)
            else
                null;
            const context = try getOptionalString(obj, "context");
            const err_ev: RuntimeErrorEvent = .{
                .code = code,
                .message = message,
                .seq = seq,
                .context = context,
                .v = version,
            };
            return .{ .event = .{ .@"error" = err_ev } };
        } else if (std.mem.eql(u8, name, "ack")) {
            try expectOnlyFields(obj, &.{ "type", "name", "seq", "status", "detail", "v" });
            const seq_usize = try getRequiredUsize(obj, "seq");
            const status = try parseAckStatusString(try getRequiredString(obj, "status"));
            const detail = try getOptionalString(obj, "detail");
            const ack_ev: AckEvent = .{
                .seq = try usizeToU64(seq_usize),
                .status = status,
                .detail = detail,
                .v = version,
            };
            return .{ .event = .{ .ack = ack_ev } };
        } else if (std.mem.eql(u8, name, "config_ack")) {
            try expectOnlyFields(obj, &.{ "type", "name", "applied", "rejected", "v" });
            const ack = try parseConfigAckEvent(allocator, obj, version);
            return .{ .event = .{ .config_ack = ack } };
        } else if (std.mem.eql(u8, name, "rendered")) {
            try expectOnlyFields(obj, &.{ "type", "name", "seq", "dropped", "bytes", "changed_cells", "v" });
            const seq_usize = try getRequiredUsize(obj, "seq");
            const dropped = try getOptionalUsize(obj, "dropped") orelse 0;
            const bytes = try getOptionalUsize(obj, "bytes") orelse 0;
            const changed_cells = try getOptionalUsize(obj, "changed_cells") orelse 0;
            return .{ .event = .{ .rendered = .{
                .seq = try usizeToU64(seq_usize),
                .dropped = dropped,
                .bytes = bytes,
                .changed_cells = changed_cells,
                .v = version,
            } } };
        } else if (std.mem.eql(u8, name, "dropped")) {
            try expectOnlyFields(obj, &.{ "type", "name", "seq", "reason", "v" });
            const seq_usize = try getRequiredUsize(obj, "seq");
            const reason = try getRequiredString(obj, "reason");
            return .{ .event = .{ .dropped = .{
                .seq = try usizeToU64(seq_usize),
                .reason = reason,
                .v = version,
            } } };
        } else {
            return error.UnknownEventName;
        }
    } else if (std.mem.eql(u8, type_str, "clipboard")) {
        const op = try parseClipboardOp(obj);
        switch (op) {
            .write => try expectOnlyFields(obj, &.{ "type", "op", "data", "target", "seq", "v" }),
            .read => try expectOnlyFields(obj, &.{ "type", "op", "request_id", "target", "seq", "v" }),
        }
        const target = try parseClipboardTarget(obj);
        const seq = if (try getOptionalUsize(obj, "seq")) |seq_usize|
            try usizeToU64(seq_usize)
        else
            null;
        switch (op) {
            .write => {
                const data = try getRequiredString(obj, "data");
                return .{ .clipboard = .{ .write = .{
                    .data = data,
                    .target = target,
                    .seq = seq,
                    .v = version,
                } } };
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
                return .{ .clipboard = .{ .read = .{
                    .request_id = request_id,
                    .target = target,
                    .seq = seq,
                    .v = version,
                } } };
            },
        }
    } else if (std.mem.eql(u8, type_str, "config")) {
        try expectOnlyFields(obj, &.{ "type", "keybindings", "theme_spec", "scrolling", "seq", "v" });
        const cfg = try parseConfigMsg(allocator, obj, version);
        return .{ .config = cfg };
    } else {
        return error.UnknownMsgType;
    }
}

fn parseConfigMsg(allocator: std.mem.Allocator, obj: std.json.ObjectMap, v: ?u32) ParseMsgError!ConfigMsg {
    const keybindings: ?KeybindingsConfig = if (obj.get("keybindings")) |keybindings_val| blk: {
        const keybindings_obj = try asObject(keybindings_val);
        break :blk try parseKeybindingsConfig(allocator, keybindings_obj);
    } else null;
    const theme_spec: ?ThemeSpec = if (obj.get("theme_spec")) |theme_spec_val| blk: {
        const theme_spec_obj = try asObject(theme_spec_val);
        break :blk try parseThemeSpec(allocator, theme_spec_obj);
    } else null;
    const scrolling: ?ScrollingConfig = if (obj.get("scrolling")) |scrolling_val| blk: {
        const scrolling_obj = try asObject(scrolling_val);
        break :blk try parseScrollingConfig(scrolling_obj);
    } else null;
    const seq = if (try getOptionalUsize(obj, "seq")) |seq_usize|
        try usizeToU64(seq_usize)
    else
        null;
    if (keybindings == null and theme_spec == null and scrolling == null) return error.MissingField;
    return .{
        .keybindings = keybindings,
        .theme_spec = theme_spec,
        .scrolling = scrolling,
        .seq = seq,
        .v = v,
    };
}

fn parseScrollingConfig(obj: std.json.ObjectMap) ParseMsgError!ScrollingConfig {
    var out: ScrollingConfig = .{};
    var has_any: bool = false;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "scrollbars_enabled")) {
            out.scrollbars_enabled = switch (value) {
                .bool => |b| b,
                else => return error.WrongType,
            };
            has_any = true;
        } else if (std.mem.eql(u8, key, "scrollbar_min_thumb")) {
            const v = switch (value) {
                .integer => |n| blk: {
                    if (n < 1) return error.InvalidScrollingConfig;
                    break :blk @as(usize, @intCast(n));
                },
                else => return error.WrongType,
            };
            out.scrollbar_min_thumb = v;
            has_any = true;
        } else if (std.mem.eql(u8, key, "wheel_scroll_lines")) {
            const v = switch (value) {
                .integer => |n| blk: {
                    if (n < 1 or n > 100) return error.InvalidScrollingConfig;
                    break :blk @as(usize, @intCast(n));
                },
                else => return error.WrongType,
            };
            out.wheel_scroll_lines = v;
            has_any = true;
        } else if (std.mem.eql(u8, key, "wheel_list_lines")) {
            const v = switch (value) {
                .integer => |n| blk: {
                    if (n < 1 or n > 100) return error.InvalidScrollingConfig;
                    break :blk @as(usize, @intCast(n));
                },
                else => return error.WrongType,
            };
            out.wheel_list_lines = v;
            has_any = true;
        } else if (std.mem.eql(u8, key, "wheel_textarea_lines")) {
            const v = switch (value) {
                .integer => |n| blk: {
                    if (n < 1 or n > 100) return error.InvalidScrollingConfig;
                    break :blk @as(usize, @intCast(n));
                },
                else => return error.WrongType,
            };
            out.wheel_textarea_lines = v;
            has_any = true;
        } else {
            return error.UnknownField;
        }
    }
    if (!has_any) return error.MissingField;
    return out;
}

fn parseConfigAckEvent(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    v: ?u32,
) ParseMsgError!ConfigAckEvent {
    const applied_val = try getRequired(obj, "applied");
    const applied_arr = try asArray(applied_val);
    const applied = try allocator.alloc([]const u8, applied_arr.items.len);
    for (applied_arr.items, 0..) |item, idx| {
        applied[idx] = switch (item) {
            .string => |s| s,
            else => return error.WrongType,
        };
    }

    const rejected_val = try getRequired(obj, "rejected");
    const rejected_arr = try asArray(rejected_val);
    const rejected = try allocator.alloc(ConfigAckRejected, rejected_arr.items.len);
    for (rejected_arr.items, 0..) |item, idx| {
        const rej_obj = try asObject(item);
        try expectOnlyFields(rej_obj, &.{ "key", "reason" });
        rejected[idx] = .{
            .key = try getRequiredString(rej_obj, "key"),
            .reason = try getRequiredString(rej_obj, "reason"),
        };
    }

    return .{
        .applied = applied,
        .rejected = rejected,
        .v = v,
    };
}

fn parseHelloCaps(obj: std.json.ObjectMap) ParseMsgError!HelloCaps {
    try expectOnlyFields(obj, &.{ "ansi", "alt_screen", "bracketed_paste", "mouse_sgr", "osc52", "color" });
    return .{
        .ansi = try getRequiredBool(obj, "ansi"),
        .alt_screen = try getRequiredBool(obj, "alt_screen"),
        .bracketed_paste = try getRequiredBool(obj, "bracketed_paste"),
        .mouse_sgr = try getRequiredBool(obj, "mouse_sgr"),
        .osc52 = try getRequiredBool(obj, "osc52"),
        .color = try getRequiredString(obj, "color"),
    };
}

fn parseHelloLimits(obj: std.json.ObjectMap) ParseMsgError!HelloLimits {
    try expectOnlyFields(obj, &.{ "max_fps", "frame_interval_ns", "max_pending_targets", "max_backend_lines_per_iter", "queue_overflow" });
    const max_fps_usize = try getRequiredUsize(obj, "max_fps");
    if (max_fps_usize > std.math.maxInt(u32)) return error.WrongType;
    return .{
        .max_fps = @as(u32, @intCast(max_fps_usize)),
        .frame_interval_ns = try usizeToU64(try getRequiredUsize(obj, "frame_interval_ns")),
        .max_pending_targets = try getRequiredUsize(obj, "max_pending_targets"),
        .max_backend_lines_per_iter = try getRequiredUsize(obj, "max_backend_lines_per_iter"),
        .queue_overflow = try getRequiredString(obj, "queue_overflow"),
    };
}

fn parseThemeName(s: []const u8) error{UnknownThemeSpecBase}!ThemeName {
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "light")) return .light;
    if (std.mem.eql(u8, s, "ocean")) return .ocean;
    return error.UnknownThemeSpecBase;
}

fn parseThemeSpec(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseMsgError!ThemeSpec {
    const base: ?ThemeName = if (try getOptionalString(obj, "base")) |base_name|
        try parseThemeName(base_name)
    else
        null;

    const vars: []ThemeVarEntry = if (obj.get("vars")) |vars_val| blk: {
        const vars_obj = try asObject(vars_val);
        if (vars_obj.count() > theme_spec_max_vars) return error.ThemeSpecTooLarge;
        const out = try allocator.alloc(ThemeVarEntry, vars_obj.count());
        var idx: usize = 0;
        var it = vars_obj.iterator();
        while (it.next()) |entry| : (idx += 1) {
            const name = entry.key_ptr.*;
            if (!isValidThemeVarName(name) or name.len > theme_spec_max_var_name_len) {
                return error.WrongType;
            }
            out[idx] = .{
                .name = name,
                .value = switch (entry.value_ptr.*) {
                    .string => |s| style.parseColorSpec(s) catch return error.InvalidColor,
                    else => return error.WrongType,
                },
            };
        }
        break :blk out;
    } else &.{};

    const chrome = if (obj.get("chrome")) |chrome_val|
        try parseThemeChrome(try asObject(chrome_val))
    else
        ThemeChrome{};

    const overlays = if (obj.get("overlays")) |overlays_val|
        try parseThemeOverlays(try asObject(overlays_val))
    else
        ThemeOverlays{};

    const rules: []ThemeRule = if (obj.get("rules")) |rules_val| blk: {
        const arr = try asArray(rules_val);
        if (arr.items.len > theme_spec_max_rules) return error.ThemeSpecTooLarge;
        const out = try allocator.alloc(ThemeRule, arr.items.len);
        for (arr.items, 0..) |item, idx| {
            const rule_obj = try asObject(item);
            if (rule_obj.count() != 2) return error.UnknownField;
            const selector = try getRequiredString(rule_obj, "selector");
            if (selector.len > theme_spec_max_selector_len) return error.ThemeSpecTooLarge;
            try validateSelector(selector);
            const st = switch (try getRequired(rule_obj, "style")) {
                .object => |st_obj| try parseStyleOverride(st_obj),
                else => return error.WrongType,
            };
            out[idx] = .{
                .selector = selector,
                .style = st,
            };
        }
        break :blk out;
    } else &.{};

    if (!hasOnlyThemeSpecFields(obj)) return error.UnknownField;

    return .{
        .base = base,
        .vars = vars,
        .chrome = chrome,
        .overlays = overlays,
        .rules = rules,
    };
}

fn hasOnlyThemeSpecFields(obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "base")) continue;
        if (std.mem.eql(u8, k, "vars")) continue;
        if (std.mem.eql(u8, k, "chrome")) continue;
        if (std.mem.eql(u8, k, "overlays")) continue;
        if (std.mem.eql(u8, k, "rules")) continue;
        return false;
    }
    return true;
}

fn parseThemeChrome(obj: std.json.ObjectMap) ParseMsgError!ThemeChrome {
    var out: ThemeChrome = .{};
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "input_prefix")) {
            out.input_prefix = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "input_placeholder_left")) {
            out.input_placeholder_left = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "input_placeholder_right")) {
            out.input_placeholder_right = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "list_selected_focused_marker")) {
            out.list_selected_focused_marker = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "list_selected_marker")) {
            out.list_selected_marker = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "list_unselected_marker")) {
            out.list_unselected_marker = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "list_selected_inverse")) {
            out.list_selected_inverse = switch (value) {
                .bool => |b| b,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "box_top_left")) {
            out.box_top_left = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "box_top_right")) {
            out.box_top_right = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "box_bottom_left")) {
            out.box_bottom_left = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "box_bottom_right")) {
            out.box_bottom_right = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "box_horizontal")) {
            out.box_horizontal = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "box_vertical")) {
            out.box_vertical = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "scrollbar_track_glyph")) {
            out.scrollbar_track_glyph = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "scrollbar_thumb_glyph")) {
            out.scrollbar_thumb_glyph = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else {
            return error.UnknownField;
        }
    }
    return out;
}

fn parseThemeOverlays(obj: std.json.ObjectMap) ParseMsgError!ThemeOverlays {
    var out: ThemeOverlays = .{};
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value_obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.WrongType,
        };
        const st = try parseStyleOverride(value_obj);
        if (std.mem.eql(u8, key, "disabled")) {
            out.disabled = st;
        } else if (std.mem.eql(u8, key, "readonly")) {
            out.readonly = st;
        } else if (std.mem.eql(u8, key, "focused")) {
            out.focused = st;
        } else if (std.mem.eql(u8, key, "hovered")) {
            out.hovered = st;
        } else if (std.mem.eql(u8, key, "active")) {
            out.active = st;
        } else if (std.mem.eql(u8, key, "validation_error")) {
            out.validation_error = st;
        } else if (std.mem.eql(u8, key, "validation_warning")) {
            out.validation_warning = st;
        } else if (std.mem.eql(u8, key, "validation_success")) {
            out.validation_success = st;
        } else {
            return error.UnknownField;
        }
    }
    return out;
}

fn isValidThemeVarName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!((name[0] >= 'A' and name[0] <= 'Z') or (name[0] >= 'a' and name[0] <= 'z'))) return false;
    for (name[1..]) |b| {
        if (!isThemeVarChar(b)) return false;
    }
    return true;
}

fn isThemeVarChar(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or
        (b >= 'a' and b <= 'z') or
        (b >= '0' and b <= '9') or
        b == '_';
}

fn validateSelector(selector: []const u8) ParseMsgError!void {
    if (selector.len == 0) return error.InvalidSelector;
    if (selector.len > theme_spec_max_selector_len) return error.ThemeSpecTooLarge;

    var i: usize = 0;
    if (selector[i] == '*') {
        i += 1;
    } else if (isIdentStart(selector[i])) {
        const start = i;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        _ = parseSelectorNodeKind(selector[start..i]) catch return error.InvalidSelector;
    }

    if (i < selector.len and selector[i] == '#') {
        i += 1;
        if (i >= selector.len or !isIdentStart(selector[i])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
    }

    while (i < selector.len and selector[i] == '.') {
        i += 1;
        if (i >= selector.len or !isClassChar(selector[i])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and selector[i] != ':' and selector[i] != '#') : (i += 1) {
            if (!isClassChar(selector[i])) return error.InvalidSelector;
        }
    }

    while (i < selector.len and selector[i] == ':') {
        i += 1;
        const start = i;
        if (start >= selector.len or !isIdentStart(selector[start])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        _ = parseSelectorState(selector[start..i]) catch return error.InvalidSelector;
    }

    if (i != selector.len) return error.InvalidSelector;
}

fn parseSelectorNodeKind(s: []const u8) error{InvalidSelector}!void {
    if (std.mem.eql(u8, s, "vbox")) return;
    if (std.mem.eql(u8, s, "hbox")) return;
    if (std.mem.eql(u8, s, "grid")) return;
    if (std.mem.eql(u8, s, "box")) return;
    if (std.mem.eql(u8, s, "scroll")) return;
    if (std.mem.eql(u8, s, "overlay")) return;
    if (std.mem.eql(u8, s, "text")) return;
    if (std.mem.eql(u8, s, "styled_text")) return;
    if (std.mem.eql(u8, s, "input")) return;
    if (std.mem.eql(u8, s, "textarea")) return;
    if (std.mem.eql(u8, s, "list")) return;
    return error.InvalidSelector;
}

fn parseSelectorState(s: []const u8) error{InvalidSelector}!void {
    if (std.mem.eql(u8, s, "hover")) return;
    if (std.mem.eql(u8, s, "focus")) return;
    if (std.mem.eql(u8, s, "active")) return;
    if (std.mem.eql(u8, s, "disabled")) return;
    if (std.mem.eql(u8, s, "readonly")) return;
    if (std.mem.eql(u8, s, "validation_error")) return;
    if (std.mem.eql(u8, s, "validation_warning")) return;
    if (std.mem.eql(u8, s, "validation_success")) return;
    return error.InvalidSelector;
}

fn isIdentStart(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_';
}

fn isIdentChar(b: u8) bool {
    return isIdentStart(b) or (b >= '0' and b <= '9') or b == '-';
}

fn isClassChar(b: u8) bool {
    return isIdentChar(b) or b == '.';
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
    if (std.mem.eql(u8, s, "input_select_left")) return .input_select_left;
    if (std.mem.eql(u8, s, "input_select_right")) return .input_select_right;
    if (std.mem.eql(u8, s, "input_select_word_left")) return .input_select_word_left;
    if (std.mem.eql(u8, s, "input_select_word_right")) return .input_select_word_right;
    if (std.mem.eql(u8, s, "input_select_home")) return .input_select_home;
    if (std.mem.eql(u8, s, "input_select_end")) return .input_select_end;
    if (std.mem.eql(u8, s, "input_select_all")) return .input_select_all;
    if (std.mem.eql(u8, s, "input_copy")) return .input_copy;
    if (std.mem.eql(u8, s, "input_paste")) return .input_paste;
    if (std.mem.eql(u8, s, "input_undo")) return .input_undo;
    if (std.mem.eql(u8, s, "input_redo")) return .input_redo;
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
    if (std.mem.eql(u8, s, "textarea_select_left")) return .textarea_select_left;
    if (std.mem.eql(u8, s, "textarea_select_right")) return .textarea_select_right;
    if (std.mem.eql(u8, s, "textarea_select_up")) return .textarea_select_up;
    if (std.mem.eql(u8, s, "textarea_select_down")) return .textarea_select_down;
    if (std.mem.eql(u8, s, "textarea_select_word_left")) return .textarea_select_word_left;
    if (std.mem.eql(u8, s, "textarea_select_word_right")) return .textarea_select_word_right;
    if (std.mem.eql(u8, s, "textarea_select_home")) return .textarea_select_home;
    if (std.mem.eql(u8, s, "textarea_select_end")) return .textarea_select_end;
    if (std.mem.eql(u8, s, "textarea_select_all")) return .textarea_select_all;
    if (std.mem.eql(u8, s, "textarea_copy")) return .textarea_copy;
    if (std.mem.eql(u8, s, "textarea_paste")) return .textarea_paste;
    if (std.mem.eql(u8, s, "textarea_undo")) return .textarea_undo;
    if (std.mem.eql(u8, s, "textarea_redo")) return .textarea_redo;
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
    const mode_val = obj.get("mode") orelse return error.MissingField;
    const mode_str = switch (mode_val) {
        .string => |s| s,
        else => return error.WrongType,
    };
    return parsePatchModeString(mode_str);
}

fn parsePatchModeString(mode_str: []const u8) ParseMsgError!PatchMode {
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

fn parseStateMode(obj: std.json.ObjectMap) ParseMsgError!StateMode {
    const s = try getOptionalString(obj, "state_mode") orelse return .uncontrolled;
    if (std.mem.eql(u8, s, "uncontrolled")) return .uncontrolled;
    if (std.mem.eql(u8, s, "init")) return .init;
    if (std.mem.eql(u8, s, "controlled")) return .controlled;
    return error.UnknownStateMode;
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
        if (scope.len == 0) return error.WrongType;
        return scope;
    }
    return null;
}

const GridPlacement = struct {
    grid_row: ?usize,
    grid_col: ?usize,
    row_span: usize,
    col_span: usize,
    grid_area: ?[]const u8,
};

fn parseGridPlacement(obj: std.json.ObjectMap) ParseMsgError!GridPlacement {
    const row_span = try getOptionalUsize(obj, "row_span") orelse 1;
    const col_span = try getOptionalUsize(obj, "col_span") orelse 1;
    if (row_span == 0 or col_span == 0) return error.WrongType;
    return .{
        .grid_row = try getOptionalUsize(obj, "grid_row"),
        .grid_col = try getOptionalUsize(obj, "grid_col"),
        .row_span = row_span,
        .col_span = col_span,
        .grid_area = try getOptionalString(obj, "grid_area"),
    };
}

fn parseGridTrack(v: std.json.Value) ParseMsgError!GridTrack {
    return switch (v) {
        .integer => |n| blk: {
            if (n < 0) return error.WrongType;
            break :blk .{ .fixed = @as(usize, @intCast(n)) };
        },
        .string => |s| blk: {
            if (std.mem.eql(u8, s, "auto")) break :blk .auto;
            if (s.len >= 2 and std.mem.endsWith(u8, s, "fr")) {
                const n = std.fmt.parseUnsigned(usize, s[0 .. s.len - 2], 10) catch return error.UnknownGridTrack;
                if (n == 0) return error.UnknownGridTrack;
                break :blk .{ .fr = n };
            }
            const fixed = std.fmt.parseUnsigned(usize, s, 10) catch return error.UnknownGridTrack;
            break :blk .{ .fixed = fixed };
        },
        else => error.WrongType,
    };
}

fn parseGridTrackArrayLeaky(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) ParseMsgError![]GridTrack {
    const raw = try getRequired(obj, field);
    const arr = try asArray(raw);
    var out = try allocator.alloc(GridTrack, arr.items.len);
    for (arr.items, 0..) |item, idx| {
        out[idx] = try parseGridTrack(item);
    }
    return out;
}

fn parseGridAreasLeaky(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseMsgError!?[]const []const u8 {
    const raw = obj.get("areas") orelse return null;
    const arr = try asArray(raw);
    var out = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, idx| {
        out[idx] = switch (item) {
            .string => |s| s,
            else => return error.WrongType,
        };
    }
    return out;
}

fn parseListMarker(obj: std.json.ObjectMap) ParseMsgError!ListMarker {
    const s = try getOptionalString(obj, "marker") orelse return .default;
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "none")) return .none;
    return error.UnknownListMarker;
}

fn parseClass(obj: std.json.ObjectMap) ParseMsgError!?[]const u8 {
    const cls = try getOptionalString(obj, "class") orelse return null;
    if (cls.len == 0) return error.WrongType;
    return cls;
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

fn parseSelectionKind(obj: std.json.ObjectMap) ParseMsgError!SelectionKind {
    const s = try getRequiredString(obj, "kind");
    if (std.mem.eql(u8, s, "document")) return .document;
    return error.UnknownField;
}

fn parseVListRangeReason(obj: std.json.ObjectMap) ParseMsgError!VListRangeReason {
    const s = try getRequiredString(obj, "reason");
    if (std.mem.eql(u8, s, "init")) return .init;
    if (std.mem.eql(u8, s, "scroll")) return .scroll;
    if (std.mem.eql(u8, s, "resize")) return .resize;
    if (std.mem.eql(u8, s, "focus")) return .focus;
    if (std.mem.eql(u8, s, "selection")) return .selection;
    return error.UnknownField;
}

fn parseMinimalTextNode(obj: std.json.ObjectMap) ParseMsgError!?Node {
    if (obj.count() != 3) return null;

    var saw_text_type = false;
    var id: ?[]const u8 = null;
    var text: ?[]const u8 = null;

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "type")) {
            const type_str = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
            if (!std.mem.eql(u8, type_str, "text")) return null;
            saw_text_type = true;
        } else if (std.mem.eql(u8, key, "id")) {
            id = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else if (std.mem.eql(u8, key, "text")) {
            text = switch (value) {
                .string => |s| s,
                else => return error.WrongType,
            };
        } else {
            return null;
        }
    }

    if (!saw_text_type) return error.MissingField;
    if (id == null or text == null) return error.MissingField;
    return .{ .text = .{
        .id = id.?,
        .text = text.?,
    } };
}

fn parseNodeLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!Node {
    const obj = try asObject(v);
    if (try parseMinimalTextNode(obj)) |node| return node;
    const type_str = try getRequiredString(obj, "type");
    if (std.mem.eql(u8, type_str, "vbox")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "pad", "clip", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "justify_content", "align_items", "gap", "align_self", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "children" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .vbox = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .children = out,
        } };
    } else if (std.mem.eql(u8, type_str, "hbox")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "pad", "clip", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "justify_content", "align_items", "gap", "align_self", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "children" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .hbox = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .children = out,
        } };
    } else if (std.mem.eql(u8, type_str, "grid")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "pad", "clip", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "align_self", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "gap_x", "gap_y", "rows", "cols", "areas", "style", "children" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const gap_x = try getOptionalUsize(obj, "gap_x") orelse 0;
        const gap_y = try getOptionalUsize(obj, "gap_y") orelse 0;
        const rows_tracks = try parseGridTrackArrayLeaky(allocator, obj, "rows");
        const cols_tracks = try parseGridTrackArrayLeaky(allocator, obj, "cols");
        const areas = try parseGridAreasLeaky(allocator, obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .grid = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .gap_x = gap_x,
            .gap_y = gap_y,
            .rows = rows_tracks,
            .cols = cols_tracks,
            .areas = areas,
            .style = st,
            .children = out,
        } };
    } else if (std.mem.eql(u8, type_str, "box")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "title", "border", "pad", "clip", "shadow", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "align_self", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "child" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const child_val = try getRequired(obj, "child");
        const child_node = try parseNodeLeaky(allocator, child_val);
        const child = try allocator.create(Node);
        child.* = child_node;
        return .{ .box = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .child = child,
        } };
    } else if (std.mem.eql(u8, type_str, "scroll")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "pad", "clip", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "align_self", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "state_mode", "scroll_y", "child" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const state_mode = try parseStateMode(obj);
        const scroll_y = try getOptionalUsize(obj, "scroll_y");
        const child_val = try getRequired(obj, "child");
        const child_node = try parseNodeLeaky(allocator, child_val);
        const child = try allocator.create(Node);
        child.* = child_node;
        return .{ .scroll = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .state_mode = state_mode,
            .scroll_y = scroll_y,
            .child = child,
        } };
    } else if (std.mem.eql(u8, type_str, "overlay")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "pad", "clip", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "align_self", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "base", "layers" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
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
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .base = base,
            .layers = layers,
        } };
    } else if (std.mem.eql(u8, type_str, "text")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "align_self", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "ext_align", "v_align", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "text" });
        const id = try getRequiredString(obj, "id");
        const text = try getRequiredString(obj, "text");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        return .{ .text = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .text = text,
        } };
    } else if (std.mem.eql(u8, type_str, "styled_text")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "align_self", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "ext_align", "v_align", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "spans" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const spans_val = try getRequired(obj, "spans");
        const spans_arr = try asArray(spans_val);
        var spans_out = try allocator.alloc(Span, spans_arr.items.len);
        for (spans_arr.items, 0..) |span_val, i| {
            spans_out[i] = try parseSpanLeaky(allocator, span_val);
        }
        return .{ .styled_text = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .spans = spans_out,
        } };
    } else if (std.mem.eql(u8, type_str, "input")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "align_self", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "content_align", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "selection_style", "placeholder_style", "placeholder", "state_mode", "value", "cursor", "scroll_x", "selection_start", "selection_end" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const sel_st = try getOptionalStyleOverride(obj, "selection_style");
        const ph_st = try getOptionalStyleOverride(obj, "placeholder_style");
        const placeholder = try getOptionalString(obj, "placeholder");
        const state_mode = try parseStateMode(obj);
        const value = try getOptionalString(obj, "value");
        const cursor = try getOptionalUsize(obj, "cursor");
        const scroll_x = try getOptionalUsize(obj, "scroll_x");
        const selection_start = try getOptionalUsize(obj, "selection_start");
        const selection_end = try getOptionalUsize(obj, "selection_end");
        return .{ .input = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .selection_style = sel_st,
            .placeholder_style = ph_st,
            .placeholder = placeholder,
            .state_mode = state_mode,
            .value = value,
            .cursor = cursor,
            .scroll_x = scroll_x,
            .selection_start = selection_start,
            .selection_end = selection_end,
        } };
    } else if (std.mem.eql(u8, type_str, "textarea")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "align_self", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "selection_style", "placeholder_style", "placeholder", "state_mode", "value", "cursor", "scroll_y", "selection_start", "selection_end" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const sel_st = try getOptionalStyleOverride(obj, "selection_style");
        const ph_st = try getOptionalStyleOverride(obj, "placeholder_style");
        const placeholder = try getOptionalString(obj, "placeholder");
        const state_mode = try parseStateMode(obj);
        const value = try getOptionalString(obj, "value");
        const cursor = try getOptionalUsize(obj, "cursor");
        const scroll_y = try getOptionalUsize(obj, "scroll_y");
        const selection_start = try getOptionalUsize(obj, "selection_start");
        const selection_end = try getOptionalUsize(obj, "selection_end");
        return .{ .textarea = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .selection_style = sel_st,
            .placeholder_style = ph_st,
            .placeholder = placeholder,
            .state_mode = state_mode,
            .value = value,
            .cursor = cursor,
            .scroll_y = scroll_y,
            .selection_start = selection_start,
            .selection_end = selection_end,
        } };
    } else if (std.mem.eql(u8, type_str, "list")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "height", "align_self", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "marker", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "state_mode", "selected_id", "scroll", "children" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const state_mode = try parseStateMode(obj);
        const selected_id = try getOptionalString(obj, "selected_id");
        const scroll = try getOptionalUsize(obj, "scroll");
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .list = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .state_mode = state_mode,
            .selected_id = selected_id,
            .scroll = scroll,
            .children = out,
        } };
    } else if (std.mem.eql(u8, type_str, "vlist")) {
        try expectOnlyFields(obj, &.{ "type", "id", "class", "w", "h", "flex", "height", "align_self", "hoverable", "mouseable", "disabled", "readonly", "validation", "focusable", "focus_scope", "marker", "grid_row", "grid_col", "row_span", "col_span", "grid_area", "style", "state_mode", "selected_index", "scroll", "total", "window_start", "item_id_prefix", "overscan", "req", "children" });
        const id = try getRequiredString(obj, "id");
        const class = try parseClass(obj);
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
        const state_mode = try parseStateMode(obj);
        const selected_index = try getOptionalUsize(obj, "selected_index");
        const scroll = try getOptionalUsize(obj, "scroll");
        const total = try getRequiredUsize(obj, "total");
        const window_start = try getRequiredUsize(obj, "window_start");
        const item_id_prefix = try getRequiredString(obj, "item_id_prefix");
        const overscan = try getOptionalUsize(obj, "overscan");
        const req = if (try getOptionalUsize(obj, "req")) |req_usize|
            try usizeToU64(req_usize)
        else
            null;
        const gp = try parseGridPlacement(obj);
        const st = try getOptionalStyleOverride(obj, "style");
        const children_val = try getRequired(obj, "children");
        const children_arr = try asArray(children_val);
        var out = try allocator.alloc(Node, children_arr.items.len);
        for (children_arr.items, 0..) |child_val, i| {
            out[i] = try parseNodeLeaky(allocator, child_val);
        }
        return .{ .vlist = .{
            .id = id,
            .class = class,
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
            .grid_row = gp.grid_row,
            .grid_col = gp.grid_col,
            .row_span = gp.row_span,
            .col_span = gp.col_span,
            .grid_area = gp.grid_area,
            .style = st,
            .state_mode = state_mode,
            .selected_index = selected_index,
            .scroll = scroll,
            .total = total,
            .window_start = window_start,
            .item_id_prefix = item_id_prefix,
            .overscan = overscan,
            .req = req,
            .children = out,
        } };
    } else {
        return error.UnknownNodeType;
    }
}

fn parseOverlayLayerLeaky(allocator: std.mem.Allocator, v: std.json.Value) ParseMsgError!OverlayLayer {
    const obj = try asObject(v);
    try expectOnlyFields(obj, &.{ "node", "anchor", "placement", "align", "offset_x", "offset_y", "w", "h", "clip", "modal" });

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
    try expectOnlyFields(obj, &.{ "text", "style" });
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
    try expectOnlyFields(obj, &.{ "fg", "bg", "bold", "dim", "italic", "underline", "blink", "inverse", "hidden", "strikethrough" });
    var out: style.StyleOverride = .{};

    if (obj.get("fg")) |v| {
        out.fg = switch (v) {
            .null => .clear,
            .string => |s| blk: {
                if (s.len >= 2 and s[0] == '$') {
                    const name = s[1..];
                    if (!isValidThemeVarName(name) or name.len > theme_spec_max_var_name_len) return error.WrongType;
                    break :blk .{ .@"var" = name };
                }
                break :blk .{ .rgb = style.parseColorSpec(s) catch return error.InvalidColor };
            },
            else => return error.WrongType,
        };
    }

    if (obj.get("bg")) |v| {
        out.bg = switch (v) {
            .null => .clear,
            .string => |s| blk: {
                if (s.len >= 2 and s[0] == '$') {
                    const name = s[1..];
                    if (!isValidThemeVarName(name) or name.len > theme_spec_max_var_name_len) return error.WrongType;
                    break :blk .{ .@"var" = name };
                }
                break :blk .{ .rgb = style.parseColorSpec(s) catch return error.InvalidColor };
            },
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

fn expectOnlyFields(obj: std.json.ObjectMap, allowed: []const []const u8) ParseMsgError!void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!containsField(allowed, key)) return error.UnknownField;
    }
}

fn containsField(allowed: []const []const u8, key: []const u8) bool {
    for (allowed) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
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
        .integer => |n| std.math.cast(usize, n) orelse return error.WrongType,
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
        .integer => |n| std.math.cast(usize, n) orelse return error.WrongType,
        else => error.WrongType,
    };
}

fn getRequiredVersion(obj: std.json.ObjectMap) ParseMsgError!u32 {
    const n = try getRequiredUsize(obj, "v");
    const version = std.math.cast(u32, n) orelse return error.WrongType;
    if (version != protocol.PROTOCOL_VERSION) return error.UnsupportedVersion;
    return version;
}

fn usizeToU64(v: usize) ParseMsgError!u64 {
    return std.math.cast(u64, v) orelse return error.WrongType;
}

fn parseAckStatusString(s: []const u8) ParseMsgError!AckStatus {
    if (std.mem.eql(u8, s, "queued")) return .queued;
    if (std.mem.eql(u8, s, "coalesced")) return .coalesced;
    if (std.mem.eql(u8, s, "applied")) return .applied;
    if (std.mem.eql(u8, s, "dropped_overflow")) return .dropped_overflow;
    if (std.mem.eql(u8, s, "dropped_stale")) return .dropped_stale;
    if (std.mem.eql(u8, s, "dropped_no_root")) return .dropped_no_root;
    if (std.mem.eql(u8, s, "dropped_not_found")) return .dropped_not_found;
    if (std.mem.eql(u8, s, "ignored_invalid")) return .ignored_invalid;
    return error.UnknownAckStatus;
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

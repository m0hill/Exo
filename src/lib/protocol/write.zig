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
const PointerEvent = protocol.PointerEvent;
const ClipboardOp = protocol.ClipboardOp;
const ClipboardTarget = protocol.ClipboardTarget;
const PasteSource = protocol.PasteSource;
const KeybindingsConfig = protocol.KeybindingsConfig;
const KeybindingRule = protocol.KeybindingRule;
const KeyAction = protocol.KeyAction;
const ThemeName = protocol.ThemeName;
const HelloCaps = protocol.HelloCaps;
const HelloLimits = protocol.HelloLimits;
const StateMode = protocol.StateMode;
const ParseMsgError = protocol.ParseMsgError;

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

fn writeVersionField(writer: anytype, v: ?u32) !void {
    if (v) |version| {
        try writer.print(",\"v\":{d}", .{version});
    }
}

pub fn writeEventJsonl(writer: anytype, key: []const u8) !void {
    return writeEventJsonlVersion(writer, key, null);
}

pub fn writeEventJsonlVersion(writer: anytype, key: []const u8, v: ?u32) !void {
    return writeKeyEventJsonlVersion(writer, key, v);
}

pub fn writeHelloEventJsonl(
    writer: anytype,
    protocol_version: u32,
    caps: HelloCaps,
    limits: HelloLimits,
) !void {
    return writeHelloEventJsonlVersion(writer, protocol_version, caps, limits, null);
}

pub fn writeHelloEventJsonlVersion(
    writer: anytype,
    protocol_version: u32,
    caps: HelloCaps,
    limits: HelloLimits,
    v: ?u32,
) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.print(",\"name\":\"hello\",\"protocol_version\":{d}", .{protocol_version});
    try writer.writeAll(",\"caps\":{");
    try writer.writeAll("\"ansi\":");
    try writer.writeAll(if (caps.ansi) "true" else "false");
    try writer.writeAll(",\"alt_screen\":");
    try writer.writeAll(if (caps.alt_screen) "true" else "false");
    try writer.writeAll(",\"bracketed_paste\":");
    try writer.writeAll(if (caps.bracketed_paste) "true" else "false");
    try writer.writeAll(",\"mouse_sgr\":");
    try writer.writeAll(if (caps.mouse_sgr) "true" else "false");
    try writer.writeAll(",\"osc52\":");
    try writer.writeAll(if (caps.osc52) "true" else "false");
    try writer.writeAll(",\"color\":");
    try writeJsonString(writer, caps.color);
    try writer.writeAll("},\"limits\":{");
    try writer.print("\"max_fps\":{d}", .{limits.max_fps});
    try writer.print(",\"frame_interval_ns\":{d}", .{limits.frame_interval_ns});
    try writer.print(",\"max_pending_targets\":{d}", .{limits.max_pending_targets});
    try writer.print(",\"max_backend_lines_per_iter\":{d}", .{limits.max_backend_lines_per_iter});
    try writer.writeAll(",\"queue_overflow\":");
    try writeJsonString(writer, limits.queue_overflow);
    try writer.writeAll("}}\n");
}

pub fn writeKeyEventJsonl(writer: anytype, key: []const u8) !void {
    return writeKeyEventJsonlVersion(writer, key, null);
}

pub fn writeKeyEventJsonlVersion(writer: anytype, key: []const u8, v: ?u32) !void {
    return writeKeyEventJsonlFullVersion(writer, key, 0, null, v);
}

pub fn writeKeyEventJsonlFull(writer: anytype, key: []const u8, mods: u8, seq: ?[]const u8) !void {
    return writeKeyEventJsonlFullVersion(writer, key, mods, seq, null);
}

pub fn writeKeyEventJsonlFullVersion(writer: anytype, key: []const u8, mods: u8, seq: ?[]const u8, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"key\",\"key\":");
    try writeJsonString(writer, key);
    if (mods != 0) {
        try writer.print(",\"mods\":{d}", .{mods});
    }
    if (seq) |s| {
        try writer.writeAll(",\"seq\":");
        try writeJsonString(writer, s);
    }
    try writer.writeAll("}\n");
}

pub fn writeFocusEventJsonl(writer: anytype, id: []const u8) !void {
    return writeFocusEventJsonlVersion(writer, id, null);
}

pub fn writeFocusEventJsonlVersion(writer: anytype, id: []const u8, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"focus\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll("}\n");
}

pub fn writeInputEventJsonl(writer: anytype, id: []const u8, value: []const u8, cursor: usize) !void {
    return writeInputEventJsonlVersion(writer, id, value, cursor, null);
}

pub fn writeInputEventJsonlVersion(writer: anytype, id: []const u8, value: []const u8, cursor: usize, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"input\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"value\":");
    try writeJsonString(writer, value);
    try writer.print(",\"cursor\":{d}}}\n", .{cursor});
}

pub fn writeSelectEventJsonl(writer: anytype, id: []const u8, item: []const u8) !void {
    return writeSelectEventJsonlVersion(writer, id, item, null);
}

pub fn writeSelectEventJsonlVersion(writer: anytype, id: []const u8, item: []const u8, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"select\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"item\":");
    try writeJsonString(writer, item);
    try writer.writeAll("}\n");
}

pub fn writeActivateEventJsonl(writer: anytype, id: []const u8, item: []const u8) !void {
    return writeActivateEventJsonlVersion(writer, id, item, null);
}

pub fn writeActivateEventJsonlVersion(writer: anytype, id: []const u8, item: []const u8, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"activate\",\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"item\":");
    try writeJsonString(writer, item);
    try writer.writeAll("}\n");
}

pub fn writeScrollEventJsonl(writer: anytype, id: []const u8, scroll_y: usize) !void {
    return writeScrollEventJsonlVersion(writer, id, scroll_y, null);
}

pub fn writeScrollEventJsonlVersion(writer: anytype, id: []const u8, scroll_y: usize, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"scroll\",\"id\":");
    try writeJsonString(writer, id);
    try writer.print(",\"scroll_y\":{d}}}\n", .{scroll_y});
}

pub fn writeResizeEventJsonl(writer: anytype, rows: usize, cols: usize) !void {
    return writeResizeEventJsonlVersion(writer, rows, cols, null);
}

pub fn writeResizeEventJsonlVersion(writer: anytype, rows: usize, cols: usize, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.print(",\"name\":\"resize\",\"rows\":{d},\"cols\":{d}}}\n", .{ rows, cols });
}

pub fn writeHoverEventJsonl(writer: anytype, id: []const u8, x: usize, y: usize, item: ?[]const u8) !void {
    return writeHoverEventJsonlVersion(writer, id, x, y, item, null);
}

pub fn writeHoverEventJsonlVersion(writer: anytype, id: []const u8, x: usize, y: usize, item: ?[]const u8, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"hover\",\"id\":");
    try writeJsonString(writer, id);
    try writer.print(",\"x\":{d},\"y\":{d}", .{ x, y });
    if (item) |it| {
        try writer.writeAll(",\"item\":");
        try writeJsonString(writer, it);
    }
    try writer.writeAll("}\n");
}

pub fn writePointerEventJsonl(writer: anytype, ev: PointerEvent) !void {
    return writePointerEventJsonlVersion(writer, ev, null);
}

pub fn writePointerEventJsonlVersion(writer: anytype, ev: PointerEvent, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v orelse ev.v);
    try writer.writeAll(",\"name\":\"pointer\",\"kind\":");
    try writeJsonString(writer, switch (ev.kind) {
        .down => "down",
        .up => "up",
        .move => "move",
        .drag => "drag",
        .scroll => "scroll",
    });
    try writer.writeAll(",\"id\":");
    try writeJsonString(writer, ev.id);
    try writer.print(
        ",\"x\":{d},\"y\":{d},\"local_x\":{d},\"local_y\":{d}",
        .{ ev.x, ev.y, ev.local_x, ev.local_y },
    );
    try writer.writeAll(",\"button\":");
    try writeJsonString(writer, switch (ev.button) {
        .left => "left",
        .middle => "middle",
        .right => "right",
        .none => "none",
    });
    try writer.print(",\"buttons\":{d},\"mods\":{d},\"clicks\":{d}", .{ ev.buttons, ev.mods, ev.clicks });
    try writer.print(",\"scroll_dx\":{d},\"scroll_dy\":{d}", .{ ev.scroll_dx, ev.scroll_dy });
    if (ev.item) |it| {
        try writer.writeAll(",\"item\":");
        try writeJsonString(writer, it);
    }
    try writer.writeAll(",\"captured\":");
    try writer.writeAll(if (ev.captured) "true" else "false");
    try writer.writeAll("}\n");
}

pub fn writeClipboardWriteJsonl(writer: anytype, data: []const u8, target: ClipboardTarget) !void {
    return writeClipboardWriteJsonlVersion(writer, data, target, null);
}

pub fn writeClipboardWriteJsonlVersion(writer: anytype, data: []const u8, target: ClipboardTarget, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"clipboard\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"op\":\"write\",\"data\":");
    try writeJsonString(writer, data);
    if (target != .clipboard) {
        try writer.writeAll(",\"target\":");
        try writeJsonString(writer, "clipboard");
    }
    try writer.writeAll("}\n");
}

pub fn writeClipboardReadJsonl(writer: anytype, request_id: u32, target: ClipboardTarget) !void {
    return writeClipboardReadJsonlVersion(writer, request_id, target, null);
}

pub fn writeClipboardReadJsonlVersion(writer: anytype, request_id: u32, target: ClipboardTarget, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"clipboard\"");
    try writeVersionField(writer, v);
    try writer.print(",\"op\":\"read\",\"request_id\":{d}", .{request_id});
    if (target != .clipboard) {
        try writer.writeAll(",\"target\":");
        try writeJsonString(writer, "clipboard");
    }
    try writer.writeAll("}\n");
}

pub fn writeClipboardEventJsonl(
    writer: anytype,
    op: ClipboardOp,
    ok: bool,
    request_id: u32,
    data: ?[]const u8,
    reason: ?[]const u8,
) !void {
    return writeClipboardEventJsonlVersion(writer, op, ok, request_id, data, reason, null);
}

pub fn writeClipboardEventJsonlVersion(
    writer: anytype,
    op: ClipboardOp,
    ok: bool,
    request_id: u32,
    data: ?[]const u8,
    reason: ?[]const u8,
    v: ?u32,
) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"clipboard\",\"op\":");
    try writeJsonString(writer, switch (op) {
        .write => "write",
        .read => "read",
    });
    try writer.writeAll(",\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    if (request_id != 0) {
        try writer.print(",\"request_id\":{d}", .{request_id});
    }
    if (data) |d| {
        try writer.writeAll(",\"data\":");
        try writeJsonString(writer, d);
    }
    if (reason) |r| {
        try writer.writeAll(",\"reason\":");
        try writeJsonString(writer, r);
    }
    try writer.writeAll("}\n");
}

pub fn writePasteEventJsonl(writer: anytype, source: PasteSource, bytes: usize) !void {
    return writePasteEventJsonlVersion(writer, source, bytes, null);
}

pub fn writePasteEventJsonlVersion(writer: anytype, source: PasteSource, bytes: usize, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":\"paste\",\"source\":");
    try writeJsonString(writer, switch (source) {
        .bracketed => "bracketed",
        .clipboard => "clipboard",
    });
    try writer.print(",\"bytes\":{d}}}\n", .{bytes});
}

pub fn writeRenderedEventJsonl(
    writer: anytype,
    seq: u64,
    dropped: u64,
    bytes: usize,
    changed_cells: usize,
) !void {
    return writeRenderedEventJsonlVersion(writer, seq, dropped, bytes, changed_cells, null);
}

pub fn writeRenderedEventJsonlVersion(
    writer: anytype,
    seq: u64,
    dropped: u64,
    bytes: usize,
    changed_cells: usize,
    v: ?u32,
) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.print(
        ",\"name\":\"rendered\",\"seq\":{d},\"dropped\":{d},\"bytes\":{d},\"changed_cells\":{d}}}\n",
        .{ seq, dropped, bytes, changed_cells },
    );
}

pub fn writeDroppedEventJsonl(writer: anytype, seq: u64, reason: []const u8) !void {
    return writeDroppedEventJsonlVersion(writer, seq, reason, null);
}

pub fn writeDroppedEventJsonlVersion(writer: anytype, seq: u64, reason: []const u8, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"event\"");
    try writeVersionField(writer, v);
    try writer.print(",\"name\":\"dropped\",\"seq\":{d},\"reason\":", .{seq});
    try writeJsonString(writer, reason);
    try writer.writeAll("}\n");
}

pub fn writeConfigJsonl(writer: anytype, cfg: protocol.ConfigMsg) !void {
    return writeConfigJsonlVersion(writer, cfg, null);
}

pub fn writeConfigJsonlVersion(writer: anytype, cfg: protocol.ConfigMsg, v: ?u32) !void {
    if (cfg.keybindings == null and cfg.theme == null) return ParseMsgError.MissingField;
    try writer.writeAll("{\"type\":\"config\"");
    try writeVersionField(writer, v orelse cfg.v);
    if (cfg.keybindings) |kb| {
        try writer.writeAll(",\"keybindings\":{");
        var wrote_context = false;
        try writeKeybindingContext(writer, "global", kb.global, &wrote_context);
        try writeKeybindingContext(writer, "input", kb.input, &wrote_context);
        try writeKeybindingContext(writer, "textarea", kb.textarea, &wrote_context);
        try writeKeybindingContext(writer, "list", kb.list, &wrote_context);
        try writeKeybindingContext(writer, "scroll", kb.scroll, &wrote_context);
        try writeKeybindingContext(writer, "action", kb.action, &wrote_context);
        try writer.writeByte('}');
    }
    if (cfg.theme) |theme| {
        try writer.writeAll(",\"theme\":");
        try writeJsonString(writer, switch (theme) {
            .default => "default",
            .light => "light",
            .ocean => "ocean",
        });
    }
    try writer.writeAll("}\n");
}

pub fn writeThemeJsonl(writer: anytype, name: ThemeName) !void {
    return writeThemeJsonlVersion(writer, name, null);
}

pub fn writeThemeJsonlVersion(writer: anytype, name: ThemeName, v: ?u32) !void {
    try writer.writeAll("{\"type\":\"theme\"");
    try writeVersionField(writer, v);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, switch (name) {
        .default => "default",
        .light => "light",
        .ocean => "ocean",
    });
    try writer.writeAll("}\n");
}

fn writeKeybindingContext(
    writer: anytype,
    name: []const u8,
    rules_opt: ?[]const KeybindingRule,
    wrote_context: *bool,
) !void {
    const rules = rules_opt orelse return;
    if (wrote_context.*) try writer.writeByte(',');
    wrote_context.* = true;
    try writeJsonString(writer, name);
    try writer.writeAll(":[");
    for (rules, 0..) |rule, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, rule.key);
        if (rule.mods != 0) {
            try writer.print(",\"mods\":{d}", .{rule.mods});
        }
        try writer.writeAll(",\"action\":");
        try writeJsonString(writer, keyActionString(rule.action));
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn keyActionString(action: KeyAction) []const u8 {
    return switch (action) {
        .noop => "noop",
        .focus_next => "focus_next",
        .focus_prev => "focus_prev",
        .focus_scope_next => "focus_scope_next",
        .focus_scope_prev => "focus_scope_prev",
        .focus_clear => "focus_clear",
        .list_prev => "list_prev",
        .list_next => "list_next",
        .list_activate => "list_activate",
        .scroll_line_up => "scroll_line_up",
        .scroll_line_down => "scroll_line_down",
        .scroll_page_up => "scroll_page_up",
        .scroll_page_down => "scroll_page_down",
        .scroll_home => "scroll_home",
        .scroll_end => "scroll_end",
        .action_activate => "action_activate",
        .input_left => "input_left",
        .input_right => "input_right",
        .input_word_left => "input_word_left",
        .input_word_right => "input_word_right",
        .input_home => "input_home",
        .input_end => "input_end",
        .input_delete => "input_delete",
        .input_backspace => "input_backspace",
        .input_select_left => "input_select_left",
        .input_select_right => "input_select_right",
        .input_select_word_left => "input_select_word_left",
        .input_select_word_right => "input_select_word_right",
        .input_select_home => "input_select_home",
        .input_select_end => "input_select_end",
        .input_select_all => "input_select_all",
        .input_copy => "input_copy",
        .input_paste => "input_paste",
        .input_undo => "input_undo",
        .input_redo => "input_redo",
        .textarea_left => "textarea_left",
        .textarea_right => "textarea_right",
        .textarea_up => "textarea_up",
        .textarea_down => "textarea_down",
        .textarea_word_left => "textarea_word_left",
        .textarea_word_right => "textarea_word_right",
        .textarea_home => "textarea_home",
        .textarea_end => "textarea_end",
        .textarea_page_up => "textarea_page_up",
        .textarea_page_down => "textarea_page_down",
        .textarea_delete => "textarea_delete",
        .textarea_backspace => "textarea_backspace",
        .textarea_newline => "textarea_newline",
        .textarea_select_left => "textarea_select_left",
        .textarea_select_right => "textarea_select_right",
        .textarea_select_up => "textarea_select_up",
        .textarea_select_down => "textarea_select_down",
        .textarea_select_word_left => "textarea_select_word_left",
        .textarea_select_word_right => "textarea_select_word_right",
        .textarea_select_home => "textarea_select_home",
        .textarea_select_end => "textarea_select_end",
        .textarea_select_all => "textarea_select_all",
        .textarea_copy => "textarea_copy",
        .textarea_paste => "textarea_paste",
        .textarea_undo => "textarea_undo",
        .textarea_redo => "textarea_redo",
    };
}

fn writeWidgetStateFields(
    writer: anytype,
    disabled: bool,
    readonly: bool,
    validation: protocol.ValidationState,
    focusable: bool,
    focusable_default: bool,
    focus_scope: ?[]const u8,
) !void {
    if (disabled) try writer.writeAll(",\"disabled\":true");
    if (readonly) try writer.writeAll(",\"readonly\":true");
    if (validation != .none) {
        try writer.writeAll(",\"validation\":");
        try writeJsonString(writer, switch (validation) {
            .none => "none",
            .@"error" => "error",
            .warning => "warning",
            .success => "success",
        });
    }
    if (focusable != focusable_default) {
        try writer.writeAll(",\"focusable\":");
        try writer.writeAll(if (focusable) "true" else "false");
    }
    if (focus_scope) |scope| {
        if (scope.len > 0) {
            try writer.writeAll(",\"focus_scope\":");
            try writeJsonString(writer, scope);
        }
    }
}

fn writeClassField(writer: anytype, class: ?[]const u8) !void {
    const cls = class orelse return;
    if (cls.len == 0) return;
    try writer.writeAll(",\"class\":");
    try writeJsonString(writer, cls);
}

fn writeGridPlacementFields(
    writer: anytype,
    grid_row: ?usize,
    grid_col: ?usize,
    row_span: usize,
    col_span: usize,
    grid_area: ?[]const u8,
) !void {
    if (grid_row) |v| try writer.print(",\"grid_row\":{d}", .{v});
    if (grid_col) |v| try writer.print(",\"grid_col\":{d}", .{v});
    if (row_span != 1) try writer.print(",\"row_span\":{d}", .{row_span});
    if (col_span != 1) try writer.print(",\"col_span\":{d}", .{col_span});
    if (grid_area) |a| {
        if (a.len > 0) {
            try writer.writeAll(",\"grid_area\":");
            try writeJsonString(writer, a);
        }
    }
}

fn writeStateModeField(writer: anytype, mode: StateMode) !void {
    if (mode == .uncontrolled) return;
    try writer.writeAll(",\"state_mode\":");
    try writeJsonString(writer, switch (mode) {
        .uncontrolled => "uncontrolled",
        .init => "init",
        .controlled => "controlled",
    });
}

fn writeGridTrackJson(writer: anytype, t: GridTrack) !void {
    switch (t) {
        .fixed => |v| try writer.print("{d}", .{v}),
        .auto => try writeJsonString(writer, "auto"),
        .fr => |v| try writer.print("\"{d}fr\"", .{v}),
    }
}

pub fn writeNodeJson(writer: anytype, node: Node) !void {
    switch (node) {
        .vbox => |v| {
            try writer.writeAll("{\"type\":\"vbox\",\"id\":");
            try writeJsonString(writer, v.id);
            try writeClassField(writer, v.class);
            if (v.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (v.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (v.flex != 0) try writer.print(",\"flex\":{d}", .{v.flex});
            if (v.pad != 0) try writer.print(",\"pad\":{d}", .{v.pad});
            if (v.clip) try writer.writeAll(",\"clip\":true");
            if (v.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (v.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, v.disabled, v.readonly, v.validation, v.focusable, false, v.focus_scope);
            if (v.justify_content != .start) {
                try writer.writeAll(",\"justify_content\":");
                try writeJsonString(writer, switch (v.justify_content) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .space_between => "space_between",
                    .space_around => "space_around",
                    .space_evenly => "space_evenly",
                });
            }
            if (v.align_items != .stretch) {
                try writer.writeAll(",\"align_items\":");
                try writeJsonString(writer, switch (v.align_items) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (v.gap != 0) try writer.print(",\"gap\":{d}", .{v.gap});
            if (v.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            try writeGridPlacementFields(writer, v.grid_row, v.grid_col, v.row_span, v.col_span, v.grid_area);
            if (v.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"children\":[");
            for (v.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
        .hbox => |h| {
            try writer.writeAll("{\"type\":\"hbox\",\"id\":");
            try writeJsonString(writer, h.id);
            try writeClassField(writer, h.class);
            if (h.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (h.h) |hh| try writer.print(",\"h\":{d}", .{hh});
            if (h.flex != 0) try writer.print(",\"flex\":{d}", .{h.flex});
            if (h.pad != 0) try writer.print(",\"pad\":{d}", .{h.pad});
            if (h.clip) try writer.writeAll(",\"clip\":true");
            if (h.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (h.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, h.disabled, h.readonly, h.validation, h.focusable, false, h.focus_scope);
            if (h.justify_content != .start) {
                try writer.writeAll(",\"justify_content\":");
                try writeJsonString(writer, switch (h.justify_content) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .space_between => "space_between",
                    .space_around => "space_around",
                    .space_evenly => "space_evenly",
                });
            }
            if (h.align_items != .stretch) {
                try writer.writeAll(",\"align_items\":");
                try writeJsonString(writer, switch (h.align_items) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (h.gap != 0) try writer.print(",\"gap\":{d}", .{h.gap});
            if (h.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            try writeGridPlacementFields(writer, h.grid_row, h.grid_col, h.row_span, h.col_span, h.grid_area);
            if (h.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"children\":[");
            for (h.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
        .grid => |g| {
            try writer.writeAll("{\"type\":\"grid\",\"id\":");
            try writeJsonString(writer, g.id);
            try writeClassField(writer, g.class);
            if (g.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (g.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (g.flex != 0) try writer.print(",\"flex\":{d}", .{g.flex});
            if (g.pad != 0) try writer.print(",\"pad\":{d}", .{g.pad});
            if (g.clip) try writer.writeAll(",\"clip\":true");
            if (g.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (g.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, g.disabled, g.readonly, g.validation, g.focusable, false, g.focus_scope);
            if (g.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            try writeGridPlacementFields(writer, g.grid_row, g.grid_col, g.row_span, g.col_span, g.grid_area);
            if (g.gap_x != 0) try writer.print(",\"gap_x\":{d}", .{g.gap_x});
            if (g.gap_y != 0) try writer.print(",\"gap_y\":{d}", .{g.gap_y});
            try writer.writeAll(",\"rows\":[");
            for (g.rows, 0..) |t, i| {
                if (i != 0) try writer.writeByte(',');
                try writeGridTrackJson(writer, t);
            }
            try writer.writeAll("],\"cols\":[");
            for (g.cols, 0..) |t, i| {
                if (i != 0) try writer.writeByte(',');
                try writeGridTrackJson(writer, t);
            }
            try writer.writeByte(']');
            if (g.areas) |areas| {
                try writer.writeAll(",\"areas\":[");
                for (areas, 0..) |row, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writeJsonString(writer, row);
                }
                try writer.writeByte(']');
            }
            if (g.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"children\":[");
            for (g.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
        .box => |b| {
            try writer.writeAll("{\"type\":\"box\",\"id\":");
            try writeJsonString(writer, b.id);
            try writeClassField(writer, b.class);
            if (b.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (b.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (b.flex != 0) try writer.print(",\"flex\":{d}", .{b.flex});
            if (b.title) |t| {
                try writer.writeAll(",\"title\":");
                try writeJsonString(writer, t);
            }
            if (!b.border) try writer.writeAll(",\"border\":false");
            if (b.pad != 0) try writer.print(",\"pad\":{d}", .{b.pad});
            if (!b.clip) try writer.writeAll(",\"clip\":false");
            if (b.shadow) try writer.writeAll(",\"shadow\":true");
            if (b.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (b.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, b.disabled, b.readonly, b.validation, b.focusable, false, b.focus_scope);
            if (b.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            try writeGridPlacementFields(writer, b.grid_row, b.grid_col, b.row_span, b.col_span, b.grid_area);
            if (b.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"child\":");
            try writeNodeJson(writer, b.child.*);
            try writer.writeByte('}');
        },
        .scroll => |s| {
            try writer.writeAll("{\"type\":\"scroll\",\"id\":");
            try writeJsonString(writer, s.id);
            try writeClassField(writer, s.class);
            if (s.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (s.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (s.flex != 0) try writer.print(",\"flex\":{d}", .{s.flex});
            if (s.pad != 0) try writer.print(",\"pad\":{d}", .{s.pad});
            if (!s.clip) try writer.writeAll(",\"clip\":false");
            if (s.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (s.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, s.disabled, s.readonly, s.validation, s.focusable, true, s.focus_scope);
            if (s.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            try writeGridPlacementFields(writer, s.grid_row, s.grid_col, s.row_span, s.col_span, s.grid_area);
            if (s.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writeStateModeField(writer, s.state_mode);
            if (s.scroll_y) |scroll_y| try writer.print(",\"scroll_y\":{d}", .{scroll_y});
            try writer.writeAll(",\"child\":");
            try writeNodeJson(writer, s.child.*);
            try writer.writeByte('}');
        },
        .overlay => |o| {
            try writer.writeAll("{\"type\":\"overlay\",\"id\":");
            try writeJsonString(writer, o.id);
            try writeClassField(writer, o.class);
            if (o.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (o.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (o.flex != 0) try writer.print(",\"flex\":{d}", .{o.flex});
            if (o.pad != 0) try writer.print(",\"pad\":{d}", .{o.pad});
            if (o.clip) try writer.writeAll(",\"clip\":true");
            if (o.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (o.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, o.disabled, o.readonly, o.validation, o.focusable, false, o.focus_scope);
            if (o.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            try writeGridPlacementFields(writer, o.grid_row, o.grid_col, o.row_span, o.col_span, o.grid_area);
            if (o.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"base\":");
            try writeNodeJson(writer, o.base.*);
            try writer.writeAll(",\"layers\":[");
            for (o.layers, 0..) |layer, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeAll("{\"node\":");
                try writeNodeJson(writer, layer.node.*);
                if (layer.anchor) |a| {
                    try writer.writeAll(",\"anchor\":");
                    try writeJsonString(writer, a);
                }
                try writer.writeAll(",\"placement\":");
                try writeJsonString(writer, switch (layer.placement) {
                    .below => "below",
                    .above => "above",
                    .right => "right",
                    .left => "left",
                    .center => "center",
                });
                if (layer.align_ != .start) {
                    try writer.writeAll(",\"align\":");
                    try writeJsonString(writer, switch (layer.align_) {
                        .start => "start",
                        .center => "center",
                        .end => "end",
                    });
                }
                if (layer.offset_x != 0) try writer.print(",\"offset_x\":{d}", .{layer.offset_x});
                if (layer.offset_y != 0) try writer.print(",\"offset_y\":{d}", .{layer.offset_y});
                if (layer.w) |w| try writer.print(",\"w\":{d}", .{w});
                if (layer.h) |h| try writer.print(",\"h\":{d}", .{h});
                if (!layer.clip) try writer.writeAll(",\"clip\":false");
                if (layer.modal) try writer.writeAll(",\"modal\":true");
                try writer.writeByte('}');
            }
            try writer.writeAll("]}");
        },
        .text => |t| {
            try writer.writeAll("{\"type\":\"text\",\"id\":");
            try writeJsonString(writer, t.id);
            try writeClassField(writer, t.class);
            if (t.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (t.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (t.flex != 0) try writer.print(",\"flex\":{d}", .{t.flex});
            if (t.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (t.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (t.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, t.disabled, t.readonly, t.validation, t.focusable, false, t.focus_scope);
            if (t.ext_align != .left) {
                try writer.writeAll(",\"ext_align\":");
                try writeJsonString(writer, switch (t.ext_align) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                });
            }
            if (t.v_align != .top) {
                try writer.writeAll(",\"v_align\":");
                try writeJsonString(writer, switch (t.v_align) {
                    .top => "top",
                    .center => "center",
                    .bottom => "bottom",
                });
            }
            try writeGridPlacementFields(writer, t.grid_row, t.grid_col, t.row_span, t.col_span, t.grid_area);
            if (t.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"text\":");
            try writeJsonString(writer, t.text);
            try writer.writeByte('}');
        },
        .styled_text => |t| {
            try writer.writeAll("{\"type\":\"styled_text\",\"id\":");
            try writeJsonString(writer, t.id);
            try writeClassField(writer, t.class);
            if (t.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (t.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (t.flex != 0) try writer.print(",\"flex\":{d}", .{t.flex});
            if (t.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (t.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (t.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, t.disabled, t.readonly, t.validation, t.focusable, false, t.focus_scope);
            if (t.ext_align != .left) {
                try writer.writeAll(",\"ext_align\":");
                try writeJsonString(writer, switch (t.ext_align) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                });
            }
            if (t.v_align != .top) {
                try writer.writeAll(",\"v_align\":");
                try writeJsonString(writer, switch (t.v_align) {
                    .top => "top",
                    .center => "center",
                    .bottom => "bottom",
                });
            }
            try writeGridPlacementFields(writer, t.grid_row, t.grid_col, t.row_span, t.col_span, t.grid_area);
            if (t.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writer.writeAll(",\"spans\":[");
            for (t.spans, 0..) |sp, i| {
                if (i != 0) try writer.writeByte(',');
                try writeSpanJson(writer, sp);
            }
            try writer.writeAll("]}");
        },
        .input => |inp| {
            try writer.writeAll("{\"type\":\"input\",\"id\":");
            try writeJsonString(writer, inp.id);
            try writeClassField(writer, inp.class);
            if (inp.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (inp.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (inp.flex != 0) try writer.print(",\"flex\":{d}", .{inp.flex});
            if (inp.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (inp.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (inp.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, inp.disabled, inp.readonly, inp.validation, inp.focusable, true, inp.focus_scope);
            if (inp.content_align != .left) {
                try writer.writeAll(",\"content_align\":");
                try writeJsonString(writer, switch (inp.content_align) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                });
            }
            try writeGridPlacementFields(writer, inp.grid_row, inp.grid_col, inp.row_span, inp.col_span, inp.grid_area);
            if (inp.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (inp.selection_style) |st| {
                try writer.writeAll(",\"selection_style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (inp.placeholder_style) |st| {
                try writer.writeAll(",\"placeholder_style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (inp.placeholder) |ph| {
                try writer.writeAll(",\"placeholder\":");
                try writeJsonString(writer, ph);
            }
            try writeStateModeField(writer, inp.state_mode);
            if (inp.value) |value| {
                try writer.writeAll(",\"value\":");
                try writeJsonString(writer, value);
            }
            if (inp.cursor) |cursor| try writer.print(",\"cursor\":{d}", .{cursor});
            if (inp.scroll_x) |scroll_x| try writer.print(",\"scroll_x\":{d}", .{scroll_x});
            if (inp.selection_start) |selection_start| try writer.print(",\"selection_start\":{d}", .{selection_start});
            if (inp.selection_end) |selection_end| try writer.print(",\"selection_end\":{d}", .{selection_end});
            try writer.writeByte('}');
        },
        .textarea => |ta| {
            try writer.writeAll("{\"type\":\"textarea\",\"id\":");
            try writeJsonString(writer, ta.id);
            try writeClassField(writer, ta.class);
            if (ta.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (ta.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (ta.flex != 0) try writer.print(",\"flex\":{d}", .{ta.flex});
            if (ta.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (ta.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (ta.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, ta.disabled, ta.readonly, ta.validation, ta.focusable, true, ta.focus_scope);
            try writeGridPlacementFields(writer, ta.grid_row, ta.grid_col, ta.row_span, ta.col_span, ta.grid_area);
            if (ta.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (ta.selection_style) |st| {
                try writer.writeAll(",\"selection_style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (ta.placeholder_style) |st| {
                try writer.writeAll(",\"placeholder_style\":");
                try writeStyleOverrideJson(writer, st);
            }
            if (ta.placeholder) |ph| {
                try writer.writeAll(",\"placeholder\":");
                try writeJsonString(writer, ph);
            }
            try writeStateModeField(writer, ta.state_mode);
            if (ta.value) |value| {
                try writer.writeAll(",\"value\":");
                try writeJsonString(writer, value);
            }
            if (ta.cursor) |cursor| try writer.print(",\"cursor\":{d}", .{cursor});
            if (ta.scroll_y) |scroll_y| try writer.print(",\"scroll_y\":{d}", .{scroll_y});
            if (ta.selection_start) |selection_start| try writer.print(",\"selection_start\":{d}", .{selection_start});
            if (ta.selection_end) |selection_end| try writer.print(",\"selection_end\":{d}", .{selection_end});
            try writer.writeByte('}');
        },
        .list => |l| {
            try writer.writeAll("{\"type\":\"list\",\"id\":");
            try writeJsonString(writer, l.id);
            try writeClassField(writer, l.class);
            if (l.w) |w| try writer.print(",\"w\":{d}", .{w});
            if (l.h) |h| try writer.print(",\"h\":{d}", .{h});
            if (l.flex != 0) try writer.print(",\"flex\":{d}", .{l.flex});
            if (l.height) |height| try writer.print(",\"height\":{d}", .{height});
            if (l.align_self) |as| {
                try writer.writeAll(",\"align_self\":");
                try writeJsonString(writer, switch (as) {
                    .start => "start",
                    .center => "center",
                    .end => "end",
                    .stretch => "stretch",
                });
            }
            if (l.hoverable) try writer.writeAll(",\"hoverable\":true");
            if (l.mouseable) try writer.writeAll(",\"mouseable\":true");
            try writeWidgetStateFields(writer, l.disabled, l.readonly, l.validation, l.focusable, true, l.focus_scope);
            if (l.marker != .default) {
                try writer.writeAll(",\"marker\":");
                try writeJsonString(writer, switch (l.marker) {
                    .default => "default",
                    .none => "none",
                });
            }
            try writeGridPlacementFields(writer, l.grid_row, l.grid_col, l.row_span, l.col_span, l.grid_area);
            if (l.style) |st| {
                try writer.writeAll(",\"style\":");
                try writeStyleOverrideJson(writer, st);
            }
            try writeStateModeField(writer, l.state_mode);
            if (l.selected_id) |selected_id| {
                try writer.writeAll(",\"selected_id\":");
                try writeJsonString(writer, selected_id);
            }
            if (l.scroll) |scroll| try writer.print(",\"scroll\":{d}", .{scroll});
            try writer.writeAll(",\"children\":[");
            for (l.children, 0..) |child, i| {
                if (i != 0) try writer.writeByte(',');
                try writeNodeJson(writer, child);
            }
            try writer.writeAll("]}");
        },
    }
}

pub fn writeSpanJson(writer: anytype, sp: Span) !void {
    try writer.writeAll("{\"text\":");
    try writeJsonString(writer, sp.text);
    if (sp.style) |st| {
        try writer.writeAll(",\"style\":");
        try writeStyleOverrideJson(writer, st);
    }
    try writer.writeByte('}');
}

pub fn writeStyleOverrideJson(writer: anytype, st: style.StyleOverride) !void {
    var first: bool = true;
    try writer.writeByte('{');

    switch (st.fg) {
        .inherit => {},
        .clear => {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"fg\":null");
        },
        .rgb => |c| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"fg\":");
            try writeRgbHexJsonString(writer, c);
        },
    }

    switch (st.bg) {
        .inherit => {},
        .clear => {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"bg\":null");
        },
        .rgb => |c| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"bg\":");
            try writeRgbHexJsonString(writer, c);
        },
    }

    try writeStyleAttr(writer, "bold", style.ATTR_BOLD, st, &first);
    try writeStyleAttr(writer, "dim", style.ATTR_DIM, st, &first);
    try writeStyleAttr(writer, "italic", style.ATTR_ITALIC, st, &first);
    try writeStyleAttr(writer, "underline", style.ATTR_UNDERLINE, st, &first);
    try writeStyleAttr(writer, "blink", style.ATTR_BLINK, st, &first);
    try writeStyleAttr(writer, "inverse", style.ATTR_INVERSE, st, &first);
    try writeStyleAttr(writer, "hidden", style.ATTR_HIDDEN, st, &first);
    try writeStyleAttr(writer, "strikethrough", style.ATTR_STRIKETHROUGH, st, &first);

    try writer.writeByte('}');
}

fn writeStyleAttr(
    writer: anytype,
    key: []const u8,
    bit: u8,
    st: style.StyleOverride,
    first: *bool,
) !void {
    if ((st.attrs_set & bit) == 0) return;
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    const value = (st.attrs_values & bit) != 0;
    if (value) {
        try writer.print("\"{s}\":true", .{key});
    } else {
        try writer.print("\"{s}\":false", .{key});
    }
}

fn writeRgbHexJsonString(writer: anytype, c: style.Rgb) !void {
    const u: u24 = (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | @as(u24, c.b);
    try writer.print("\"#{X:0>6}\"", .{u});
}

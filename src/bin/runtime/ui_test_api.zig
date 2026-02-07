const std = @import("std");
const ui = @import("ui/mod.zig");
const keybindings = @import("keybindings.zig");

pub const pointer = ui.pointer;
pub const WidgetEntry = ui.WidgetEntry;
pub const deinitWidgetEntries = ui.deinitWidgetEntries;
pub const handleFocusedInputKey = ui.handleFocusedInputKey;
pub const handleFocusedTextareaKey = ui.handleFocusedTextareaKey;
pub const applyInputAction = ui.applyInputAction;
pub const applyTextareaAction = ui.applyTextareaAction;
pub const inputSelectedTextAlloc = ui.inputSelectedTextAlloc;
pub const textareaSelectedTextAlloc = ui.textareaSelectedTextAlloc;
pub const cycleFocusInTreeDir = ui.cycleFocusInTreeDir;
pub const cycleFocusScopeInTreeDir = ui.cycleFocusScopeInTreeDir;
pub const syncUiAfterPatch = ui.syncUiAfterPatch;
pub const setFocusId = ui.setFocusId;
pub const KeymapState = keybindings.KeymapState;
pub const KeyContext = keybindings.Context;
pub const makeNoopLogSink = ui.makeNoopLogSink;

pub fn applyListAction(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: @import("tui").protocol.Node,
    rows: usize,
    cols: usize,
    list_id: []const u8,
    action: @import("tui").protocol.KeyAction,
) !bool {
    var sink = ui.makeNoopLogSink();
    return ui.applyListAction(allocator, &sink, backend_in, widgets, root, rows, cols, list_id, action);
}

pub fn applyScrollAction(
    allocator: std.mem.Allocator,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: @import("tui").protocol.Node,
    rows: usize,
    cols: usize,
    scroll_id: []const u8,
    action: @import("tui").protocol.KeyAction,
) !bool {
    var sink = ui.makeNoopLogSink();
    return ui.applyScrollAction(allocator, &sink, backend_in, widgets, root, rows, cols, scroll_id, action);
}

pub fn applyActionWidgetAction(backend_in: anytype, id: []const u8, action: @import("tui").protocol.KeyAction) !bool {
    var sink = ui.makeNoopLogSink();
    return ui.applyActionWidgetAction(&sink, backend_in, id, action);
}

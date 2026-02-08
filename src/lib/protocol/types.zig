const std = @import("std");
const style = @import("../style.zig");

pub const Msg = union(enum) {
    patch: PatchMsg,
    event: EventMsg,
    clipboard: ClipboardMsg,
    config: ConfigMsg,
    theme: ThemeMsg,
};

pub const PatchMsg = union(enum) {
    full: struct { root: Node, seq: ?u64 = null, v: ?u32 = null },
    target: struct { target: []const u8, node: Node, mode: PatchMode = .replace, seq: ?u64 = null, v: ?u32 = null },
};

pub const PatchMode = enum {
    replace,
    morph,
};

pub const EventMsg = union(enum) {
    hello: HelloEvent,
    key: struct { key: []const u8, mods: u8 = 0, seq: ?[]const u8 = null, v: ?u32 = null },
    focus: struct { id: []const u8, v: ?u32 = null },
    input: struct { id: []const u8, value: []const u8, cursor: usize, v: ?u32 = null },
    select: struct { id: []const u8, item: []const u8, v: ?u32 = null },
    activate: struct { id: []const u8, item: []const u8, v: ?u32 = null },
    scroll: struct { id: []const u8, scroll_y: usize, v: ?u32 = null },
    resize: struct { rows: usize, cols: usize, v: ?u32 = null },
    hover: struct { id: []const u8, x: usize, y: usize, item: ?[]const u8 = null, v: ?u32 = null },
    pointer: PointerEvent,
    clipboard: ClipboardEvent,
    paste: PasteEvent,
    @"error": RuntimeErrorEvent,
    ack: AckEvent,
    config_ack: ConfigAckEvent,
    rendered: struct { seq: u64, dropped: u64 = 0, bytes: usize = 0, changed_cells: usize = 0, v: ?u32 = null },
    dropped: struct { seq: u64, reason: []const u8, v: ?u32 = null },
};

pub const HelloCaps = struct {
    ansi: bool = true,
    alt_screen: bool = true,
    bracketed_paste: bool = true,
    mouse_sgr: bool = true,
    osc52: bool = true,
    color: []const u8,
};

pub const HelloLimits = struct {
    max_fps: u32,
    frame_interval_ns: u64,
    max_pending_targets: usize,
    max_backend_lines_per_iter: usize,
    queue_overflow: []const u8,
};

pub const HelloEvent = struct {
    protocol_version: u32,
    caps: HelloCaps,
    limits: HelloLimits,
    v: ?u32 = null,
};

pub const ClipboardOp = enum {
    write,
    read,
};

pub const ClipboardTarget = enum {
    clipboard,
};

pub const ClipboardMsg = union(enum) {
    write: struct { data: []const u8, target: ClipboardTarget = .clipboard, seq: ?u64 = null, v: ?u32 = null },
    read: struct { request_id: u32, target: ClipboardTarget = .clipboard, seq: ?u64 = null, v: ?u32 = null },
};

pub const ClipboardEvent = struct {
    op: ClipboardOp,
    ok: bool,
    request_id: u32 = 0,
    data: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    v: ?u32 = null,
};

pub const PasteSource = enum {
    bracketed,
    clipboard,
};

pub const PasteEvent = struct {
    source: PasteSource,
    bytes: usize,
    v: ?u32 = null,
};

pub const RuntimeErrorEvent = struct {
    code: []const u8,
    message: []const u8,
    seq: ?u64 = null,
    context: ?[]const u8 = null,
    v: ?u32 = null,
};

pub const AckEvent = struct {
    seq: u64,
    status: []const u8,
    detail: ?[]const u8 = null,
    v: ?u32 = null,
};

pub const ConfigAckRejected = struct {
    key: []const u8,
    reason: []const u8,
};

pub const ConfigAckEvent = struct {
    applied: []const []const u8,
    rejected: []const ConfigAckRejected,
    v: ?u32 = null,
};

pub const ConfigMsg = struct {
    keybindings: ?KeybindingsConfig = null,
    theme: ?ThemeName = null,
    seq: ?u64 = null,
    v: ?u32 = null,
};

pub const ThemeName = enum {
    default,
    light,
    ocean,
};

pub const ThemeMsg = struct {
    name: ThemeName,
    v: ?u32 = null,
};

pub const KeybindingsConfig = struct {
    global: ?[]KeybindingRule = null,
    input: ?[]KeybindingRule = null,
    textarea: ?[]KeybindingRule = null,
    list: ?[]KeybindingRule = null,
    scroll: ?[]KeybindingRule = null,
    action: ?[]KeybindingRule = null,
};

pub const KeybindingRule = struct {
    key: []const u8,
    mods: u8 = 0,
    action: KeyAction,
};

pub const KeyAction = enum {
    noop,
    focus_next,
    focus_prev,
    focus_scope_next,
    focus_scope_prev,
    focus_clear,
    list_prev,
    list_next,
    list_activate,
    scroll_line_up,
    scroll_line_down,
    scroll_page_up,
    scroll_page_down,
    scroll_home,
    scroll_end,
    action_activate,
    input_left,
    input_right,
    input_word_left,
    input_word_right,
    input_home,
    input_end,
    input_delete,
    input_backspace,
    input_select_left,
    input_select_right,
    input_select_word_left,
    input_select_word_right,
    input_select_home,
    input_select_end,
    input_select_all,
    input_copy,
    input_paste,
    input_undo,
    input_redo,
    textarea_left,
    textarea_right,
    textarea_up,
    textarea_down,
    textarea_word_left,
    textarea_word_right,
    textarea_home,
    textarea_end,
    textarea_page_up,
    textarea_page_down,
    textarea_delete,
    textarea_backspace,
    textarea_newline,
    textarea_select_left,
    textarea_select_right,
    textarea_select_up,
    textarea_select_down,
    textarea_select_word_left,
    textarea_select_word_right,
    textarea_select_home,
    textarea_select_end,
    textarea_select_all,
    textarea_copy,
    textarea_paste,
    textarea_undo,
    textarea_redo,
};

pub const ValidationState = enum {
    none,
    @"error",
    warning,
    success,
};

pub const StateMode = enum {
    uncontrolled,
    init,
    controlled,
};

pub const Node = union(enum) {
    vbox: VBoxNode,
    hbox: HBoxNode,
    grid: GridNode,
    box: BoxNode,
    scroll: ScrollNode,
    overlay: OverlayNode,
    text: TextNode,
    styled_text: StyledTextNode,
    input: InputNode,
    textarea: TextareaNode,
    list: ListNode,
};

pub const JustifyContent = enum {
    start,
    center,
    end,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    start,
    center,
    end,
    stretch,
};

pub const HorizontalAlign = enum {
    left,
    center,
    right,
};

pub const VerticalAlign = enum {
    top,
    center,
    bottom,
};

pub const VBoxNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    justify_content: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    gap: usize = 0,
    align_self: ?AlignItems = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const HBoxNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    justify_content: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    gap: usize = 0,
    align_self: ?AlignItems = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const GridTrack = union(enum) {
    fixed: usize,
    auto,
    fr: usize,
};

pub const GridNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    align_self: ?AlignItems = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    gap_x: usize = 0,
    gap_y: usize = 0,
    rows: []GridTrack,
    cols: []GridTrack,
    /// Each string is one row with space-delimited area names.
    areas: ?[]const []const u8 = null,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const BoxNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    title: ?[]const u8 = null,
    border: bool = true,
    pad: usize = 0,
    /// Defaults to true; backends may omit `clip` entirely.
    clip: bool = true,
    shadow: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    align_self: ?AlignItems = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    child: *Node,
};

pub const ScrollNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    /// Defaults to true; backends may omit `clip` entirely.
    clip: bool = true,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = true,
    focus_scope: ?[]const u8 = null,
    align_self: ?AlignItems = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    state_mode: StateMode = .uncontrolled,
    scroll_y: ?usize = null,
    child: *Node,
};

pub const OverlayPlacement = enum {
    below,
    above,
    right,
    left,
    center,
};

pub const OverlayAlign = enum {
    start,
    center,
    end,
};

pub const OverlayLayer = struct {
    node: *Node,
    anchor: ?[]const u8 = null,
    placement: OverlayPlacement,
    align_: OverlayAlign = .start,
    offset_x: isize = 0,
    offset_y: isize = 0,
    w: ?usize = null,
    h: ?usize = null,
    clip: bool = true,
    modal: bool = false,
};

pub const OverlayNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    align_self: ?AlignItems = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    base: *Node,
    layers: []OverlayLayer,
};

pub const TextNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    ext_align: HorizontalAlign = .left,
    v_align: VerticalAlign = .top,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    text: []const u8,
};

pub const Span = struct {
    text: []const u8,
    style: ?style.StyleOverride = null,
};

pub const StyledTextNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = false,
    focus_scope: ?[]const u8 = null,
    ext_align: HorizontalAlign = .left,
    v_align: VerticalAlign = .top,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    spans: []Span,
};

pub const InputNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = true,
    focus_scope: ?[]const u8 = null,
    content_align: HorizontalAlign = .left,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    selection_style: ?style.StyleOverride = null,
    placeholder_style: ?style.StyleOverride = null,
    placeholder: ?[]const u8 = null,
    state_mode: StateMode = .uncontrolled,
    value: ?[]const u8 = null,
    cursor: ?usize = null,
    scroll_x: ?usize = null,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
};

pub const TextareaNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = true,
    focus_scope: ?[]const u8 = null,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    selection_style: ?style.StyleOverride = null,
    placeholder_style: ?style.StyleOverride = null,
    placeholder: ?[]const u8 = null,
    state_mode: StateMode = .uncontrolled,
    value: ?[]const u8 = null,
    cursor: ?usize = null,
    scroll_y: ?usize = null,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
};

pub const ListMarker = enum {
    default,
    none,
};

pub const ListNode = struct {
    id: []const u8,
    class: ?[]const u8 = null,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    height: ?usize = null,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    validation: ValidationState = .none,
    focusable: bool = true,
    focus_scope: ?[]const u8 = null,
    marker: ListMarker = .default,
    grid_row: ?usize = null,
    grid_col: ?usize = null,
    row_span: usize = 1,
    col_span: usize = 1,
    grid_area: ?[]const u8 = null,
    style: ?style.StyleOverride = null,
    state_mode: StateMode = .uncontrolled,
    selected_id: ?[]const u8 = null,
    scroll: ?usize = null,
    children: []Node,
};

pub const PointerKind = enum {
    down,
    up,
    move,
    drag,
    scroll,
};

pub const PointerButton = enum {
    left,
    middle,
    right,
    none,
};

pub const PointerEvent = struct {
    kind: PointerKind,
    id: []const u8,
    x: usize,
    y: usize,
    local_x: usize,
    local_y: usize,
    button: PointerButton = .none,
    buttons: u8 = 0,
    mods: u8 = 0,
    clicks: u8 = 1,
    scroll_dx: isize = 0,
    scroll_dy: isize = 0,
    item: ?[]const u8 = null,
    captured: bool = false,
    v: ?u32 = null,
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
    UnknownValidationState,
    UnknownStateMode,
    UnknownListMarker,
    UnknownOverlayPlacement,
    UnknownOverlayAlign,
    UnknownJustifyContent,
    UnknownAlignItems,
    UnknownGridTrack,
    UnknownHorizontalAlign,
    UnknownVerticalAlign,
    UnknownPointerKind,
    UnknownPointerButton,
    UnknownClipboardOp,
    UnknownClipboardTarget,
    UnknownPasteSource,
    UnknownThemeName,
    UnknownKeyAction,
    InvalidKeybindingRule,
} || std.mem.Allocator.Error;

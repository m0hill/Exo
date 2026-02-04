const std = @import("std");
const style = @import("../style.zig");

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
    scroll: struct { id: []const u8, scroll_y: usize },
    resize: struct { rows: usize, cols: usize },
    hover: struct { id: []const u8, x: usize, y: usize, item: ?[]const u8 = null },
    pointer: PointerEvent,
};

pub const Node = union(enum) {
    vbox: VBoxNode,
    hbox: HBoxNode,
    box: BoxNode,
    scroll: ScrollNode,
    overlay: OverlayNode,
    text: TextNode,
    styled_text: StyledTextNode,
    input: InputNode,
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
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    justify_content: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    gap: usize = 0,
    align_self: ?AlignItems = null,
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
    hoverable: bool = false,
    mouseable: bool = false,
    justify_content: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    gap: usize = 0,
    align_self: ?AlignItems = null,
    style: ?style.StyleOverride = null,
    children: []Node,
};

pub const BoxNode = struct {
    id: []const u8,
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
    align_self: ?AlignItems = null,
    style: ?style.StyleOverride = null,
    child: *Node,
};

pub const ScrollNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    /// Defaults to true; backends may omit `clip` entirely.
    clip: bool = true,
    hoverable: bool = false,
    mouseable: bool = false,
    align_self: ?AlignItems = null,
    style: ?style.StyleOverride = null,
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
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    pad: usize = 0,
    clip: bool = false,
    hoverable: bool = false,
    mouseable: bool = false,
    align_self: ?AlignItems = null,
    style: ?style.StyleOverride = null,
    base: *Node,
    layers: []OverlayLayer,
};

pub const TextNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    ext_align: HorizontalAlign = .left,
    v_align: VerticalAlign = .top,
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
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    ext_align: HorizontalAlign = .left,
    v_align: VerticalAlign = .top,
    style: ?style.StyleOverride = null,
    spans: []Span,
};

pub const InputNode = struct {
    id: []const u8,
    w: ?usize = null,
    h: ?usize = null,
    flex: usize = 0,
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    content_align: HorizontalAlign = .left,
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
    align_self: ?AlignItems = null,
    hoverable: bool = false,
    mouseable: bool = false,
    style: ?style.StyleOverride = null,
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
    UnknownOverlayPlacement,
    UnknownOverlayAlign,
    UnknownJustifyContent,
    UnknownAlignItems,
    UnknownHorizontalAlign,
    UnknownVerticalAlign,
    UnknownPointerKind,
    UnknownPointerButton,
} || std.mem.Allocator.Error;

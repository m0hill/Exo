const std = @import("std");

const protocol = @import("../protocol/mod.zig");

const block = @import("block.zig");
const inline_mod = @import("inline.zig");
const stream = @import("stream/mod.zig");
const types = @import("types.zig");

pub const Theme = types.Theme;
pub const InlineOptions = types.InlineOptions;
pub const Options = types.Options;
pub const CompileError = types.CompileError;

pub const StreamBlocks = stream.StreamBlocks;
pub const StreamInline = stream.StreamInline;

pub fn compileInlineSpansLeaky(
    allocator: std.mem.Allocator,
    md: []const u8,
    opts: InlineOptions,
) CompileError![]protocol.Span {
    return inline_mod.compileInlineSpansLeaky(allocator, md, opts);
}

pub fn compileLeaky(
    allocator: std.mem.Allocator,
    md: []const u8,
    opts: Options,
) CompileError!protocol.Node {
    return block.compileLeaky(allocator, md, opts);
}

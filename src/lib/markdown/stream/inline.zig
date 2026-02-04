const std = @import("std");

const protocol = @import("../../protocol/mod.zig");

const stream_blocks = @import("blocks.zig");
const types = @import("../types.zig");

pub const StreamInline = struct {
    inner: stream_blocks.StreamBlocks,

    pub fn init(allocator: std.mem.Allocator, opts: types.Options, caps: stream_blocks.StreamBlocks.Caps) StreamInline {
        return .{ .inner = stream_blocks.StreamBlocks.init(allocator, opts, caps, .inline_parse) };
    }

    pub fn deinit(self: *StreamInline) void {
        self.inner.deinit();
    }

    pub fn reset(self: *StreamInline) void {
        self.inner.reset();
    }

    pub fn push(self: *StreamInline, chunk: []const u8) types.CompileError!stream_blocks.StreamBlocks.PushResult {
        return self.inner.push(chunk);
    }

    pub fn finish(self: *StreamInline) types.CompileError!stream_blocks.StreamBlocks.PushResult {
        return self.inner.finish();
    }

    pub fn snapshotLeaky(self: *const StreamInline, arena_tx: std.mem.Allocator) types.CompileError!protocol.Node {
        return self.inner.snapshotLeaky(arena_tx);
    }

    pub fn tailNodeLeaky(self: *const StreamInline, arena_tx: std.mem.Allocator) ?protocol.Node {
        return self.inner.tailNodeLeaky(arena_tx);
    }

    pub fn tailKey(self: *const StreamInline) stream_blocks.StreamBlocks.TailKey {
        return self.inner.tailKey();
    }
};

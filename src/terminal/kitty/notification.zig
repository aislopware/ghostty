//! Kitty's desktop notification protocol (OSC 99), the part of it that
//! maps onto a plain desktop notification: a title and a body, sent in
//! one escape code or in chunks, plain or base64 encoded, and the query
//! for what the terminal supports.
//!
//! A finished notification is handed to the embedder through the same
//! effect as OSC 9 and OSC 777 notifications, so an embedder that shows
//! those shows these. Actions, close events, icons, buttons, sounds,
//! urgency and occasions are not implemented, and the query answer says
//! so, as the protocol asks.
//!
//! Specification: https://sw.kovidgoyal.net/kitty/desktop-notifications/
const std = @import("std");
const Allocator = std.mem.Allocator;
const osc = @import("../osc.zig");

const OSC = osc.Command.KittyDesktopNotification;

/// The most bytes a title or body is kept to. The protocol leaves the
/// limit to the terminal; past it the text is cut, on a character.
pub const max_text_bytes = 16 * 1024;

/// What the query answers: the payload types implemented, and the one
/// occasion a terminal that implements none must name.
const capabilities = "o=always:p=title,body,?";

/// A notification ready to show. Its text lives until the next call to
/// `State.handle` or `State.deinit`.
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
};

/// The notification being assembled from chunks.
pub const State = struct {
    /// The id of the notification in progress; empty when it has none.
    id: std.ArrayList(u8) = .empty,
    title: Text = .{},
    body: Text = .{},
    /// A notification is in progress: chunks of it came with `d=0`.
    open: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.id.deinit(gpa);
        self.title.deinit(gpa);
        self.body.deinit(gpa);
    }

    fn clear(self: *State) void {
        self.id.clearRetainingCapacity();
        self.title.clear();
        self.body.clear();
        self.open = false;
    }

    /// Handle one OSC 99. Any answer the program is owed is written to
    /// `writer`. Returns the notification this completes, if any.
    pub fn handle(
        self: *State,
        gpa: Allocator,
        writer: *std.Io.Writer,
        cmd: OSC,
    ) (Allocator.Error || std.Io.Writer.Error)!?Notification {
        const id = cmd.readOption(.i) orelse "";
        switch (cmd.readOption(.p)) {
            .query => {
                try writer.print("\x1b]99;i={s}:p=?;{s}{s}", .{
                    if (id.len > 0) id else "0",
                    capabilities,
                    cmd.terminator.string(),
                });
                return null;
            },
            // These name a notification already shown, which is not
            // tracked: nothing to close, nothing alive to report.
            .close, .alive => return null,
            .title, .body, .icon, .buttons, .unknown => {},
        }

        // A chunk of another notification ends the one in progress.
        if (self.open and !std.mem.eql(u8, self.id.items, id)) self.clear();
        if (!self.open) {
            self.clear();
            try self.id.appendSlice(gpa, id);
        }

        const base64 = cmd.readOption(.e);
        switch (cmd.readOption(.p)) {
            .title => try self.title.append(gpa, cmd.payload, base64),
            .body => try self.body.append(gpa, cmd.payload, base64),
            else => {},
        }

        if (!cmd.readOption(.d)) {
            self.open = true;
            return null;
        }

        self.open = false;
        const title = try self.title.finish(gpa);
        const body = try self.body.finish(gpa);
        if (title.len == 0 and body.len == 0) return null;
        return .{ .title = title, .body = body };
    }
};

/// A title or body as it arrives: plain text appended as it is, base64
/// decoded a whole group of four characters at a time, so a payload
/// chunked before encoding (each chunk padded) and one chunked after
/// (groups split across chunks) decode alike.
const Text = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// Base64 characters not yet making a whole group.
    group: [4]u8 = undefined,
    group_len: u3 = 0,

    fn deinit(self: *Text, gpa: Allocator) void {
        self.bytes.deinit(gpa);
    }

    fn clear(self: *Text) void {
        self.bytes.clearRetainingCapacity();
        self.group_len = 0;
    }

    fn append(
        self: *Text,
        gpa: Allocator,
        payload: []const u8,
        base64: bool,
    ) Allocator.Error!void {
        if (!base64) return self.keep(gpa, payload);
        for (payload) |c| {
            self.group[self.group_len] = c;
            self.group_len += 1;
            if (self.group_len == 4) {
                self.group_len = 0;
                try self.decode(gpa, self.group[0..4]);
            }
        }
    }

    /// The text, its last base64 characters decoded as if padded, cut
    /// to `max_text_bytes` on a character and to valid UTF-8.
    fn finish(self: *Text, gpa: Allocator) Allocator.Error![]const u8 {
        if (self.group_len > 1) {
            var padded: [4]u8 = .{ '=', '=', '=', '=' };
            @memcpy(padded[0..self.group_len], self.group[0..self.group_len]);
            try self.decode(gpa, &padded);
        }
        self.group_len = 0;
        const text = self.bytes.items;
        return text[0..validUtf8Prefix(text)];
    }

    fn decode(self: *Text, gpa: Allocator, group: *const [4]u8) Allocator.Error!void {
        const decoder = std.base64.standard.Decoder;
        var out: [3]u8 = undefined;
        const len = decoder.calcSizeForSlice(group) catch return;
        decoder.decode(out[0..len], group) catch return;
        try self.keep(gpa, out[0..len]);
    }

    fn keep(self: *Text, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        const room = max_text_bytes -| self.bytes.items.len;
        try self.bytes.appendSlice(gpa, bytes[0..@min(room, bytes.len)]);
    }
};

/// The length of the longest prefix of `bytes` that is valid UTF-8.
fn validUtf8Prefix(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + len > bytes.len) return i;
        _ = std.unicode.utf8Decode(bytes[i..][0..len]) catch return i;
        i += len;
    }
    return i;
}

const testing = std.testing;

fn command(metadata: []const u8, payload: []const u8) OSC {
    return .{ .metadata = metadata, .payload = payload, .terminator = .st };
}

const Harness = struct {
    state: State = .{},
    out: std.Io.Writer.Allocating,

    fn init() Harness {
        return .{ .out = .init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.state.deinit(testing.allocator);
        self.out.deinit();
    }

    fn send(self: *Harness, metadata: []const u8, payload: []const u8) !?Notification {
        return self.state.handle(testing.allocator, &self.out.writer, command(metadata, payload));
    }
};

test "a one-line notification is its title" {
    var h: Harness = .init();
    defer h.deinit();
    const n = (try h.send("", "Hello world")).?;
    try testing.expectEqualStrings("Hello world", n.title);
    try testing.expectEqualStrings("", n.body);
}

test "a title and a body in chunks under one id" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expect(try h.send("i=1:d=0", "Hello ") == null);
    try testing.expect(try h.send("i=1:d=0", "world") == null);
    const n = (try h.send("i=1:p=body", "This is cool")).?;
    try testing.expectEqualStrings("Hello world", n.title);
    try testing.expectEqualStrings("This is cool", n.body);
}

test "base64 chunked before or after encoding decodes alike" {
    var h: Harness = .init();
    defer h.deinit();
    // "Hello" and " world", each encoded with its padding.
    try testing.expect(try h.send("i=a:e=1:d=0", "SGVsbG8=") == null);
    const before = (try h.send("i=a:e=1", "IHdvcmxk")).?;
    try testing.expectEqualStrings("Hello world", before.title);
    // "Hello world" encoded, then split mid-group, its padding dropped.
    try testing.expect(try h.send("i=b:e=1:d=0", "SGVsbG8gd2") == null);
    const after = (try h.send("i=b:e=1", "9ybGQ")).?;
    try testing.expectEqualStrings("Hello world", after.title);
}

test "a chunk of another notification drops the one in progress" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expect(try h.send("i=1:d=0", "lost") == null);
    const n = (try h.send("i=2", "kept")).?;
    try testing.expectEqualStrings("kept", n.title);
}

test "the query names what is implemented" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expect(try h.send("i=q:p=?", "") == null);
    try testing.expectEqualStrings(
        "\x1b]99;i=q:p=?;o=always:p=title,body,?\x1b\\",
        h.out.written(),
    );
}

test "close, alive and empty notifications show nothing" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expect(try h.send("i=1:p=close", "") == null);
    try testing.expect(try h.send("i=1:p=alive", "") == null);
    try testing.expect(try h.send("i=1:p=icon", "") == null);
    try testing.expectEqualStrings("", h.out.written());
}

test "text is kept to its bound, on a character" {
    var h: Harness = .init();
    defer h.deinit();
    const chunk = "é" ** 1000;
    var sent: usize = 0;
    while (sent <= max_text_bytes) : (sent += chunk.len) {
        try testing.expect(try h.send("i=big:d=0", chunk) == null);
    }
    const n = (try h.send("i=big", "")).?;
    try testing.expectEqual(max_text_bytes, n.title.len);
    try testing.expect(std.unicode.utf8ValidateSlice(n.title));
}

//! Native drag and drop for programs running in the terminal, independent
//! of the protocol a program uses to take part in it. The embedder
//! connects these to the OS; Kitty's OSC 72 (`kitty.dnd`) is the only
//! protocol today.

const std = @import("std");

/// A drag and drop operation.
///
/// C: GhosttyDndOperation
pub const Operation = enum(c_int) {
    none = 0,
    copy = 1,
    move = 2,
};

/// A list of MIME types, borrowed from the terminal and only valid for
/// the duration of the effect callback it was delivered to. MIME types
/// can't contain the separator, so the list is held as received rather
/// than split into slices.
pub const MimeList = struct {
    bytes: []const u8 = "",
    separator: u8 = ' ',

    pub fn iterator(self: MimeList) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.bytes, self.separator);
    }

    pub fn count(self: MimeList) usize {
        var it = self.iterator();
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }
};

/// A change in drops onto the terminal that the embedder may need to act
/// on. Everything borrowed is only valid for the duration of the effect
/// callback.
pub const DropEvent = union(enum) {
    /// The program started or stopped accepting drops. While it accepts
    /// them, native drags over the terminal go to it rather than being
    /// handled as they would be without it (e.g. pasting dropped paths).
    registration: Registration,

    /// The program answered the drag over the terminal, for the OS drag
    /// feedback. Until it accepts, the drag isn't accepted: a drop it
    /// hasn't accepted would never be read or concluded, so the embedder
    /// refuses it.
    acceptance: Acceptance,

    /// The program wants data from the drop, which the embedder reads
    /// from the native drop (asynchronously if it must) and sends back.
    data_request: DataRequest,

    /// The program is done with the drop. The embedder finishes the
    /// native drop with the operation it performed.
    concluded: Operation,

    pub const Registration = struct {
        accepting: bool,

        /// MIME types the program declared it accepts, if any. Only
        /// needed to register types with the OS ahead of a drag.
        mimes: MimeList = .{},
    };

    pub const Acceptance = struct {
        /// The operation the program would perform, or none if it
        /// rejects the drag.
        operation: Operation,

        /// The MIME types it wants, most preferred first. Empty when
        /// the program didn't say.
        mimes: MimeList = .{},
    };

    pub const DataRequest = struct {
        /// Identifies the request when answering it. Never reused, so an
        /// answer to a request the program abandoned is rejected rather
        /// than answering another.
        id: u32,

        /// Index into the MIME types of the drop.
        mime_index: u32,

        /// The MIME type to read from the native drop.
        mime: []const u8,
    };
};

test "MimeList iterates either separator" {
    const testing = std.testing;
    const spaced: MimeList = .{ .bytes = "text/plain image/png " };
    try testing.expectEqual(@as(usize, 2), spaced.count());
    const nul: MimeList = .{ .bytes = "text/plain\x00", .separator = 0 };
    var it = nul.iterator();
    try testing.expectEqualStrings("text/plain", it.next().?);
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 0), (MimeList{}).count());
}

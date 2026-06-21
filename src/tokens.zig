const std = @import("std");

/// A simple message line got from client
pub const ClientMsg = struct {
    msg: []const u8,

    fn deinit(self: ClientMsg, gpa: std.mem.Allocator) void {
        gpa.free(self.msg);
    }

    fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !ClientMsg {
        const msg = try gpa.dupe(u8, str);
        return ClientMsg{
            .msg = msg,
        };
    }
};

/// Represents a token, that client sends
pub const ClientToken = union(enum) {
    msg: ClientMsg,

    pub fn deinit(self: ClientToken, gpa: std.mem.Allocator) void {
        switch (self) {
            .msg => |msg| msg.deinit(gpa),
        }
    }

    /// Constructs ClientToken
    /// For now it holds just a ClientMsg
    fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !ClientToken {
        const msg = try ClientMsg.fromStringAlloc(gpa, str);
        return ClientToken{
            .msg = msg,
        };
    }
};

test "ClientMsg contains the same string" {
    const gpa = std.testing.allocator;
    const str = "some msg";

    const msg = try ClientMsg.fromStringAlloc(gpa, str);
    defer msg.deinit(gpa);

    try std.testing.expectEqualStrings(str, msg.msg);
}

test "ClientToken creates a message token" {
    const gpa = std.testing.allocator;
    const str = "some msg";

    const token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqualStrings(str, token.msg.msg);
}

pub const ClientTokenReader = struct {
    reader: *std.Io.Reader,

    pub fn next(self: ClientTokenReader, gpa: std.mem.Allocator) !?ClientToken {
        const line = try self.reader.takeDelimiter('\n') orelse return null;
        return try ClientToken.fromStringAlloc(gpa, line);
    }
};

test "ClientTokenReader reads all lines" {
    const gpa = std.testing.allocator;

    const line1 = "hello world";
    const line2 = "bye world";
    const line = line1 ++ "\n" ++ line2;

    var reader = std.Io.Reader.fixed(line);
    var tokenReader = ClientTokenReader{
        .reader = &reader,
    };

    const gotLine1 = try tokenReader.next(gpa) orelse return error.GotNullLine;
    defer gotLine1.deinit(gpa);
    try std.testing.expectEqualStrings(line1, gotLine1.msg.msg);

    const gotLine2 = try tokenReader.next(gpa) orelse return error.GotNullLine;
    defer gotLine2.deinit(gpa);
    try std.testing.expectEqualStrings(line2, gotLine2.msg.msg);

    const gotEmptyLine1 = try tokenReader.next(gpa);
    try std.testing.expectEqual(null, gotEmptyLine1);

    const gotEmptyLine2 = try tokenReader.next(gpa);
    try std.testing.expectEqual(null, gotEmptyLine2);
}

const std = @import("std");

/// A simple message line got from client
const ClientMsg = struct {
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
const ClientToken = union(enum) {
    msg: ClientMsg,

    fn deinit(self: ClientToken, gpa: std.mem.Allocator) void {
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

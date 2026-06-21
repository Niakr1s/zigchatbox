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

pub const ClientCmd = union(enum) {
    whoami: CliendCmdWhoami,

    fn deinit(self: ClientCmd, gpa: std.mem.Allocator) void {
        _ = gpa;
        switch (self) {
            .whoami => {},
        }
    }

    pub const CliendCmdWhoami = struct {
        const WHOAMI = "whoami";
    };

    /// Args:
    ///   str: this should be a command without command prefix
    ///   so, if a command: "/whoami", caller should trim the first char
    fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !ClientCmd {
        _ = gpa;

        const trimmed = std.mem.trim(u8, str, " ");
        if (std.mem.eql(u8, CliendCmdWhoami.WHOAMI, trimmed)) {
            return ClientCmd{ .whoami = .{} };
        } else {
            return error.UnknownClientCmd;
        }
    }
};

/// Represents a token, that client sends
pub const ClientToken = union(enum) {
    msg: ClientMsg,
    cmd: ClientCmd,

    pub fn deinit(self: ClientToken, gpa: std.mem.Allocator) void {
        switch (self) {
            .msg => self.msg.deinit(gpa),
            .cmd => self.cmd.deinit(gpa),
        }
    }

    /// Constructs ClientToken
    pub fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !ClientToken {
        if (str.len == 0) {
            return error.EmptyString;
        }

        if (str[0] == '/') {
            const cmd = try ClientCmd.fromStringAlloc(gpa, str[1..]);
            return ClientToken{
                .cmd = cmd,
            };
        } else {
            const msg = try ClientMsg.fromStringAlloc(gpa, str);
            return ClientToken{
                .msg = msg,
            };
        }
    }
};

test "ClientMsg contains the same string" {
    const gpa = std.testing.allocator;
    const str = "some msg";

    const msg = try ClientMsg.fromStringAlloc(gpa, str);
    defer msg.deinit(gpa);

    try std.testing.expectEqualStrings(str, msg.msg);
}

test "ClienCmd creates whoami command" {
    const gpa = std.testing.allocator;
    const str = ClientCmd.CliendCmdWhoami.WHOAMI;

    const msg = try ClientCmd.fromStringAlloc(gpa, str);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(ClientCmd.CliendCmdWhoami{}, msg.whoami);
}

test "ClienCmd trims incoming str" {
    const gpa = std.testing.allocator;
    const str = ClientCmd.CliendCmdWhoami.WHOAMI ++ "   ";

    const msg = try ClientCmd.fromStringAlloc(gpa, str);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(ClientCmd.CliendCmdWhoami{}, msg.whoami);
}

test "ClientToken creates a message token" {
    const gpa = std.testing.allocator;
    const str = "some msg";

    var token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqualStrings(str, token.msg.msg);
}

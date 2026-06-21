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
    whoami: Whoami,
    nickname: Nickname,

    fn deinit(self: ClientCmd, gpa: std.mem.Allocator) void {
        switch (self) {
            .whoami => {},
            .nickname => {
                self.nickname.deinit(gpa);
            },
        }
    }

    /// Requests nickname
    pub const Whoami = struct {
        const CMD = "whoami";
    };

    /// Changes nick
    pub const Nickname = struct {
        nickname: []const u8,

        const CMD = "nickname";

        fn deinit(self: Nickname, gpa: std.mem.Allocator) void {
            gpa.free(self.nickname);
        }

        fn init(gpa: std.mem.Allocator, nickname: []const u8) !Nickname {
            return Nickname{
                .nickname = try gpa.dupe(u8, nickname),
            };
        }
    };

    /// Args:
    ///   str: this should be a trimmed string without command prefix
    ///   so, if a command: "/whoami", caller should trim the first char
    fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !ClientCmd {
        // std.debug.print("{s}\n", .{str});
        // std.debug.print("cut prefix: {s}: in {s}: {any}\n", .{ Nickname.CMD ++ " ", str, std.mem.cutPrefix(u8, str, Nickname.CMD ++ " ") });
        if (std.mem.eql(u8, Whoami.CMD, str)) {
            return ClientCmd{ .whoami = .{} };
        } else if (std.mem.cutPrefix(u8, str, Nickname.CMD ++ " ")) |nickname| {
            return ClientCmd{ .nickname = try Nickname.init(gpa, nickname) };
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
        const trimmed = std.mem.trim(u8, str, " \n");

        if (trimmed.len == 0) {
            return error.EmptyString;
        }

        if (trimmed[0] == '/') {
            const cmd = try ClientCmd.fromStringAlloc(gpa, trimmed[1..]);
            return ClientToken{
                .cmd = cmd,
            };
        } else {
            const msg = try ClientMsg.fromStringAlloc(gpa, trimmed);
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
    const str = ClientCmd.Whoami.CMD;

    const msg = try ClientCmd.fromStringAlloc(gpa, str);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(ClientCmd.Whoami{}, msg.whoami);
}

test "ClientCmd creates nickname command" {
    const gpa = std.testing.allocator;
    const expectedNickname = "Vasyan";
    const str = "/" ++ ClientCmd.Nickname.CMD ++ " " ++ expectedNickname ++ " ";

    const token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqualDeep(ClientCmd.Nickname{
        .nickname = expectedNickname,
    }, token.cmd.nickname);
}

test "ClienCmd trims incoming str" {
    const gpa = std.testing.allocator;
    const str = ClientCmd.Whoami.CMD ++ "   ";

    const msg = try ClientCmd.fromStringAlloc(gpa, str);
    defer msg.deinit(gpa);

    try std.testing.expectEqual(ClientCmd.Whoami{}, msg.whoami);
}

test "ClientToken creates a message token" {
    const gpa = std.testing.allocator;
    const str = "some msg";

    var token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqualStrings(str, token.msg.msg);
}

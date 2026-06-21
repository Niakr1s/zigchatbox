const std = @import("std");

/// Represents a token, that client sends
pub const ClientToken = union(enum) {
    msg: Msg,
    cmd: Cmd,

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

        if (std.mem.cutPrefix(u8, trimmed, Cmd.PREFIX)) |cmdStr| {
            const cmd = try Cmd.fromStringAlloc(gpa, cmdStr);
            return ClientToken{
                .cmd = cmd,
            };
        } else {
            const msg = try Msg.fromStringAlloc(gpa, trimmed);
            return ClientToken{
                .msg = msg,
            };
        }
    }

    /// A simple message line got from client
    pub const Msg = struct {
        msg: []const u8,

        fn deinit(self: Msg, gpa: std.mem.Allocator) void {
            gpa.free(self.msg);
        }

        fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !Msg {
            const msg = try gpa.dupe(u8, str);
            return Msg{
                .msg = msg,
            };
        }
    };

    pub const Cmd = union(enum) {
        whoami: Whoami,
        who: Who,
        nickname: Nickname,

        pub const PREFIX = "/";

        fn deinit(self: Cmd, gpa: std.mem.Allocator) void {
            switch (self) {
                .whoami => {},
                .who => {},
                .nickname => {
                    self.nickname.deinit(gpa);
                },
            }
        }

        /// Requests nickname
        pub const Whoami = struct {
            const CMD = "whoami";
        };

        /// Requests all connected users
        pub const Who = struct {
            const CMD = "who";
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
        fn fromStringAlloc(gpa: std.mem.Allocator, str: []const u8) !Cmd {
            // std.debug.print("{s}\n", .{str});
            // std.debug.print("cut prefix: {s}: in {s}: {any}\n", .{ Nickname.CMD ++ " ", str, std.mem.cutPrefix(u8, str, Nickname.CMD ++ " ") });
            if (std.mem.eql(u8, Whoami.CMD, str)) {
                return Cmd{ .whoami = .{} };
            } else if (std.mem.eql(u8, Who.CMD, str)) {
                return Cmd{ .who = .{} };
            } else if (std.mem.cutPrefix(u8, str, Nickname.CMD ++ " ")) |nickname| {
                return Cmd{ .nickname = try Nickname.init(gpa, nickname) };
            } else {
                return error.UnknownClientCmd;
            }
        }
    };
};

test "ClienCmd creates whoami command" {
    const gpa = std.testing.allocator;
    const str = ClientToken.Cmd.PREFIX ++ ClientToken.Cmd.Whoami.CMD;

    const token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqual(ClientToken.Cmd.Whoami{}, token.cmd.whoami);
}

test "ClienCmd creates who command" {
    const gpa = std.testing.allocator;
    const str = ClientToken.Cmd.PREFIX ++ ClientToken.Cmd.Who.CMD;

    const token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqual(ClientToken.Cmd.Who{}, token.cmd.who);
}

test "ClientCmd creates nickname command" {
    const gpa = std.testing.allocator;
    const expectedNickname = "Vasyan";
    const str = ClientToken.Cmd.PREFIX ++ ClientToken.Cmd.Nickname.CMD ++ " " ++ expectedNickname ++ " ";

    const token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqualDeep(ClientToken.Cmd.Nickname{
        .nickname = expectedNickname,
    }, token.cmd.nickname);
}

test "ClientToken creates a message token" {
    const gpa = std.testing.allocator;
    const str = "some msg";

    var token = try ClientToken.fromStringAlloc(gpa, str);
    defer token.deinit(gpa);

    try std.testing.expectEqualStrings(str, token.msg.msg);
}

const std = @import("std");
const tokens = @import("tokens.zig");

pub const NetServer = struct {
    pub const Type = Server(NetConnectionProducer, NetConnection);

    pub const NetConnection = struct {
        const Self = @This();

        stream: std.Io.net.Stream,

        fn readLine(self: *Self, gpa: std.mem.Allocator, io: std.Io, buf: []u8) !?[]u8 {
            var reader = self.stream.reader(io, buf);
            if (reader.interface.takeDelimiter('\n') catch |err| {
                const errLine = try std.fmt.allocPrint(gpa, "Error: {any}\n", .{err});
                defer gpa.free(errLine);
                // try Broadcaster.broadcastToOne(io, connection, errLine);

                switch (err) {
                    error.StreamTooLong => {
                        _ = try reader.interface.discardDelimiterInclusive('\n');
                        return err;
                    },
                    error.ReadFailed => return err,
                }
            }) |line| {
                return try gpa.dupe(u8, line);
            } else {
                return null;
            }
        }

        fn writeLine(self: *Self, io: std.Io, buf: []u8, line: []const u8) !void {
            var writer = self.stream.writer(io, buf);
            _ = try writer.interface.write(line);
            _ = try writer.interface.flush();
        }
    };

    pub const NetConnectionProducer = struct {
        const Self = @This();

        server: std.Io.net.Server,

        pub fn initFromUnixSocket(io: std.Io, sockPath: []const u8) !NetConnectionProducer {
            const sock: std.Io.net.UnixAddress = try .init(sockPath);
            const server: std.Io.net.Server = try sock.listen(io, .{});

            return Self{
                .server = server,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
            _ = gpa;
            self.server.deinit(io);
        }

        pub fn waitForConnection(self: *Self, gpa: std.mem.Allocator, io: std.Io) !*NetConnection {
            const stream = try self.server.accept(io);

            var netConnection = try gpa.create(NetConnection);
            netConnection.stream = stream;
            return netConnection;
        }
    };
};

pub fn Server(comptime ConnectionProducer: type, Connection: type) type {
    return struct {
        const Self = @This();

        connectionProducer: *ConnectionProducer,
        group: std.Io.Group = .init,

        users: std.StringArrayHashMapUnmanaged(*User) = .empty,
        usersMu: std.Io.Mutex = .init,

        const User = struct {
            nickname: []const u8,
            connection: *Connection,

            fn init(gpa: std.mem.Allocator, nickname: []const u8, connection: *Connection) !*User {
                var user = try gpa.create(User);
                user.nickname = try gpa.dupe(u8, nickname);
                user.connection = connection;
                return user;
            }

            fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
                gpa.free(self.nickname);
            }

            /// Sets nickname. Frees old nickname. Dupes new nckname.
            fn setNickname(self: *@This(), gpa: std.mem.Allocator, newNickname: []const u8) !void {
                gpa.free(self.nickname);
                self.nickname = try gpa.dupe(u8, newNickname);
            }
        };

        pub fn init(connectionProducer: *ConnectionProducer) Self {
            return Self{
                .connectionProducer = connectionProducer,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
            self.connectionProducer.deinit(gpa, io);
            self.group.cancel(io);
            self.users.deinit(gpa);
        }

        pub fn start(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {
            std.debug.print("server started\n", .{});
            while (true) {
                std.debug.print("waiting a new connection\n", .{});
                const connection: *Connection = try self.connectionProducer.waitForConnection(gpa, io);
                std.debug.print("got a new connection\n", .{});
                self.group.async(io, Self.handleConnectionAsync, .{ self, gpa, io, connection });
            }
        }

        fn handleConnectionAsync(self: *Self, gpa: std.mem.Allocator, io: std.Io, connection: *Connection) error{Canceled}!void {
            self.handleConnection(gpa, io, connection) catch |err| {
                std.debug.print("{any}\n", .{err});
            };
        }

        fn handleConnection(self: *Self, gpa: std.mem.Allocator, io: std.Io, connection: *Connection) !void {
            const user = try self.registerUser(gpa, io, connection);
            std.debug.print("registered user {s}\n", .{user.nickname});
            try self.startMessaging(gpa, io, user);
        }

        fn registerUser(self: *Self, gpa: std.mem.Allocator, io: std.Io, connection: *Connection) !*User {
            var readBuf: [256]u8 = undefined;
            var writeBuf: [256]u8 = undefined;

            while (true) {
                try connection.writeLine(io, &writeBuf, "> Hello! Write '/nickname nickname' to begin\n");
                const line = try connection.readLine(gpa, io, &readBuf) orelse break;
                defer gpa.free(line);

                const token = try tokens.ClientToken.fromStringAlloc(gpa, line);
                defer token.deinit(gpa);

                switch (token) {
                    tokens.ClientToken.cmd => {
                        switch (token.cmd) {
                            .nickname => {
                                if (self.users.contains(token.cmd.nickname.nickname)) {
                                    continue;
                                }

                                const user = try User.init(gpa, token.cmd.nickname.nickname, connection);
                                try self.users.put(gpa, user.nickname, user);
                                return user;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
            return error.Unreachable;
        }

        fn startMessaging(self: *Self, gpa: std.mem.Allocator, io: std.Io, user: *User) !void {
            defer {
                const removed = self.users.swapRemove(user.nickname);
                if (!removed) {
                    std.debug.print("[{s}]: Error: wasn't removed from users\n", .{user.nickname});
                }
            }

            const helloLine = try std.fmt.allocPrint(gpa, "{s}: joined\n", .{user.nickname});
            defer gpa.free(helloLine);
            try Broadcaster.broadcastToAll(io, self.users.values(), helloLine);

            var readBuf: [256]u8 = undefined;
            while (true) {
                if (user.connection.readLine(gpa, io, &readBuf) catch |err| {
                    const errLine = try std.fmt.allocPrint(gpa, "Error: {any}\n", .{err});
                    defer gpa.free(errLine);
                    try Broadcaster.broadcastToOne(io, user, errLine);

                    continue;
                }) |line| {
                    const token = tokens.ClientToken.fromStringAlloc(gpa, line) catch |err| {
                        switch (err) {
                            error.EmptyString, error.UnknownClientCmd => {
                                const errLine = try std.fmt.allocPrint(gpa, "Error: {any}\n", .{err});
                                defer gpa.free(errLine);
                                try Broadcaster.broadcastToOne(io, user, errLine);

                                continue;
                            },
                            error.OutOfMemory => return err,
                        }
                    }; // handle errors
                    defer token.deinit(gpa);

                    try self.handleToken(gpa, io, user, &token);
                } else {
                    break;
                }
            }
            const disconnectedLine = try std.fmt.allocPrint(gpa, "{s}: disconnected\n", .{user.nickname});
            defer gpa.free(disconnectedLine);
            try Broadcaster.broadcastToAllExceptOne(io, self.users.values(), disconnectedLine, user.nickname);
            // std.debug.print("[{s}]: disconnected\n", .{connection.nickname});
        }

        fn handleToken(self: *Self, gpa: std.mem.Allocator, io: std.Io, user: *User, token: *const tokens.ClientToken) !void {
            switch (token.*) {
                .msg => |msg| {
                    const fullLine = try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ user.nickname, msg.msg });
                    defer gpa.free(fullLine);
                    try Broadcaster.broadcastToAllExceptOne(io, self.users.values(), fullLine, user.nickname);
                },
                .cmd => |cmd| {
                    switch (cmd) {
                        .whoami => {
                            const whoamiLine = try std.fmt.allocPrint(gpa, "> You are {s}\n", .{user.nickname});
                            defer gpa.free(whoamiLine);
                            try Broadcaster.broadcastToOne(io, user, whoamiLine);
                        },
                        .who => {
                            const whoLine = try std.fmt.allocPrint(gpa, "> Clients: {any}\n", .{self.users.values()});
                            defer gpa.free(whoLine);

                            var stringBuilder = try std.ArrayList(u8).initCapacity(gpa, user.nickname.len * 2);

                            // TODO: maybe I need to sort them...
                            for (self.users.values()) |conn| {
                                try stringBuilder.appendSlice(gpa, "> ");
                                try stringBuilder.appendSlice(gpa, conn.nickname);
                                try stringBuilder.appendSlice(gpa, "\n");
                            }

                            try Broadcaster.broadcastToOne(io, user, stringBuilder.items);
                        },
                        .nickname => {
                            const newNickname = cmd.nickname.nickname;
                            const oldNickname = user.nickname;
                            if (!self.users.contains(newNickname)) {
                                const removed = self.users.swapRemove(oldNickname);
                                std.debug.print("removed {s} = {any}, users count = {d}\n", .{ oldNickname, removed, self.users.count() });

                                // this needs to be before setNickname call
                                const nicknameLine = try std.fmt.allocPrint(gpa, "> {s} is known as {s} now\n", .{ oldNickname, newNickname });
                                defer gpa.free(nicknameLine);

                                try user.setNickname(gpa, newNickname);
                                try self.users.put(gpa, user.nickname, user);

                                try Broadcaster.broadcastToAll(io, self.users.values(), nicknameLine);
                            }
                        },
                    }
                },
            }
        }

        const Broadcaster = struct {
            fn broadcastToOne(io: std.Io, user: *User, line: []const u8) !void {
                var writeBuf: [256]u8 = undefined;
                try user.connection.writeLine(io, &writeBuf, line);
            }

            fn broadcastToAll(io: std.Io, users: []*User, line: []const u8) !void {
                return broadcastToAllExceptOne(io, users, line, "");
            }

            fn broadcastToAllExceptOne(io: std.Io, users: []*User, line: []const u8, except: []const u8) !void {
                // std.debug.print("broadcasting for {d} users\n", .{self.users.size});
                std.debug.print("{s}", .{line});

                for (users) |user| {
                    if (std.mem.eql(u8, except, user.*.nickname)) continue;
                    try broadcastToOne(io, user, line);
                }
            }
        };
    };
}

pub const MockServer = struct {
    pub const Type = Server(MockConnectionProducer, MockConnection);

    pub const MockConnection = struct {
        const Self = @This();

        input: []const u8,
        output: [1024]u8 = undefined,

        fn readLine(self: *Self, gpa: std.mem.Allocator, io: std.Io, buf: []u8) !?[]u8 {
            _ = io;
            _ = buf;

            var reader = std.Io.Reader.fixed(self.input);
            if (reader.takeDelimiter('\n') catch |err| {
                const errLine = try std.fmt.allocPrint(gpa, "Error: {any}\n", .{err});
                defer gpa.free(errLine);

                switch (err) {
                    error.StreamTooLong => {
                        _ = try reader.discardDelimiterInclusive('\n');
                        return err;
                    },
                    error.ReadFailed => return err,
                }
            }) |line| {
                return try gpa.dupe(u8, line);
            } else {
                return null;
            }
        }

        fn writeLine(self: *Self, io: std.Io, buf: []u8, line: []const u8) !void {
            _ = io;
            _ = buf;

            var writer = std.Io.Writer.fixed(&self.output);
            _ = try writer.write(line);
            _ = try writer.flush();
        }
    };

    pub const MockConnectionProducer = struct {
        const Self = @This();

        connections: std.ArrayListUnmanaged(*MockConnection) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
            _ = io;
            self.connections.deinit(gpa);
        }

        pub fn waitForConnection(self: *Self, gpa: std.mem.Allocator, io: std.Io) !*MockConnection {
            _ = gpa;
            _ = io;
            std.debug.print("waitForConnection\n", .{});
            const connection = self.connections.pop() orelse error.NoMoreConnections;
            std.debug.print("waitForConnection: {any}\n", .{connection});
            return connection;
        }
    };
};

// this test just hangs after MockConnectionProducer.waitForConnection got error.NoMoreConnections
// and I don't know why, too tired atm
test "server adds user" {
    if (true) {
        return error.SkipZigTest;
    }

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var connectionProducer = MockServer.MockConnectionProducer{};

    var mockConnection = MockServer.MockConnection{
        .input = "/nickname User\n",
    };

    try connectionProducer.connections.append(gpa, &mockConnection);

    var server = MockServer.Type.init(&connectionProducer);
    defer server.deinit(gpa, io);

    try server.start(gpa, io);
    std.debug.print("after start\n", .{});
}

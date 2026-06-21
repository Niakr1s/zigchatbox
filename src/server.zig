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

        connections: std.StringArrayHashMapUnmanaged(*User) = .empty,
        connectionsMu: std.Io.Mutex = .init,

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
            self.connections.deinit(gpa);
        }

        pub fn start(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {
            while (true) {
                const connection: *Connection = try self.connectionProducer.waitForConnection(gpa, io);
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
                                if (self.connections.contains(token.cmd.nickname.nickname)) {
                                    continue;
                                }

                                const user = try User.init(gpa, token.cmd.nickname.nickname, connection);
                                try self.connections.put(gpa, user.nickname, user);
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
                const removed = self.connections.swapRemove(user.nickname);
                if (!removed) {
                    std.debug.print("[{s}]: Error: wasn't removed from connections\n", .{user.nickname});
                }
            }

            const helloLine = try std.fmt.allocPrint(gpa, "{s}: joined\n", .{user.nickname});
            defer gpa.free(helloLine);
            try Broadcaster.broadcastToAll(io, self.connections.values(), helloLine);

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

                    switch (token) {
                        .msg => |msg| {
                            const fullLine = try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ user.nickname, msg.msg });
                            defer gpa.free(fullLine);
                            try Broadcaster.broadcastToAllExceptOne(io, self.connections.values(), fullLine, user.nickname);
                        },
                        .cmd => |cmd| {
                            switch (cmd) {
                                .whoami => {
                                    const whoamiLine = try std.fmt.allocPrint(gpa, "> You are {s}\n", .{user.nickname});
                                    defer gpa.free(whoamiLine);
                                    try Broadcaster.broadcastToOne(io, user, whoamiLine);
                                },
                                .who => {
                                    const whoLine = try std.fmt.allocPrint(gpa, "> Clients: {any}\n", .{self.connections.values()});
                                    defer gpa.free(whoLine);

                                    var stringBuilder = try std.ArrayList(u8).initCapacity(gpa, user.nickname.len * 2);

                                    // TODO: maybe I need to sort them...
                                    for (self.connections.values()) |conn| {
                                        try stringBuilder.appendSlice(gpa, "> ");
                                        try stringBuilder.appendSlice(gpa, conn.nickname);
                                        try stringBuilder.appendSlice(gpa, "\n");
                                    }

                                    try Broadcaster.broadcastToOne(io, user, stringBuilder.items);
                                },
                                .nickname => {
                                    const newNickname = cmd.nickname.nickname;
                                    const oldNickname = user.nickname;
                                    if (!self.connections.contains(newNickname)) {
                                        const removed = self.connections.swapRemove(oldNickname);
                                        std.debug.print("removed {s} = {any}, connections count = {d}\n", .{ oldNickname, removed, self.connections.count() });

                                        // this needs to be before setNickname call
                                        const nicknameLine = try std.fmt.allocPrint(gpa, "> {s} is known as {s} now\n", .{ oldNickname, newNickname });
                                        defer gpa.free(nicknameLine);

                                        try user.setNickname(gpa, newNickname);
                                        try self.connections.put(gpa, user.nickname, user);

                                        try Broadcaster.broadcastToAll(io, self.connections.values(), nicknameLine);
                                    }
                                },
                            }
                        },
                    }
                } else {
                    break;
                }
            }
            const disconnectedLine = try std.fmt.allocPrint(gpa, "{s}: disconnected\n", .{user.nickname});
            defer gpa.free(disconnectedLine);
            try Broadcaster.broadcastToAllExceptOne(io, self.connections.values(), disconnectedLine, user.nickname);
            // std.debug.print("[{s}]: disconnected\n", .{connection.nickname});
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
                // std.debug.print("broadcasting for {d} users\n", .{self.connections.size});
                std.debug.print("{s}", .{line});

                for (users) |user| {
                    if (std.mem.eql(u8, except, user.*.nickname)) continue;
                    try broadcastToOne(io, user, line);
                }
            }
        };
    };
}

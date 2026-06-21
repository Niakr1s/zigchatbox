const std = @import("std");
const tokens = @import("tokens.zig");

pub const Server = struct {
    const Self = @This();

    server: std.Io.net.Server,
    connections: std.StringArrayHashMapUnmanaged(*Connection) = .empty,
    group: std.Io.Group,

    pub fn init(server: std.Io.net.Server) !Self {
        const group: std.Io.Group = .init;

        return Server{
            .server = server,
            .group = group,
        };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
        self.group.cancel(io);
        self.connections.deinit(gpa);
    }

    pub fn start(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {
        var i: usize = 0;
        while (true) : (i += 1) {
            const stream = try self.server.accept(io);

            // temporary string on the stack
            const username = try std.fmt.allocPrint(gpa, "Anon{d}", .{i});
            defer gpa.free(username);

            const connection = try Connection.init(gpa, username, stream);

            if (self.connections.contains(username)) {
                return error.DuplicateUsername;
            }
            try self.connections.put(gpa, connection.username, connection);

            self.group.async(io, Self.startMessagingAsync, .{ self, gpa, io, connection });
            // try self.startMessaging(io, connection);
        }
    }

    fn startMessagingAsync(self: *Self, gpa: std.mem.Allocator, io: std.Io, connection: *Connection) error{Canceled}!void {
        self.startMessaging(gpa, io, connection) catch |err| {
            std.debug.print("[{s}]: {any}\n", .{ connection.username, err });
        };
    }

    fn startMessaging(self: *Self, gpa: std.mem.Allocator, io: std.Io, connection: *Connection) !void {
        defer {
            const removed = self.connections.swapRemove(connection.username);
            if (!removed) {
                std.debug.print("[{s}]: Error: wasn't removed from connections\n", .{connection.username});
            }
        }

        const helloLine = try std.fmt.allocPrint(gpa, "{s}: joined\n", .{connection.username});
        defer gpa.free(helloLine);
        try Broadcaster.broadcastToAll(io, self.connections.values(), helloLine);

        var readBuf: [256]u8 = undefined;
        var reader = connection.stream.reader(io, &readBuf);

        while (true) {
            if (reader.interface.takeDelimiter('\n') catch |err| {
                const errLine = try std.fmt.allocPrint(gpa, "Error: {any}\n", .{err});
                defer gpa.free(errLine);
                try Broadcaster.broadcastToOne(io, connection, errLine);

                switch (err) {
                    error.StreamTooLong => {
                        _ = try reader.interface.discardDelimiterInclusive('\n');
                        continue;
                    },
                    error.ReadFailed => {
                        continue;
                    },
                }
            }) |line| {
                const token = tokens.ClientToken.fromStringAlloc(gpa, line) catch |err| {
                    switch (err) {
                        error.EmptyString, error.UnknownClientCmd => {
                            const errLine = try std.fmt.allocPrint(gpa, "Error: {any}\n", .{err});
                            defer gpa.free(errLine);
                            try Broadcaster.broadcastToOne(io, connection, errLine);

                            continue;
                        },
                        error.OutOfMemory => return err,
                    }
                }; // handle errors

                switch (token) {
                    .msg => |msg| {
                        const fullLine = try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ connection.username, msg.msg });
                        defer gpa.free(fullLine);
                        try Broadcaster.broadcastToAllExceptOne(io, self.connections.values(), fullLine, connection.username);
                    },
                    .cmd => |cmd| {
                        switch (cmd) {
                            .whoami => {
                                const whoamiLine = try std.fmt.allocPrint(gpa, "> You are {s}\n", .{connection.username});
                                defer gpa.free(whoamiLine);
                                try Broadcaster.broadcastToOne(io, connection, whoamiLine);
                            },
                        }
                    },
                }
            } else {
                break;
            }
        }
        const disconnectedLine = try std.fmt.allocPrint(gpa, "{s}: disconnected\n", .{connection.username});
        defer gpa.free(disconnectedLine);
        try Broadcaster.broadcastToAllExceptOne(io, self.connections.values(), disconnectedLine, connection.username);
        // std.debug.print("[{s}]: disconnected\n", .{connection.username});
    }
};

const Broadcaster = struct {
    const Self = @This();
    const WRITE_BUF_SZ = 256;

    fn broadcastToOne(io: std.Io, connection: *Connection, line: []const u8) !void {
        var writeBuf: [WRITE_BUF_SZ]u8 = undefined;
        var writer = connection.*.stream.writer(io, &writeBuf);
        _ = try writer.interface.write(line);
        _ = try writer.interface.flush();
    }

    fn broadcastToAll(io: std.Io, connections: []*Connection, line: []const u8) !void {
        return Self.broadcastToAllExceptOne(io, connections, line, "");
    }

    fn broadcastToAllExceptOne(io: std.Io, connections: []*Connection, line: []const u8, except: []const u8) !void {
        // std.debug.print("broadcasting for {d} users\n", .{self.connections.size});
        std.debug.print("{s}", .{line});

        for (connections) |connection| {
            if (std.mem.eql(u8, except, connection.*.username)) continue;
            try broadcastToOne(io, connection, line);
        }
    }
};

const Connection = struct {
    const Self = @This();

    username: []const u8,
    stream: std.Io.net.Stream,

    /// Args:
    ///   username: will be duplicated and owned
    fn init(gpa: std.mem.Allocator, username: []const u8, stream: std.Io.net.Stream) !*Connection {
        const connection = try gpa.create(Connection);
        errdefer gpa.destroy(connection);

        connection.username = try gpa.dupe(u8, username);
        errdefer gpa.destroy(connection.username);

        connection.stream = stream;
        return connection;
    }

    fn deinit(self: *Self, gpa: std.mem.Allocator, io: std.Io) void {
        self.stream.close(io);
        gpa.free(self.username);
        gpa.destroy(self);
    }

    // Blocks until something was read
    fn next(self: *Self, gpa: std.mem.Allocator) !?tokens.ClientToken {
        const line = try self.reader.takeDelimiter('\n') orelse return null;
        const token = try tokens.ClientToken.fromStringAlloc(gpa, line);
        return token;
    }
};

// test "Connection reads from writer" {
//     const gpa = std.testing.allocator;
//
//     const line1 = "hello world";
//     const line = line1 ++ "\n";
//     var reader = std.Io.Reader.fixed(line);
//
//     var writerBuf: [1024]u8 = undefined;
//     var writer = std.Io.Writer.fixed(&writerBuf);
//
//     var connection = try Connection.init(gpa, "Anon", &reader, &writer);
//     defer connection.deinit(gpa);
//
//     const token = try connection.next(gpa) orelse return error.GotNullToken;
//     defer token.deinit(gpa);
//
//     try std.testing.expectEqualStrings(line1, token.msg.msg);
//
//     try std.testing.expectEqual(null, try connection.next(gpa));
//     try std.testing.expectEqual(null, try connection.next(gpa));
// }

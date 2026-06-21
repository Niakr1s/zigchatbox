const std = @import("std");
const tokens = @import("tokens.zig");

pub const Server = struct {
    const Self = @This();

    server: std.Io.net.Server,
    connections: std.StringHashMapUnmanaged(*Connection) = .empty,
    group: std.Io.Group,

    pub fn init(server: std.Io.net.Server) !Self {
        const connections: std.Io.Group = .init;

        return Server{
            .server = server,
            .group = connections,
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
            const removed = self.connections.remove(connection.username);
            if (!removed) {
                std.debug.print("[{s}]: Error: wasn't removed from connections\n", .{connection.username});
            }
        }

        const helloLine = try std.fmt.allocPrint(gpa, "{s} joined\n", .{connection.username});
        defer gpa.free(helloLine);
        try self.broadcast(io, helloLine);

        var readBuf: [256]u8 = undefined;
        var reader = connection.stream.reader(io, &readBuf);

        while (try reader.interface.takeDelimiter('\n')) |line| {
            const fullLine = try std.fmt.allocPrint(gpa, "{s}: {s}\n", .{ connection.username, line });
            defer gpa.free(fullLine);
            try self.broadcastExceptOne(io, fullLine, connection.username);
        }
        const disconnectedLine = try std.fmt.allocPrint(gpa, "{s}: disconnected\n", .{connection.username});
        defer gpa.free(disconnectedLine);
        try self.broadcastExceptOne(io, disconnectedLine, connection.username);
        // std.debug.print("[{s}]: disconnected\n", .{connection.username});
    }

    fn broadcast(self: *Self, io: std.Io, line: []const u8) !void {
        return self.broadcastExceptOne(io, line, "");
    }

    fn broadcastExceptOne(self: *Self, io: std.Io, line: []const u8, except: []const u8) !void {
        std.debug.print("broadcasting for {d} users\n", .{self.connections.size});
        var iter = self.connections.valueIterator();
        while (iter.next()) |connection| {
            if (std.mem.eql(u8, except, connection.*.username)) continue;

            var writeBuf: [256]u8 = undefined;
            var writer = connection.*.stream.writer(io, &writeBuf);
            _ = try writer.interface.write(line);
            _ = try writer.interface.flush();
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

const std = @import("std");
const tokens = @import("tokens.zig");

fn startServer(io: std.Io) !void {
    const sock: std.Io.net.UnixAddress = try .init("/tmp/zigchatbot.sock");
    const server: std.Io.net.Server = try sock.listen(io, .{});
    _ = server;
}

const Server = struct {
    const Self = @This();

    server: std.Io.net.Server,
    connections: std.ArrayListUnmanaged(Connection),

    fn init(gpa: std.mem.Allocator, server: std.Io.net.Server) !void {
        const connections: std.ArrayListUnmanaged(Connection) = try .initCapacity(gpa, 4);
        return Server{
            .server = server,
            .connections = connections,
        };
    }

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.connections.deinit(gpa);
    }

    fn start(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {
        var i = 0;
        while (true) : (i += 1) {
            const stream = try self.server.accept(io);

            const username = std.fmt.allocPrint(gpa, "Anon{d}", .{i});
            defer gpa.free(username);

            var readerBuf: [1024]u8 = undefined;
            var writerBuf: [1024]u8 = undefined;

            const connection = Connection{
                .username = username,
                .reader = stream.reader(io, &readerBuf),
                .writer = stream.writer(io, &writerBuf),
            };
            self.startMessaging(io, connection);
        }
    }

    fn startMessaging(_: *Self, io: std.Io, connection: Connection) void {
        _ = io;
        _ = connection;
    }
};

const Connection = struct {
    const Self = @This();

    username: []const u8,
    reader: *tokens.ClientTokenReader,
    writer: *std.Io.Writer,

    fn init(gpa: std.mem.Allocator, username: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !Connection {
        const usernameDupe = try gpa.dupe(u8, username);

        const tokenReader = try gpa.create(tokens.ClientTokenReader);
        tokenReader.* = .{ .reader = reader };

        return .{
            .username = usernameDupe,
            .reader = tokenReader,
            .writer = writer,
        };
    }

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.username);
        gpa.destroy(self.reader);
    }

    // Blocks until something was read
    fn read(self: *Self, gpa: std.mem.Allocator) !?tokens.ClientToken {
        return self.reader.next(gpa);
    }
};

test "Connection reads from writer" {
    const gpa = std.testing.allocator;

    const line1 = "hello world";
    const line = line1 ++ "\n";
    var reader = std.Io.Reader.fixed(line);

    var writerBuf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&writerBuf);

    var connection = try Connection.init(gpa, "Anon", &reader, &writer);
    defer connection.deinit(gpa);

    const token = try connection.read(gpa) orelse return error.GotNullToken;
    defer token.deinit(gpa);

    try std.testing.expectEqualStrings(line1, token.msg.msg);

    try std.testing.expectEqual(null, try connection.read(gpa));
    try std.testing.expectEqual(null, try connection.read(gpa));
}

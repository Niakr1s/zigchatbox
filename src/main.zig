const std = @import("std");
const Io = std.Io;

const zigchatbot = @import("zigchatbot");
const Server = zigchatbot.server.Server;
const NetServer = zigchatbot.server.NetServer;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const sockPath = "/tmp/zigchatbot.sock";
    try std.Io.Dir.deleteFileAbsolute(io, sockPath);

    var producer = try NetServer.NetConnectionProducer.initFromUnixSocket(io, sockPath);
    defer producer.deinit(gpa, io);

    var server = NetServer.Type.init(&producer);
    defer server.deinit(gpa, io);

    try server.start(gpa, io);

    // const sock: std.Io.net.UnixAddress = try .init(sockPath);
    // const server: std.Io.net.Server = try sock.listen(io, .{});
    // var zigchatbotServer = try zigchatbot.server.Server.init(server);
    // defer zigchatbotServer.deinit(gpa, io);
    //
    // try zigchatbotServer.start(gpa, io);
}

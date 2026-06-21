const std = @import("std");
const Io = std.Io;

const zigchatbot = @import("zigchatbot");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const sockPath = "/tmp/zigchatbot.sock";
    try std.Io.Dir.deleteFileAbsolute(io, sockPath);

    const sock: std.Io.net.UnixAddress = try .init(sockPath);
    const server: std.Io.net.Server = try sock.listen(io, .{});
    var zigchatbotServer = try zigchatbot.server.Server.init(server);
    defer zigchatbotServer.deinit(gpa, io);

    try zigchatbotServer.start(gpa, io);
}

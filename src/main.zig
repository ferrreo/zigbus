const std = @import("std");
const testing = std.testing;
const typesys = @import("typesys.zig");
const DBusType = typesys.DBusType;
const Signature = typesys.Signature;
const BytesReader = @import("bytes.zig").BytesReader;

const Connector = struct {
    pub fn init() void {}
};

const Connection = struct {
    bus_type: BusType,

    outbox: void, // Queues of messages we are sending
    inbox: void, // Queues of messages we are receiving
    filters: void, // List of filters

    client_serial: u32, // increments for each message sent

    pub fn send() void {}
};

const BusType = enum {
    Session,
    System,
};

pub fn connector(comptime conn_type: BusType) Connector {
    switch (conn_type) {
        BusType.Session => unreachable,
        BusType.System => unreachable,
    }
}

pub fn createMessage() void {}
pub fn addMessageArgument() void {}

const DBusObj = struct {
    path: []const u8,
};

// The path may be of any length.
//
// The path must begin with an ASCII '/' (integer 47) character, and must consist of elements separated by slash characters.
//
// Each element must only contain the ASCII characters "[A-Z][a-z][0-9]_"
//
// No element may be the empty string.
//
// Multiple '/' characters cannot occur in sequence.
//
// A trailing '/' character is not allowed unless the path is the root path (a single '/' character).
fn is_valid_object_path(path: []const u8) bool {
    if (path.len == 0) {
        return false;
    }

    if (path[0] != '/') {
        return false;
    }

    var last_char: u8 = 0;
    for (path) |c| {
        if (c == '/') {
            if (last_char == '/') {
                return false;
            }
        } else {
            if (c != '_' and ((c < '0') or (c > '9')) and (c < 'a' or c > 'z') and (c < 'A' or c > 'Z')) {
                return false;
            }
        }
        last_char = c;
    }

    if (last_char == '/') {
        return path.len == 1;
    }

    return true;
}

test "validate object path checking 1" {
    try testing.expectEqual(true, is_valid_object_path("/"));
    try testing.expectEqual(true, is_valid_object_path("/a"));
    try testing.expectEqual(true, is_valid_object_path("/a/b"));
    try testing.expectEqual(true, is_valid_object_path("/a/b/c"));
    try testing.expectEqual(true, is_valid_object_path("/a/b/c/d"));
    try testing.expectEqual(true, is_valid_object_path("/a/b/c/d/e"));
    try testing.expectEqual(true, is_valid_object_path("/com/example/MusicPlayer1"));
}

test "validate object path checking 2" {
    try testing.expectEqual(false, is_valid_object_path(""));
    try testing.expectEqual(false, is_valid_object_path("a"));
    try testing.expectEqual(false, is_valid_object_path("a//b"));
    try testing.expectEqual(false, is_valid_object_path("a/b/"));
}

test {
    _ = @import("typesys.zig");
    _ = @import("bytes.zig");
    _ = @import("msg.zig");
}

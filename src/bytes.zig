//! Utilities for reading bytes.

const std = @import("std");
const typesys = @import("typesys.zig");
const DBusType = typesys.DBusType;
const Signature = typesys.Signature;
const testing = std.testing;
const Endian = std.builtin.Endian;

/// `BytesReader` is a simple utility struct to help consuming bytes
/// by alignment specified by a data type.
///
/// `next` method reads proper amount of bytes according to the alignment of the type.
/// If the reader meets the end of bytes, it returns EndOfStream error.
pub const BytesReader = struct {
    bytes: []const u8,
    endian: Endian = std.builtin.Endian.Big,
    pos: usize = 0,

    const Self = @This();

    const BytesReaderError = error{
        InvalidAlignment,
        InvalidLength,
        EndOfStream,
    };

    /// Consume bytes of a fix-sized type.
    pub fn next(self: *Self, comptime T: anytype) BytesReaderError!T {
        const alignment = @sizeOf(T);
        if (alignment != 1 and alignment != 2 and alignment != 4 and alignment != 8) {
            std.debug.print("alignment: {d}\n", .{alignment});
            return BytesReaderError.InvalidAlignment;
        }
        if (self.pos == self.bytes.len) {
            return BytesReaderError.EndOfStream;
        }
        if (alignment + self.pos > self.bytes.len) {
            return BytesReaderError.InvalidAlignment;
        }

        const value = std.mem.readIntSlice(T, self.bytes[self.pos..(self.pos + alignment)], self.endian);
        self.pos += alignment;
        return value;
    }

    pub fn skip(self: *Self, length: usize) BytesReaderError!void {
        if (self.pos == self.bytes.len) {
            return BytesReaderError.EndOfStream;
        }
        if (length + self.pos > self.bytes.len) {
            return BytesReaderError.InvalidAlignment;
        }
        self.pos += length;
    }

    pub fn take(self: *Self, length: usize) BytesReaderError![]const u8 {
        if (self.pos == self.bytes.len) {
            return BytesReaderError.EndOfStream;
        }
        if (length + self.pos > self.bytes.len) {
            return BytesReaderError.InvalidAlignment;
        }
        const taken = self.bytes[self.pos..(self.pos + length)];
        self.pos += length;
        return taken;
    }

    /// Consume bytes of a string.
    pub fn nextString(self: *Self) ![]const u8 {
        // string is encoded in 4-byte alignment
        // the first 4-byte indicates the length of the string
        const length: u32 = try self.next(u32);
        if (length == 0) {
            return BytesReaderError.InvalidLength;
        }
        // round up `length` to the next 4-byte boundary
        const boundary: usize = (length + 3) & (~@as(usize, 3));
        const str: []const u8 = try self.take(boundary);
        var end: usize = boundary - 1;
        while (str[end] == 0) {
            end -= 1;
        }
        return str[0..(end + 1)];
    }
};

test "reader can comsume basic types -- u32 little endian" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Little };
    const first = try reader.next(u8);
    try testing.expectEqual(@as(u8, 0x12), first);
    const second = try reader.next(i16);
    try testing.expectEqual(@as(i16, 0x5634), second);
    const last = try reader.next(u8);
    try testing.expectEqual(@as(u8, 0x78), last);
}

test "reader can comsume basic types -- u32 big endian" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
    const first = try reader.next(u8);
    const second = try reader.next(i16);
    const last = try reader.next(u8);
    try testing.expectEqual(first, 0x12);
    try testing.expectEqual(second, 0x3456);
    try testing.expectEqual(last, 0x78);
}

fn test_string(str: [:0]const u8, bytes: []const u8) !void {
    var reader = BytesReader{ .bytes = bytes, .endian = Endian.Little };
    const string: []const u8 = try reader.nextString();
    try testing.expectEqualSlices(u8, str, string);
}

test "reader can consume string 1" {
    const bytes: []const u8 = &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x66, 0x6f, 0x6f, 0x00 };
    try test_string("foo", bytes);
}

test "reader can consume string 2" {
    const bytes: []const u8 = &[_]u8{
        0x01, 0x00, 0x00, 0x00,
        0x2b, 0x00, 0x00, 0x00,
    };
    try test_string("+", bytes);
}

test "reader can consume string 3" {
    // "Hello, world!"
    const bytes: []const u8 = &[_]u8{
        0x0d, 0x00, 0x00, 0x00,
        0x48, 0x65, 0x6c, 0x6c,
        0x6f, 0x2c, 0x20, 0x77,
        0x6f, 0x72, 0x6c, 0x64,
        0x21, 0x00, 0x00, 0x00,
    };
    try test_string("Hello, world!", bytes);
}

test "reader can consume many strings" {
    const bytes: []const u8 = &[_]u8{
        0x03, 0x00, 0x00, 0x00, 0x66, 0x6f, 0x6f, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x62, 0x61, 0x72, 0x00,
    };
    var reader = BytesReader{ .bytes = bytes, .endian = Endian.Little };
    const str1: []const u8 = try reader.nextString();
    const str2: []const u8 = try reader.nextString();
    const str3: []const u8 = try reader.nextString();
    try testing.expectEqualSlices(u8, "foo", str1);
    try testing.expectEqualSlices(u8, "+", str2);
    try testing.expectEqualSlices(u8, "bar", str3);
}

test "reader stops when it meets end of bytes" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Little };
    const first: u8 = try reader.next(u8);
    const second: i16 = try reader.next(i16);
    try testing.expectEqual(@as(u8, 0x12), first);
    try testing.expectEqual(@as(i16, 0x5634), second);
    const last = reader.next(u8);

    try testing.expectError(BytesReader.BytesReaderError.EndOfStream, last);
}

test "reader can consume array of int64" {
    const bytes = [_]u8{
        0x00, 0x00, 0x00, 0x08, // 8 bytes of data (length is marshalled as u32)
        0x00, 0x00, 0x00, 0x00, // padding to 8-byte boundary (alignment of int64)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x05, // first element = 5
    };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
    const array_length = try reader.next(u32);
    try testing.expectEqual(@as(u32, 8), array_length);
    _ = try reader.next(u32);
    const five: i64 = try reader.next(i64); // comsume 8 bytes
    try testing.expectEqual(@as(i64, 5), five);
    const last = reader.next(i64);
    try testing.expectError(
        BytesReader.BytesReaderError.EndOfStream,
        last,
    );
}

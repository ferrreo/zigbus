const std = @import("std");
const testing = std.testing;
const Endian = std.builtin.Endian;

/// `BytesReader` is a utility struct to help consuming bytes
/// by alignment specified by a data type.
///
/// `next` method reads proper amount of bytes according to the alignment of the type.
/// If the reader meets the end of bytes, it returns null.
/// The caller is responsible to check the return value is null.
const BytesReader = struct {
    bytes: []const u8,
    endian: Endian,

    const Self = @This();

    const BytesReaderError = error{
        InvalidAlignment,
    };

    pub fn next(self: *Self, comptime T: anytype) BytesReaderError!?T {
        if (self.bytes.len == 0) {
            return null;
        } else {
            const alignment = @sizeOf(T);
            if (alignment == 0 or alignment > self.bytes.len) {
                return BytesReaderError.InvalidAlignment;
            }
            const value = std.mem.readIntSlice(T, self.bytes, self.endian);
            self.bytes = self.bytes[alignment..];
            return value;
        }
    }

    // string is encoded in 4-byte alignment
    pub fn nextString(self: *Self) !?[]const u8 {
        // the first 4-byte indicates the length of the string
        const length: ?u32 = try self.next(u32);
        if (length == null) {
            return null;
        }
        // round up `length` to the next 4-byte boundary
        const boundary: usize = (length.? + 3) & (~@as(usize, 3));
        const long_str = self.bytes[0..boundary];
        var end = boundary;
        // drop the last NUL bytes,
        // as `long_str` contains unnecessary NUL bytes at the end
        // because of the 4-byte alignment
        while (end > 0 and long_str[end - 1] == 0) {
            end -= 1;
        }

        const bytes = self.bytes;
        self.bytes = self.bytes[boundary..];
        return bytes[0..end];
    }
};

test "reader can comsume basic types -- u32 little endian" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Little };
    const first = reader.next(u8);
    const second = reader.next(i16);
    const last = reader.next(u8);
    try testing.expectEqual(first, 0x12);
    try testing.expectEqual(second, 0x5634);
    try testing.expectEqual(last, 0x78);
}

test "reader can comsume basic types -- u32 big endian" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
    const first = try reader.next(u8);
    const second = try reader.next(i16);
    const last = try reader.next(u8);
    try testing.expectEqual(first.?, 0x12);
    try testing.expectEqual(second.?, 0x3456);
    try testing.expectEqual(last.?, 0x78);
}

fn test_string(str: [:0]const u8, bytes: []const u8) !void {
    var reader = BytesReader{ .bytes = bytes, .endian = Endian.Little };
    const string: ?[]const u8 = try reader.nextString();
    try testing.expectEqualSlices(u8, str, string.?);
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
    const bytes: []const u8 = &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x62, 0x61, 0x72, 0x00 };
    try test_string("bar", bytes);
}

test "reader can consume many strings" {
    const bytes: []const u8 = &[_]u8{
        0x03, 0x00, 0x00, 0x00, 0x66, 0x6f, 0x6f, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x62, 0x61, 0x72, 0x00,
    };
    var reader = BytesReader{ .bytes = bytes, .endian = Endian.Little };
    const str1: ?[]const u8 = try reader.nextString();
    const str2: ?[]const u8 = try reader.nextString();
    const str3: ?[]const u8 = try reader.nextString();
    try testing.expectEqualSlices(u8, "foo", str1.?);
    try testing.expectEqualSlices(u8, "+", str2.?);
    try testing.expectEqualSlices(u8, "bar", str3.?);
}

// test "reader stops when it meets end of bytes" {
//     const bytes = [_]u8{ 0x12, 0x34, 0x56 };
//     var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Little };
//     const first: ?u8 = try reader.next(DBusType.BYTE);
//     const second: ?i16 = try reader.next(DBusType.INT16);
//     const last: ?u8 = try reader.next(DBusType.BYTE); // this must return null
//     try testing.expectEqual(@as(u8, 0x12), first.?);
//     try testing.expectEqual(@as(i16, 0x5634), second.?);
//     try testing.expect(last == null);
// }

// test "reader can consume array of int64" {
//     const bytes = [_]u8{
//         0x00, 0x00, 0x00, 0x08, // 8 bytes of data (length is marshalled as u32)
//         0x00, 0x00, 0x00, 0x00, // padding to 8-byte boundary (alignment of int64)
//         0x00, 0x00, 0x00, 0x00,
//         0x00, 0x00, 0x00, 0x05, // first element = 5
//     };
//     var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
//     var arrayReader = try reader.next(DBusType.ARRAY);
//     const five: ?i64 = try arrayReader.?.next(DBusType.INT64);
//     const end: ?i64 = try arrayReader.?.next(DBusType.INT64);
//     try testing.expectEqual(@as(i64, 5), five.?);
//     try testing.expect(end == null);
// }

// // we need to some how pass the type of inner data of array to the reader
// // to properly infer the length of padding

// test "reader can consume variant" {
//     // 0x01 0x74 0x00                          signature bytes (length = 1, signature = 't' and trailing nul)
//     //                0x00 0x00 0x00 0x00 0x00 padding to 8-byte boundary
//     // 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x05 8 bytes of contained value
//     const bytes = [_]u8{
//         0x01, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
//         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
//     };
//     var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
//     var variantReader = try reader.next(DBusType.VARIANT);
//     _ = variantReader;
// }

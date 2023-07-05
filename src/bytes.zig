const std = @import("std");
const testing = std.testing;
const Endian = std.builtin.Endian;
const typesys = @import("typesys.zig");
const DBusType = typesys.DBusType;

/// `BytesReader` comsumes bytes by alignment
/// It only performs bytes consumption and returns the bytes,
/// therefore it is not responsible for parsing the bytes.
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

    fn decideReturnType(comptime T: DBusType) type {
        return switch (T) {
            // basic types
            .BYTE => u8,
            .BOOLEAN => bool,
            .INT16 => i16,
            .UINT16 => u16,
            .INT32 => i32,
            .UINT32 => u32,
            .INT64 => i64,
            .UINT64 => u64,
            .DOUBLE => f64,
            .UNIX_FD => u32,

            // string-like types
            .STRING => []const u8,
            .OBJECT_PATH => []const u8,
            .SIGNATURE => []const u8,

            // container types
            .STRUCT => BytesReader,
            .VARIANT => BytesReader,
            .ARRAY => BytesReader,
            .DICT_ENTRY => BytesReader,
        };
    }

    pub fn next(self: *Self, comptime ReadType: DBusType) BytesReaderError!?decideReturnType(ReadType) {
        if (self.bytes.len == 0) {
            return null;
        } else {
            return switch (ReadType) {
                .BYTE,
                .BOOLEAN,
                .INT16,
                .UINT16,
                .INT32,
                .UINT32,
                .INT64,
                .UINT64,
                .DOUBLE,
                .UNIX_FD,
                => self.read_basic(ReadType),
                .STRING,
                .OBJECT_PATH,
                .SIGNATURE,
                => self.read_len_bytes(ReadType),
                .STRUCT,
                .VARIANT,
                .ARRAY,
                .DICT_ENTRY,
                => self.read_len_container(ReadType),
            };
        }
    }

    fn read_basic(self: *Self, comptime ReadType: DBusType) BytesReaderError!?DBusType.nativeType(ReadType) {
        // alignment here specifies how many bytes lie on the memory
        // to represent the `ReadType` value
        const alignment = DBusType.alignment(ReadType);
        if (self.bytes.len < alignment) {
            return BytesReaderError.InvalidAlignment;
        }
        const bytes_to_read = self.bytes[0..alignment];
        self.bytes = self.bytes[alignment..];
        return std.mem.readInt(ReadType.nativeType(), bytes_to_read, self.endian);
    }

    fn read_len_bytes(self: *Self, comptime ReadType: DBusType) BytesReaderError!?DBusType.nativeType(ReadType) {
        // alignment here specifies how many bytes are at the head of the bytes
        // to specify the length of the data
        const alignment = DBusType.alignment(ReadType);
        const alignment_type = ReadType.alignment_type();
        const bytes_length = std.mem.readInt(alignment_type, self.bytes[0..alignment], self.endian);
        const bytes = self.bytes[alignment..(alignment + bytes_length)];
        return bytes;
    }

    fn read_len_container(self: *Self, comptime ReadType: DBusType) BytesReaderError!?BytesReader {
        // alignment here specifies how many bytes to read the length of total data
        const alignment = DBusType.alignment(ReadType);
        const alignment_type = ReadType.alignment_type();
        const bytes_length = std.mem.readInt(alignment_type, self.bytes[0..alignment], self.endian);
        const bytes = self.bytes[alignment..(alignment + bytes_length)];
        return BytesReader{ .bytes = bytes, .endian = self.endian };
    }
};

const ArrayReader = struct {
    /// `innerTypes` specifies the types of the elements in the array
    innerTypes: []const DBusType,
};

test "reader can comsume basic types -- u32 little endian" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Little };
    const first = reader.next(DBusType.BYTE);
    const second = reader.next(DBusType.INT16);
    const last = reader.next(DBusType.BYTE);
    try testing.expectEqual(first, 0x12);
    try testing.expectEqual(second, 0x5634);
    try testing.expectEqual(last, 0x78);
}

test "reader can comsume basic types -- u32 big endian" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
    const first = try reader.next(DBusType.BYTE);
    const second = try reader.next(DBusType.INT16);
    const last = try reader.next(DBusType.BYTE);
    try testing.expectEqual(first.?, 0x12);
    try testing.expectEqual(second.?, 0x3456);
    try testing.expectEqual(last.?, 0x78);
}

test "reader can comsume string 1" {
    // string 'foo' of length 3
    const bytes = [_]u8{ 0x03, 0x00, 0x00, 0x00, 0x66, 0x6f, 0x6f, 0x00 };
    var reader = BytesReader{ .bytes = &bytes, .endian = Endian.Little };
    const str = try reader.next(DBusType.STRING);
    try testing.expectEqualStrings("foo", str.?);
}

test "reader can consume string 2" {
    // string '+' of length 1
    const bytes = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00 };
    var reader = BytesReader{ .bytes = &bytes, .endian = Endian.Little };
    const str = try reader.next(DBusType.STRING);
    try testing.expectEqualStrings("+", str.?);
}

test "reader can consume string 3" {
    // string 'bar' of length 3
    const bytes = [_]u8{ 0x03, 0x00, 0x00, 0x00, 0x62, 0x61, 0x72, 0x00 };
    var reader = BytesReader{ .bytes = &bytes, .endian = Endian.Little };
    const str = try reader.next(DBusType.STRING);
    try testing.expectEqualStrings("bar", str.?);
}

test "reader stops when it meets end of bytes" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56 };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Little };
    const first: ?u8 = try reader.next(DBusType.BYTE);
    const second: ?i16 = try reader.next(DBusType.INT16);
    const last: ?u8 = try reader.next(DBusType.BYTE); // this must return null
    try testing.expectEqual(@as(u8, 0x12), first.?);
    try testing.expectEqual(@as(i16, 0x5634), second.?);
    try testing.expect(last == null);
}

test "reader can consume array of int64" {
    const bytes = [_]u8{
        0x00, 0x00, 0x00, 0x08, // 8 bytes of data (length is marshalled as u32)
        0x00, 0x00, 0x00, 0x00, // padding to 8-byte boundary (alignment of int64)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x05, // first element = 5
    };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
    var arrayReader = try reader.next(DBusType.ARRAY);
    const five: ?i64 = try arrayReader.?.next(DBusType.INT64);
    const end: ?i64 = try arrayReader.?.next(DBusType.INT64);
    try testing.expectEqual(@as(i64, 5), five.?);
    try testing.expect(end == null);
}

// we need to some how pass the type of inner data of array to the reader
// to properly infer the length of padding

test "reader can consume variant" {
    // 0x01 0x74 0x00                          signature bytes (length = 1, signature = 't' and trailing nul)
    //                0x00 0x00 0x00 0x00 0x00 padding to 8-byte boundary
    // 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x05 8 bytes of contained value
    const bytes = [_]u8{
        0x01, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
    };
    var reader = BytesReader{ .bytes = &bytes, .endian = std.builtin.Endian.Big };
    var variantReader = try reader.next(DBusType.VARIANT);
    _ = variantReader;
}

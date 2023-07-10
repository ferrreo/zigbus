///! This module implements the D-Bus type system.
const std = @import("std");
const testing = std.testing;
const Endian = std.builtin.Endian;
const Allocator = std.mem.Allocator;

// Array: array of type T
// Arrays have a maximum length defined to be 2 to the 26th power or 67108864 (64 MiB).
// | n (UINT32) = byte length of elements | padding for alignment of T | element 1 | element 2 | ... | element n |
// For example, array of signature at is marshalled as:
// 00 00 00 08               n = 8 bytes of data
// 00 00 00 00               padding to 8-byte boundary
// 00 00 00 00  00 00 00 05  first element = 5

// Structs and dict entries are marshalled in the same way as their contents,
// but their alignment is always to an 8-byte boundary, even if their contents would normally be less strictly aligned.

// Variants are marshalled as the SIGNATURE of the contents (which must be a single complete type),
// followed by a marshalled value with the type given by that signature.
// The variant has the same 1-byte alignment as the signature, which means that alignment padding before a variant is never needed.
// Use of variants must not cause a total message depth to be larger than 64, including other container types such as structures. (See Valid Signatures.)
// For instance, if the current position in the message is at a multiple of 8 bytes and the byte-order is big-endian, a variant containing a 64-bit integer 5 would be marshalled as:

// 0x01 0x74 0x00                          signature bytes (length = 1, signature = 't' and trailing nul)
//                0x00 0x00 0x00 0x00 0x00 padding to 8-byte boundary
// 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x05 8 bytes of contained value

/// Represents a DBus type, vectorized.
/// Consuming a signature (a sequence of DBusType) is done sequentially, always.
pub const DBusType = union(enum) {
    BYTE_TYPE: void,
    BOOLEAN_TYPE: void,
    INT16_TYPE: void,
    UINT16_TYPE: void,
    INT32_TYPE: void,
    UINT32_TYPE: void,
    INT64_TYPE: void,
    UINT64_TYPE: void,
    DOUBLE_TYPE: void,
    UNIX_FD_TYPE: void,

    STRING_TYPE: void,
    OBJECT_PATH_TYPE: void,
    SIGNATURE_TYPE: void,

    VARIANT_TYPE: void,

    // A struct type is vectorized into (length, type1, type2, ...).
    // To use a struct type, the caller read types `length` times.
    STRUCT_TYPE: void,
    STRUCT_LENGTH: u8,

    // An array is always followed by a single complete type.
    ARRAY_TYPE: void,

    // An dict entry works exactly as same as a struct.
    DICT_ENTRY_TYPE: void,
    DICT_ENTRY_LENGTH: u8,

    pub fn alignment(comptime T: DBusType) comptime_int {
        return switch (T) {
            DBusType.BYTE_TYPE => 1,
            DBusType.BOOLEAN_TYPE => 4,
            DBusType.INT16_TYPE => 2,
            DBusType.UINT16_TYPE => 2,
            DBusType.INT32_TYPE => 4,
            DBusType.UINT32_TYPE => 4,
            DBusType.INT64_TYPE => 8,
            DBusType.UINT64_TYPE => 8,
            DBusType.DOUBLE_TYPE => 8,
            DBusType.UNIX_FD_TYPE => 4,

            // For string-like types, it returns the alignment for the length value
            DBusType.STRING_TYPE => 4,
            DBusType.OBJECT_PATH_TYPE => 4,
            DBusType.SIGNATURE_TYPE => 1, // The length of a signature does not exceed 255

            DBusType.VARIANT_TYPE => 1,
            DBusType.ARRAY_TYPE => 4,

            DBusType.STRUCT_TYPE => 8,
            DBusType.DICT_ENTRY_TYPE => 8,
            else => unreachable,
        };
    }
};

pub const DBusValue = union(DBusType) {
    BYTE_TYPE: u8,
    BOOLEAN_TYPE: bool,
    INT16_TYPE: i16,
    UINT16_TYPE: u16,
    INT32_TYPE: i32,
    UINT32_TYPE: u32,
    INT64_TYPE: i64,
    UINT64_TYPE: u64,
    DOUBLE_TYPE: f64,
    UNIX_FD_TYPE: i32,

    STRING_TYPE: []const u8,
    OBJECT_PATH_TYPE: []const u8,
    SIGNATURE_TYPE: []const u8,

    VARIANT_TYPE: DBusValue,
    ARRAY_TYPE: struct { inner: []DBusValue },
    STRUCT_TYPE: struct { inner: []DBusValue },
    DICT_ENTRY_TYPE: struct { key: DBusValue, value: DBusValue },
};

pub const TypeSigToken = enum(u8) {
    NONE = 0, //  Not a valid type code. For termination.
    BYTE = 'y',
    BOOLEAN = 'b',
    INT16 = 'n',
    UINT16 = 'q',
    INT32 = 'i',
    UINT32 = 'u',
    INT64 = 'x',
    UINT64 = 't',
    DOUBLE = 'd',
    UNIX_FD = 'h',

    // The string-like types are basic types with a variable length.
    // The marshalling formats for the string-like types all end
    // with a single zero (NUL) byte, but that byte is not considered to be part of the text.
    STRING = 's',
    OBJECT_PATH = 'o', // Must be a syntactically valid object path.
    SIGNATURE = 'g', // Zero or more single complete types

    VARIANT = 'v',

    // STRUCT_R = 'r',
    STRUCT_OPEN = '(',
    STRUCT_CLOSE = ')',
    ARRAY = 'a',
    // DICT_E = 'e',
    DICT_OPEN = '{',
    DICT_CLOSE = '}',
};

pub const Signature = struct {
    vectorized: std.ArrayList(DBusType) = undefined,

    const Self = @This();

    const SignatureError = error{
        NotSingleType,
        EmptySignature,
    };

    pub fn make(bytes: []const u8, allocator: Allocator) !Self {
        var sig = Signature{};

        try sig.parse(bytes, allocator);

        return sig;
    }

    pub fn deinit(self: *Self) void {
        self.vectorized.deinit();
    }

    fn parse(self: *Self, bytes: []const u8, allocator: Allocator) !void {
        self.vectorized = try std.ArrayList(DBusType).initCapacity(allocator, bytes.len * 2);
        errdefer self.vectorized.deinit();
        var pos: usize = 0;

        while (pos < bytes.len) : (pos += 1) {
            try self.next(bytes, &pos);
        }

        if (self.vectorized.items.len == 0) {
            return SignatureError.EmptySignature;
        }
    }

    fn next(self: *Self, bytes: []const u8, pos: *usize) !void {
        const token: TypeSigToken = @enumFromInt(bytes[pos.*]);
        switch (token) {
            TypeSigToken.BYTE => try self.vectorized.append(DBusType{ .BYTE_TYPE = {} }),
            TypeSigToken.BOOLEAN => try self.vectorized.append(DBusType{ .BOOLEAN_TYPE = {} }),
            TypeSigToken.INT16 => try self.vectorized.append(DBusType{ .INT16_TYPE = {} }),
            TypeSigToken.UINT16 => try self.vectorized.append(DBusType{ .UINT16_TYPE = {} }),
            TypeSigToken.INT32 => try self.vectorized.append(DBusType{ .INT32_TYPE = {} }),
            TypeSigToken.UINT32 => try self.vectorized.append(DBusType{ .UINT32_TYPE = {} }),
            TypeSigToken.INT64 => try self.vectorized.append(DBusType{ .INT64_TYPE = {} }),
            TypeSigToken.UINT64 => try self.vectorized.append(DBusType{ .UINT64_TYPE = {} }),
            TypeSigToken.DOUBLE => try self.vectorized.append(DBusType{ .DOUBLE_TYPE = {} }),
            TypeSigToken.UNIX_FD => try self.vectorized.append(DBusType{ .UNIX_FD_TYPE = {} }),
            TypeSigToken.STRING => try self.vectorized.append(DBusType{ .STRING_TYPE = {} }),
            TypeSigToken.OBJECT_PATH => try self.vectorized.append(DBusType{ .OBJECT_PATH_TYPE = {} }),
            TypeSigToken.SIGNATURE => try self.vectorized.append(DBusType{ .SIGNATURE_TYPE = {} }),
            TypeSigToken.VARIANT => try self.vectorized.append(DBusType{ .VARIANT_TYPE = {} }),
            TypeSigToken.ARRAY => try self.vectorized.append(DBusType{ .ARRAY_TYPE = {} }),
            TypeSigToken.STRUCT_OPEN => {
                pos.* += 1;
                var struct_length: u8 = 0;
                try self.vectorized.append(DBusType{ .STRUCT_TYPE = {} });
                try self.vectorized.append(DBusType{ .STRUCT_LENGTH = 0 });
                const length_pos: usize = self.vectorized.items.len - 1;
                while (pos.* < bytes.len) : (pos.* += 1) {
                    const inner_token: TypeSigToken = @enumFromInt(bytes[pos.*]);
                    if (inner_token == TypeSigToken.STRUCT_CLOSE) {
                        pos.* += 1;
                        break;
                    }
                    try self.next(bytes, pos);
                    struct_length += 1;
                }
                self.vectorized.items[length_pos] = DBusType{ .STRUCT_LENGTH = struct_length };
            },
            TypeSigToken.STRUCT_CLOSE => unreachable, // Should be handled by STRUCT_OPEN
            TypeSigToken.DICT_OPEN => {
                pos.* += 1;
                var dict_entry_length: u8 = 0;
                try self.vectorized.append(DBusType{ .DICT_ENTRY_TYPE = {} });
                try self.vectorized.append(DBusType{ .DICT_ENTRY_LENGTH = 0 });
                const dict_entry_pos = self.vectorized.items.len - 1;
                while (pos.* < bytes.len) : (pos.* += 1) {
                    const inner_token: TypeSigToken = @enumFromInt(bytes[pos.*]);
                    if (inner_token == TypeSigToken.DICT_CLOSE) {
                        pos.* += 1;
                        break;
                    }
                    try self.next(bytes, pos);
                    dict_entry_length += 1;
                }
                self.vectorized.items[dict_entry_pos] = DBusType{ .DICT_ENTRY_LENGTH = dict_entry_length };
            },
            else => unreachable,
        }
    }
};

test "report an error on an empty signature string" {
    _ = Signature.make("", testing.allocator) catch |err| {
        try testing.expect(
            Signature.SignatureError.EmptySignature == err,
        );
    };
}

test "can parse a simple signature string" {
    var signature = try Signature.make("ybnqiuxtdhsogv", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .BOOLEAN_TYPE = {} },
            DBusType{ .INT16_TYPE = {} },
            DBusType{ .UINT16_TYPE = {} },
            DBusType{ .INT32_TYPE = {} },
            DBusType{ .UINT32_TYPE = {} },
            DBusType{ .INT64_TYPE = {} },
            DBusType{ .UINT64_TYPE = {} },
            DBusType{ .DOUBLE_TYPE = {} },
            DBusType{ .UNIX_FD_TYPE = {} },
            DBusType{ .STRING_TYPE = {} },
            DBusType{ .OBJECT_PATH_TYPE = {} },
            DBusType{ .SIGNATURE_TYPE = {} },
            DBusType{ .VARIANT_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse a struct in a signature" {
    var signature = try Signature.make("(y)", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 1 },
            DBusType{ .BYTE_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse a nested struct in a signature" {
    var signature = try Signature.make("(y(y))", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 2 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 1 },
            DBusType{ .BYTE_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse a struct with multiple types in a signature" {
    var signature = try Signature.make("(ybnqiuxtdhsogv)", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 14 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .BOOLEAN_TYPE = {} },
            DBusType{ .INT16_TYPE = {} },
            DBusType{ .UINT16_TYPE = {} },
            DBusType{ .INT32_TYPE = {} },
            DBusType{ .UINT32_TYPE = {} },
            DBusType{ .INT64_TYPE = {} },
            DBusType{ .UINT64_TYPE = {} },
            DBusType{ .DOUBLE_TYPE = {} },
            DBusType{ .UNIX_FD_TYPE = {} },
            DBusType{ .STRING_TYPE = {} },
            DBusType{ .OBJECT_PATH_TYPE = {} },
            DBusType{ .SIGNATURE_TYPE = {} },
            DBusType{ .VARIANT_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse a nested struct with multiple types in a signature" {
    var signature = try Signature.make("(y(ybnqiuxtdhsogv))", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 2 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 14 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .BOOLEAN_TYPE = {} },
            DBusType{ .INT16_TYPE = {} },
            DBusType{ .UINT16_TYPE = {} },
            DBusType{ .INT32_TYPE = {} },
            DBusType{ .UINT32_TYPE = {} },
            DBusType{ .INT64_TYPE = {} },
            DBusType{ .UINT64_TYPE = {} },
            DBusType{ .DOUBLE_TYPE = {} },
            DBusType{ .UNIX_FD_TYPE = {} },
            DBusType{ .STRING_TYPE = {} },
            DBusType{ .OBJECT_PATH_TYPE = {} },
            DBusType{ .SIGNATURE_TYPE = {} },
            DBusType{ .VARIANT_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse a nested nested struct with multiple types in a signature" {
    var signature = try Signature.make("(y(y(y(y))))", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 2 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 2 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 2 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 1 },
            DBusType{ .BYTE_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse an array in a signature" {
    var signature = try Signature.make("ay", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .ARRAY_TYPE = {} },
            DBusType{ .BYTE_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse an array of struct" {
    var signature = try Signature.make("a(y)", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .ARRAY_TYPE = {} },
            DBusType{ .STRUCT_TYPE = {} },
            DBusType{ .STRUCT_LENGTH = 1 },
            DBusType{ .BYTE_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse an array of array" {
    var signature = try Signature.make("aay", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .ARRAY_TYPE = {} },
            DBusType{ .ARRAY_TYPE = {} },
            DBusType{ .BYTE_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

test "can parse an array of dict entries" {
    var signature = try Signature.make("a{ys}", testing.allocator);
    defer signature.deinit();
    try testing.expectEqualSlices(
        DBusType,
        &.{
            DBusType{ .ARRAY_TYPE = {} },
            DBusType{ .DICT_ENTRY_TYPE = {} },
            DBusType{ .DICT_ENTRY_LENGTH = 2 },
            DBusType{ .BYTE_TYPE = {} },
            DBusType{ .STRING_TYPE = {} },
        },
        signature.vectorized.items,
    );
}

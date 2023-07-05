///! This module implements the D-Bus type system.
const std = @import("std");
const Endian = std.builtin.Endian;

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
pub const DBusTypeTag = enum {
    BYTE,
    BOOLEAN,
    INT16,
    UINT16,
    INT32,
    UINT32,
    INT64,
    UINT64,
    DOUBLE,
    UNIX_FD,

    STRING,
    OBJECT_PATH,
    SIGNATURE,

    VARIANT,
    STRUCT,
    ARRAY,
    DICT_ENTRY,
};

/// Represents a type instance in DBus type system
pub const DBusType = union(DBusTypeTag) {
    BYTE: void,
    BOOLEAN: void,
    INT16: void,
    UINT16: void,
    INT32: void,
    UINT32: void,
    INT64: void,
    UINT64: void,
    DOUBLE: void,
    UNIX_FD: void,

    STRING: void,
    OBJECT_PATH: void,
    SIGNATURE: void,

    VARIANT: void,
    STRUCT: struct { inner: []DBusType },
    ARRAY: struct { inner: []DBusType },
    DICT_ENTRY: struct { key: DBusType, value: DBusType },

    pub fn alignment(comptime T: DBusType) comptime_int {
        return switch (T) {
            .BYTE => 1,
            .BOOLEAN => 4,
            .INT16 => 2,
            .UINT16 => 2,
            .INT32 => 4,
            .UINT32 => 4,
            .INT64 => 8,
            .UINT64 => 8,
            .DOUBLE => 8,
            .UNIX_FD => 4,

            // For string-like types, it returns the alignment for the length value
            .STRING => 4,
            .OBJECT_PATH => 4,
            .SIGNATURE => 1, // The length of a signature does not exceed 255

            .VARIANT => 1,
            .ARRAY => 4,
            .STRUCT => 8,
            .DICT_ENTRY => 8,
        };
    }

    pub fn alignment_type(comptime T: DBusType) type {
        return switch (T) {
            .STRING => u32,
            .OBJECT_PATH => u32,
            .SIGNATURE => u8,

            .VARIANT => u8,
            .ARRAY => u32,
            .STRUCT => u64,
            .DICT_ENTRY => u64,
            else => unreachable,
        };
    }

    pub fn nativeType(comptime T: DBusType) type {
        return switch (T) {
            .BYTE => u8,
            .BOOLEAN => bool,
            .INT16 => i16,
            .UINT16 => u16,
            .INT32 => i32,
            .UINT32 => u32,
            .INT64 => i64,
            .UINT64 => u64,
            .DOUBLE => f64,
            .UNIX_FD => i32,

            .STRING => []const u8,
            .OBJECT_PATH => []const u8,
            .SIGNATURE => []const u8,

            // Container types has no correspnding native types
            else => unreachable,
        };
    }
};

pub const DBusValue = union(DBusType) {
    BYTE: u8,
    BOOLEAN: bool,
    INT16: i16,
    UINT16: u16,
    INT32: i32,
    UINT32: u32,
    INT64: i64,
    UINT64: u64,
    DOUBLE: f64,
    UNIX_FD: i32,

    STRING: []const u8,
    OBJECT_PATH: []const u8,
    SIGNATURE: []const u8,

    VARIANT: DBusValue,
    STRUCT: struct { inner: []DBusValue },
    ARRAY: struct { inner: []DBusValue },
    DICT_ENTRY: struct { key: DBusValue, value: DBusValue },
};

// The simplest type codes are the basic types, which are the types whose structure is entirely defined by their 1-character type code.
// Basic types consist of fixed types and string-like types.

// Token for parsing signature
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

    STRUCT_R = 'r',
    STRUCT_OPEN = '(',
    STRUCT_CLOSE = ')',
    ARRAY = 'a',
    DICT_E = 'e',
    DICT_OPEN = '{',
    DICT_CLOSE = '}',
};

pub const SignatureReader = struct {
    signature: []const u8,
    len: u32 = 0,
    pos: u32 = 0,

    const Self = @This();

    pub fn init(bytes: []const u8) !Self {
        // The length of signature is stored in the first byte,
        // and the length is limited to 255.
        const len = std.mem.readInt(u8, bytes[0..1], Endian.Little);

        return Self{
            .signature = bytes[1..],
            .len = len,
        };
    }

    pub fn next(self: *Self) !DBusType {
        if (self.pos >= self.len) {
            return error.Unreachable;
        }
        const dbus_type = self.signature[self.pos];
        self.pos += 1;
        return dbus_type;
    }
};

test "sigature reader can read a signature from a byte array" {
    const bytes = [_]u8{11} ++ "yyyyuua(uv)";
    var reader = try SignatureReader.init(bytes);
    _ = reader;
    const expected = [_]DBusType{
        DBusType.BYTE,
        DBusType.BYTE,
        DBusType.BYTE,
        DBusType.BYTE,
        DBusType.UINT32,
        DBusType.UINT32,
        DBusType{
            .ARRAY = .{
                .inner = DBusType{
                    .STRUCT = .{
                        .inner = []DBusType{
                            DBusType.UINT32,
                            DBusType.VARIANT,
                        },
                    },
                },
            },
        },
    };

    var output: DBusType = try reader.next();
    while (output != null) : (output = try reader.next()) {
        const expected_type = expected[reader.pos - 1];
        expect(output == expected_type);
    }
}

pub fn read_byte(bytes: []const u8) .{ u8, []const u8 } {
    return .{ bytes[0], bytes[1..] };
}

/// Represents a single complete type.
pub const SingleCompleteType = struct {
    signature: []const u8, // The type signature represent this dbus type

    const Self = @This();

    pub fn eql(this: *Self, other: *Self) bool {
        return std.mem.eql(this.signature, other.signature);
    }

    // Given a type signature, a block of bytes can be converted into typed values.
    // Byte order and alignment issues are handled uniformly for all D-Bus types.
    // Each value in a block of bytes is aligned "naturally," for example 4-byte values are aligned to a 4-byte boundary, and 8-byte values to an 8-byte boundary.
    // As an exception to natural alignment, STRUCT and DICT_ENTRY values are always aligned to an 8-byte boundary, regardless of the alignments of their contents.
    pub fn marshall(this: *Self, message: []const u8) []const u8 {
        _ = this;
        return message;
    }
};

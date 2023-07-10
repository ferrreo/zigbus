//! A DBus message consists of a header and a body.
//! The signature of the header is fixed: yyyyuua(yv)
//! The signature of the body is specified in the header field `Signature`.
//!
//! To read a message, we need to read bytes with respect to DBus type system.

const std = @import("std");
const testing = std.testing;
const typesys = @import("typesys.zig");
const Signature = typesys.Signature;
const BytesReader = @import("bytes.zig").BytesReader;
const DBusType = typesys.DBusType;
const Endian = std.builtin.Endian;
const Allocator = std.mem.Allocator;

const header_sig_string = "yyyyuua(yv)";

const MessageDecoder = struct {
    bytesReader: BytesReader,

    // These fields are initialized reading the header
    // when `init` is called.
    msg_type: MsgType,
    header_flags: HeaderFlags,
    major_version: u8,
    body_length: u32,
    serial: u32,
    header_fields: std.ArrayList(HeaderField),

    allocator: *std.mem.Allocator = undefined,

    const Self = @This();

    const MessageReaderError = error{
        InvalidEndian,
        InvalidMsgType,
        InvalidHeaderFlags,
        InvalidVersion,
        InvalidBodyLength,
        InvalidSerial,
        InvalidHeaderFieldCode,
        InvalidHeaderField,
    };

    pub fn init(bytes: []const u8, allocator: *std.mem.Allocator) !Self {
        var reader = BytesReader{ .bytes = &bytes };

        // The signature of a header is fixed to yyyyuua(yv)

        const endian: u8 = try reader.next(u8);

        // 1. Read the first byte, which is the endianess flag.
        reader.endian = try switch (endian) {
            'l' => Endian.Little,
            'B' => Endian.Big,
            else => MessageReaderError.InvalidEndian,
        };

        // 2. Read the second byte, which is the message type.
        const msg_type_byte = try reader.next(u8);
        const msg_type = try switch (msg_type_byte) {
            MsgType.Invalid => MessageReaderError.InvalidMsgType,
            MsgType.MethodCall => MsgType.MethodCall,
            MsgType.MethodReturn => MsgType.MethodReturn,
            MsgType.Error => MsgType.Error,
            MsgType.Signal => MsgType.Signal,
            else => MessageReaderError.InvalidMsgType,
        };

        // 3. Read the third byte, which is the header flags.
        const header_flags_bits = try reader.next(u8);
        const header_flags = HeaderFlags{
            .no_reply_expected = (header_flags_bits & 0x1) == 1,
            .no_auto_start = (header_flags_bits & 0x2) == 1,
            .allow_interactive_authorization = (header_flags_bits & 0x4) == 1,
        };

        // 4. Read the fourth byte, which is the protocol version.
        const major_version: u8 = try reader.next(u8);
        if (major_version != 1) {
            return MessageReaderError.InvalidVersion;
        }

        // 5. Read the next four bytes, which are the body length.
        const body_length: u32 = try reader.next(u32);

        // 6. Read the next four bytes, which are the serial number.
        const serial: u32 = try reader.next(u32);

        // 7. Read the header fields (array of structs of field-code(byte) and variant)
        var header_fields = std.ArrayList(HeaderField).init(allocator);

        // it returns the length of the array in bytes
        const array_length = try reader.next(u32);
        const array_start: usize = reader.pos;

        while (reader.pos - array_start < array_length) {
            try reader.alignBy(8); // struct is aligned by 8 bytes
            const field_code = try reader.next(u8);
            switch (field_code) {
                HeaderFieldCode.Invalid => return MessageReaderError.InvalidHeaderFieldCode,

                // This variant is expected to be OBJECT_PATH
                HeaderFieldCode.Path => {
                    const sig_str = try reader.nextSignature();
                    const signature = try Signature.make(sig_str, allocator);
                    defer signature.deinit();
                    if (signature.vectorized.items[0] != DBusType.OBJECT_PATH_TYPE) {
                        return MessageReaderError.InvalidHeaderField;
                    }
                    const path = try reader.nextString();
                    try header_fields.append(HeaderField.Path{ .path = path });
                },
                HeaderFieldCode.Interface => {
                    const sig_str = try reader.nextSignature();
                    const signature = try Signature.make(sig_str, allocator);
                    defer signature.deinit();
                    if (signature.vectorized.items[0] != DBusType.STRING_TYPE) {
                        return MessageReaderError.InvalidHeaderField;
                    }
                    const interface = try reader.nextString();
                    try header_fields.append(HeaderField.Interface{ .interface = interface });
                },
                else => {
                    // If an implementation sees a header field code that it does not expect,
                    // it must accept and ignore that field,
                    // as it will be part of a new (but compatible) version of this specification.
                },
            }
        }

        const msgReader = MessageDecoder{
            .bytesReader = BytesReader{
                .bytes = reader.bytes,
                .endian = reader.endian,
            },
            .msg_type = msg_type,
            .header_flags = header_flags,
            .major_version = major_version,
            .body_length = body_length,
            .serial = serial,
            .header_fields = header_fields,
            .allocator = allocator,
        };

        return msgReader;
    }

    pub fn deinit(self: *Self) void {
        self.header_fields.deinit();
    }
};

const MsgType = enum(u8) {
    Invalid = 0,
    MethodCall = 1,
    MethodReturn = 2,
    Error = 3,
    Signal = 4,
};

const HeaderFlags = packed struct {
    no_reply_expected: u1 = 0,
    no_auto_start: u1 = 0,
    allow_interactive_authorization: u1 = 0,

    _padding: u5 = 0,
};

const HeaderFieldCode = enum(u8) {
    Invalid = 0,
    Path = 1,
    Interface = 2,
    Member = 3,
    ErrorName = 4,
    ReplySerial = 5,
    Destination = 6,
    Sender = 7,
    Signature = 8,
    UnixFds = 9,
};

const HeaderField = union(HeaderFieldCode) {
    Invalid: struct {},
    Path: struct { path: []const u8 },
    Interface: struct { interface: []const u8 },
};

test "can decode a message header" {
    const allocator = testing.allocator;

    const bytes: []const u8 = &[_]u8{
        'l', // Endian
        1, // MsgType
        0, // HeaderFlags
        1, // MajorVersion
        0, 0, 0, 0, // BodyLength
        0, 0, 0, 0, // Serial
        0, 0, 0, 0, // HeaderFields length
    };

    const msgReader = try MessageDecoder.init(bytes, allocator);
    defer msgReader.deinit();

    try testing.expectEqual(MsgType.MethodCall, msgReader.msg_type);
    try testing.expectEqual(HeaderFlags{ .no_reply_expected = false, .no_auto_start = false, .allow_interactive_authorization = false }, msgReader.header_flags);
    // assert(msgReader.header_flags.no_reply_expected == false);
    // assert(msgReader.header_flags.no_auto_start == false);
    // assert(msgReader.header_flags.allow_interactive_authorization == false);
    // assert(msgReader.major_version == 1);
    // assert(msgReader.body_length == 0);
    // assert(msgReader.serial == 0);
    // assert(msgReader.header_fields.len == 0);
}

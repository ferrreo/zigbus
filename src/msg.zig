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

const HeaderReader = struct {
    // byte slice with header and body included.
    // the header is always located the beginning of the slice.
    signature: Signature = undefined,
    allocator: Allocator,

    const Self = @This();

    pub fn init(self: *Self) !void {
        self.signature = try Signature.make(header_sig_string, self.allocator);
    }

    pub fn read_header(self: *Self, bytes: []const u8) !MessageHeader {
        _ = bytes;
        var sig_pos: usize = 0;
        const sig_types = self.signature.vectorized.items;

        while (sig_pos < sig_types.len) : (sig_pos += 1) {
            const sig_type = sig_types[sig_pos];
            switch (sig_type) {
                DBusType.BYTE_TYPE => |_| {},
            }
        }
    }
};

test "can read a simple header" {
    var header_reader = HeaderReader{ .allocator = testing.allocator };
    try header_reader.init();
    header_reader.read_header([_]u8{
        'B', // endian
        0x01, // msg_type
        0x00, // header_flags
        0x01, // major_version
        0x00, 0x00, 0x00, 0x00, // body_length
        0x00, 0x00, 0x00, 0x00, // serial
        0x00, 0x00, 0x00, 0x00, // header_fields
    });
}

const MessageHeader = struct {
    endian: Endian,
    msg_type: MsgType,
    header_flags: HeaderFlags,
    major_version: u8,
    body_length: u32,
    serial: u32,
    body: []const u8,
    header_fields: std.ArrayList(HeaderField),
};

const MessageReader = struct {
    bytesReader: BytesReader,
    bodySignature: []const u8 = undefined,

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
        var reader = BytesReader{
            .bytes = &bytes,
            .endian = Endian.Big,
        };

        // The signature of a header is fixed to yyyyuua(yv)
        const endian: u8 = (try reader.next(DBusType.BYTE)) orelse return MessageReaderError.InvalidEndian;

        // 1. Read the first byte, which is the endianess flag.
        reader.endian = try switch (endian) {
            'l' => Endian.Little,
            'B' => Endian.Big,
            else => MessageReaderError.InvalidEndian,
        };

        // 2. Read the second byte, which is the message type.
        const msg_type_byte = (try reader.next(DBusType.BYTE)) orelse return MessageReaderError.InvalidMsgType;
        const msg_type = try switch (msg_type_byte) {
            .Invalid => MessageReaderError.InvalidMsgType,
            .MethodCall => MsgType.MethodCall,
            .MethodReturn => MsgType.MethodReturn,
            .Error => MsgType.Error,
            .Signal => MsgType.Signal,
            else => MessageReaderError.InvalidMsgType,
        };

        // 3. Read the third byte, which is the header flags.
        const header_flags_bits = (try reader.next(DBusType.BYTE)) orelse return MessageReaderError.InvalidHeaderFlags;
        const header_flags = HeaderFlags{
            .no_reply_expected = (header_flags_bits & 0x1) == 1,
            .no_auto_start = (header_flags_bits & 0x2) == 1,
            .allow_interactive_authorization = (header_flags_bits & 0x4) == 1,
        };

        // 4. Read the fourth byte, which is the protocol version.
        const major_version: u8 = (try reader.next(DBusType.BYTE)) orelse return MessageReaderError.InvalidVersion;
        if (major_version != 1) {
            return MessageReaderError.InvalidVersion;
        }

        // 5. Read the next four bytes, which are the body length.
        const body_length: u32 = (try reader.next(DBusType.UINT32)) orelse return MessageReaderError.InvalidBodyLength;

        // 6. Read the next four bytes, which are the serial number.
        const serial: u32 = (try reader.next(DBusType.UINT32)) orelse return MessageReaderError.InvalidSerial;

        // 7. Read the header fields (array of structs of field-code(byte) and variant)
        var header_fields = std.ArrayList(HeaderField).init(allocator);

        // it returns the length of the array in bytes
        const array_length = try reader.next(DBusType.ARRAY) orelse return MessageReaderError.InvalidHeaderFieldLength;
        _ = array_length;

        try reader.next(DBusType.STRUCT) orelse return MessageReaderError.InvalidHeaderFieldStruct;

        const code = (try reader.next(DBusType.BYTE)) orelse return MessageReaderError.InvalidHeaderFieldCode;
        switch (code) {
            HeaderFieldCode.Invalid => return MessageReaderError.InvalidHeaderFieldCode,

            // Required in a method call, and a signal
            HeaderFieldCode.Path => {
                const path = try reader.next(DBusType.STRING);
                if (path == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.Path{ .path = path });
            },

            // Required in a sigal
            HeaderFieldCode.Interface => {
                const interface = try reader.next(DBusType.STRING);
                if (interface == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.Interface{ .interface = interface });
            },

            // Required in a method call, and a signal
            HeaderFieldCode.Member => {
                const member = try reader.next(DBusType.STRING);
                if (member == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.Member{ .member = member });
            },

            // Required in an error
            HeaderFieldCode.ErrorName => {
                const error_name = try reader.next(DBusType.STRING);
                if (error_name == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.ErrorName{ .error_name = error_name });
            },

            // Required in an error, and method return
            HeaderFieldCode.ReplySerial => {
                const reply_serial = try reader.next(DBusType.UINT32);
                if (reply_serial == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.ReplySerial{ .reply_serial = reply_serial });
            },

            HeaderFieldCode.Destination => {
                const destination = try reader.next(DBusType.STRING);
                if (destination == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.Destination{ .destination = destination });
            },

            HeaderFieldCode.Sender => {
                const sender = try reader.next(DBusType.STRING);
                if (sender == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.Sender{ .sender = sender });
            },

            HeaderFieldCode.Signature => {
                const signature = try reader.next(DBusType.SIGNATURE);
                if (signature == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.Signature{ .signature = signature });
            },

            HeaderFieldCode.UnixFds => {
                const unix_fds = try reader.next(DBusType.UINT32);
                if (unix_fds == null) {
                    return MessageReaderError.InvalidHeaderField;
                }
                try Self.header_fields.append(HeaderField.UnixFds{ .unix_fds = unix_fds });
            },
        }

        const msgReader = MessageReader{
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
    Path: struct {
        path: []const u8,
    },
};

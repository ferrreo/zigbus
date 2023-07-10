# Zigbus

`Zigbus` is a D-Bus implemented in [zig](https://ziglang.org/).

For specification, see https://dbus.freedesktop.org/doc/dbus-specification.html.

Zig version: 0.11.0-dev.3936+8ae92fd17

# Progress

WIP: Type System, Serialization/Deserialization, Message Format

# Wire Format (Marshalling)

## What does it mean by Alignment?

By alignment, D-Bus Wire Format specifies the start position of a data in a byte stream(or, a message).
For example, since `INT16` has an alignment of 2, `INT16` data must start at `2n`.
Also, since `INT64` has an alignment of 8, a data of the type must start at `8n`.

Let's take an example.
If two numbers of `INT16` and `INT64` lie in a message, respectively, in little endian,
the message must be shaped as:

```
0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
0x02 0x00 0x00 0x00 0x00 0x00 0x00 0x00
```

The first two bytes are the bytes of `INT16` number, which represents 1.
And, the next six bytes are padding to meet the alignment of the next `INT64` number.
Finally, the next 8 bytes are bytes of the `INT64` number, which represents 2.

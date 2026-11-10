#!/usr/bin/env python3
"""Differential and corrupted-input tests of generated SPARK code.

Python protobuf is the reference. For random messages within the bounds of
the options files, and for variants of their encodings (fields reordered,
unknown fields added, packed fields sent unpacked, stale earlier copies of
fields), the round trip program of run_all.sh decodes and encodes again,
and the result must match what Python decodes from the same bytes, without
unknown and ignored fields. Then valid encodings are corrupted at random:
the program must not crash, must decode to the same values as Python when
both accept the input, and must only reject what Python accepts for a
documented reason (bounds, the reject policy for proto3 enums, UTF-8 checks
of proto2 strings).

Usage: differential.py DESCRIPTOR_SET OPTIONS_DIR MESSAGE ROUNDTRIP WORKDIR
                       [--count N] [--seed S]

DESCRIPTOR_SET is written by protoc --descriptor_set_out --include_imports,
OPTIONS_DIR holds <name>.options for each <name>.proto, MESSAGE is the full
protobuf name of the message ROUNDTRIP reads and writes.
"""

import argparse
import os
import random
import re
import struct
import subprocess
import sys

from google.protobuf import descriptor_pb2
from google.protobuf import descriptor_pool
from google.protobuf import message_factory
from google.protobuf.descriptor import FieldDescriptor as FD

STATUSES = {"TRUNCATED", "MALFORMED", "LIMIT_EXCEEDED", "INVALID_UTF8",
            "MISSING_REQUIRED", "UNKNOWN_ENUM"}
MAX_DEPTH = 3

# Wire types
VARINT, FIXED64, DELIMITED, START_GROUP, END_GROUP, FIXED32 = range(6)

VARINT_TYPES = {FD.TYPE_INT32, FD.TYPE_INT64, FD.TYPE_UINT32, FD.TYPE_UINT64,
                FD.TYPE_SINT32, FD.TYPE_SINT64, FD.TYPE_BOOL, FD.TYPE_ENUM}
FIXED32_TYPES = {FD.TYPE_FIXED32, FD.TYPE_SFIXED32, FD.TYPE_FLOAT}
FIXED64_TYPES = {FD.TYPE_FIXED64, FD.TYPE_SFIXED64, FD.TYPE_DOUBLE}


# ---------------------------------------------------------------- options

def pattern_regex(pattern):
    """'*' is any sequence (including '.'), '?' one character."""
    parts = []
    for c in pattern:
        parts.append(".*" if c == "*" else "." if c == "?" else re.escape(c))
    return re.compile("".join(parts) + r"\Z")


def read_rules(path):
    rules = []
    if not os.path.exists(path):
        return rules
    with open(path, encoding="utf-8") as f:
        for line in f:
            tokens = []
            for t in line.split():
                if t.startswith("#") or t.startswith("//"):
                    break
                tokens.append(t)
            if not tokens:
                continue
            values = {}
            for t in tokens[1:]:
                key, _, value = t.partition(":")
                values[key] = value
            rules.append((pattern_regex(tokens[0]), values))
    return rules


class Bounds:
    """Options of fields, matched as Compiler.Options does."""

    def __init__(self, options_dir):
        self.dir = options_dir
        self.files = {}

    def options(self, field):
        name = field.file.name
        if name not in self.files:
            base = os.path.splitext(os.path.basename(name))[0]
            self.files[name] = read_rules(
                os.path.join(self.dir, base + ".options"))
        full = field.full_name
        package = field.file.package
        short = full[len(package) + 1:] if package else full
        result = {}
        for regex, values in self.files[name]:
            if regex.match(full) or regex.match(short) or regex.match(name):
                result.update(values)
        return result

    def ignored(self, field):
        return self.options(field).get("type") == "ignore"

    def capacity(self, field):
        o = self.options(field)
        if field.type == FD.TYPE_STRING:
            if "max_length" in o:
                return int(o["max_length"])
            if "max_size" in o:
                return int(o["max_size"]) - 1
        elif "max_size" in o:
            return int(o["max_size"])
        return None

    def count(self, field):
        o = self.options(field)
        return int(o["max_count"]) if "max_count" in o else None

    def first_policy(self, field):
        return self.options(field).get("on_unknown_enum") == "first"


# ------------------------------------------------------------- schema info

def is_repeated(field):
    r = getattr(field, "is_repeated", None)
    return r if r is not None else field.label == FD.LABEL_REPEATED


def is_required(field):
    r = getattr(field, "is_required", None)
    return r if r is not None else field.label == FD.LABEL_REQUIRED


def is_map(field):
    return (field.type == FD.TYPE_MESSAGE
            and field.message_type.GetOptions().map_entry)


class Schema:
    def __init__(self, descriptor_set):
        fds = descriptor_pb2.FileDescriptorSet()
        with open(descriptor_set, "rb") as f:
            fds.ParseFromString(f.read())
        self.pool = descriptor_pool.DescriptorPool()
        self.syntax = {}
        for file_proto in fds.file:
            self.pool.Add(file_proto)
            self.syntax[file_proto.name] = file_proto.syntax or "proto2"

    def proto3(self, descriptor):
        return self.syntax.get(descriptor.file.name) == "proto3"

    def message_class(self, name):
        desc = self.pool.FindMessageTypeByName(name)
        if hasattr(message_factory, "GetMessageClass"):
            return message_factory.GetMessageClass(desc)
        return message_factory.MessageFactory(self.pool).GetPrototype(desc)


# ------------------------------------------------------- random messages

def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def random_scalar(rnd, field):
    t = field.type
    if t in (FD.TYPE_INT32, FD.TYPE_SINT32, FD.TYPE_SFIXED32):
        return rnd.choice([0, 1, -1, 2**31 - 1, -2**31,
                           rnd.randint(-2**31, 2**31 - 1)])
    if t in (FD.TYPE_INT64, FD.TYPE_SINT64, FD.TYPE_SFIXED64):
        return rnd.choice([0, 1, -1, 2**63 - 1, -2**63,
                           rnd.randint(-2**63, 2**63 - 1)])
    if t in (FD.TYPE_UINT32, FD.TYPE_FIXED32):
        return rnd.choice([0, 1, 2**32 - 1, rnd.randint(0, 2**32 - 1)])
    if t in (FD.TYPE_UINT64, FD.TYPE_FIXED64):
        return rnd.choice([0, 1, 2**64 - 1, rnd.randint(0, 2**64 - 1)])
    if t == FD.TYPE_BOOL:
        return rnd.choice([False, True])
    if t in (FD.TYPE_FLOAT, FD.TYPE_DOUBLE):
        x = rnd.choice([0.0, -0.0, 1.5, -2.25, float("inf"), float("-inf"),
                        float("nan"), rnd.uniform(-1e30, 1e30),
                        rnd.uniform(-1, 1)])
        return f32(x) if t == FD.TYPE_FLOAT else x
    if t == FD.TYPE_ENUM:
        return rnd.choice(field.enum_type.values).number
    raise ValueError(t)


def random_text(rnd, field, cap):
    limit = 12 if cap is None else cap
    n = rnd.randint(0, limit)
    if field.type == FD.TYPE_BYTES:
        return bytes(rnd.randrange(256) for _ in range(n))
    chars = "ab Z0~" + "é€\U0001F600"
    out, size = [], 0
    while True:
        c = rnd.choice(chars)
        s = len(c.encode("utf-8"))
        if size + s > n:
            return "".join(out)
        out.append(c)
        size += s


class Generator:
    def __init__(self, schema, bounds, rnd):
        self.schema, self.bounds, self.rnd = schema, bounds, rnd

    def value(self, field, depth):
        if field.type == FD.TYPE_MESSAGE:
            return None  # filled in place
        if field.type in (FD.TYPE_STRING, FD.TYPE_BYTES):
            return random_text(self.rnd, field, self.bounds.capacity(field))
        return random_scalar(self.rnd, field)

    def fill(self, msg, depth=0):
        rnd = self.rnd
        chosen = {}
        for oneof in msg.DESCRIPTOR.oneofs:
            members = [f for f in oneof.fields if not self.bounds.ignored(f)]
            # A proto3 optional field is a synthetic oneof of its own
            if members and rnd.random() < 0.8:
                chosen[oneof.name] = rnd.choice(members)
            else:
                chosen[oneof.name] = None
        for field in msg.DESCRIPTOR.fields:
            if self.bounds.ignored(field):
                continue
            if field.containing_oneof is not None:
                if chosen[field.containing_oneof.name] is not field:
                    continue
            elif not is_required(field) and not is_repeated(field) \
                    and field.has_presence and rnd.random() < 0.3:
                continue
            if field.type == FD.TYPE_MESSAGE and depth >= MAX_DEPTH \
                    and not is_required(field):
                continue
            if is_map(field):
                self.fill_map(msg, field, depth)
            elif is_repeated(field):
                limit = self.bounds.count(field)
                n = rnd.randint(0, 3 if limit is None else limit)
                container = getattr(msg, field.name)
                for _ in range(n):
                    if field.type == FD.TYPE_MESSAGE:
                        self.fill(container.add(), depth + 1)
                    else:
                        container.append(self.value(field, depth))
            elif field.type == FD.TYPE_MESSAGE:
                sub = getattr(msg, field.name)
                sub.SetInParent()
                self.fill(sub, depth + 1)
            else:
                setattr(msg, field.name, self.value(field, depth))

    def fill_map(self, msg, field, depth):
        key_f = field.message_type.fields_by_name["key"]
        value_f = field.message_type.fields_by_name["value"]
        limit = self.bounds.count(field)
        n = self.rnd.randint(0, 3 if limit is None else limit)
        container = getattr(msg, field.name)
        for _ in range(n):
            key = self.value(key_f, depth)
            if value_f.type == FD.TYPE_MESSAGE:
                self.fill(container[key], depth + 1)
            else:
                container[key] = self.value(value_f, depth)


# ------------------------------------------------------------ wire level

def get_varint(data, pos):
    result, shift = 0, 0
    while True:
        if pos >= len(data) or shift > 63:
            raise ValueError("bad varint")
        b = data[pos]
        pos += 1
        result |= (b & 127) << shift
        shift += 7
        if b < 128:
            return result, pos


def put_varint(value):
    out = bytearray()
    while True:
        b = value & 127
        value >>= 7
        if value:
            out.append(b | 128)
        else:
            out.append(b)
            return bytes(out)


def chunks(data):
    """Split a valid encoding into (number, wire type, bytes, payload)."""
    result, pos = [], 0
    while pos < len(data):
        start = pos
        key, pos = get_varint(data, pos)
        number, wire = key >> 3, key & 7
        if wire == VARINT:
            _, pos = get_varint(data, pos)
            payload = None
        elif wire == FIXED64:
            pos += 8
            payload = None
        elif wire == FIXED32:
            pos += 4
            payload = None
        elif wire == DELIMITED:
            length, pos = get_varint(data, pos)
            payload = data[pos:pos + length]
            pos += length
        else:
            raise ValueError("group in generated input")
        result.append((number, wire, data[start:pos], payload))
    return result


def unpack(field, payload):
    """Encode the values of a packed payload one by one, with tags."""
    out, pos = bytearray(), 0
    if field.type in VARINT_TYPES:
        tag, size = put_varint(field.number << 3 | VARINT), None
    elif field.type in FIXED32_TYPES:
        tag, size = put_varint(field.number << 3 | FIXED32), 4
    else:
        tag, size = put_varint(field.number << 3 | FIXED64), 8
    while pos < len(payload):
        start = pos
        if size is None:
            _, pos = get_varint(payload, pos)
        else:
            pos += size
        out += tag + payload[start:pos]
    return bytes(out)


def random_unknown(rnd, used):
    number = rnd.choice([n for n in (rnd.randint(1, 2**29 - 1),
                                     rnd.randint(1, 200), 19999)
                         if n not in used] or [2**29 - 1])
    kind = rnd.randrange(5)
    if kind == 0:
        return put_varint(number << 3) + put_varint(rnd.randrange(2**64))
    if kind == 1:
        return put_varint(number << 3 | FIXED64) + os.urandom(8)
    if kind == 2:
        return put_varint(number << 3 | FIXED32) + os.urandom(4)
    if kind == 3:
        body = os.urandom(rnd.randint(0, 6))
        return put_varint(number << 3 | DELIMITED) + put_varint(len(body)) \
            + body
    inner = put_varint(5 << 3) + put_varint(7)
    return put_varint(number << 3 | START_GROUP) + inner \
        + put_varint(number << 3 | END_GROUP)


def variant(rnd, msg, extra):
    """Another encoding of msg, which Python decodes as the reference."""
    desc = msg.DESCRIPTOR
    data = msg.SerializeToString()
    parts = chunks(data)
    used = {f.number for f in desc.fields}
    by_number = desc.fields_by_number
    out = []
    for number, wire, raw, payload in parts:
        field = by_number.get(number)
        if field is not None and wire == DELIMITED and is_repeated(field) \
                and field.type not in (FD.TYPE_STRING, FD.TYPE_BYTES,
                                       FD.TYPE_MESSAGE) \
                and rnd.random() < 0.5:
            raw = unpack(field, payload)
        out.append((group_key(field, number), raw))
    # Stale earlier copies: chunks of another message go first. Repeated
    # fields then get more elements, which may exceed their bounds.
    if rnd.random() < 0.3:
        stale = [(group_key(by_number.get(n), n), raw)
                 for n, _, raw, _ in chunks(extra.SerializeToString())
                 if by_number.get(n) is not None
                 and not is_repeated(by_number[n])]
        out = stale + out
    # Reorder, keeping the order within each field and each oneof
    if rnd.random() < 0.7:
        groups = {}
        for key, raw in out:
            groups.setdefault(key, []).append(raw)
        keys = [k for k, _ in out]
        rnd.shuffle(keys)
        result = []
        for k in keys:
            result.append(groups[k].pop(0))
    else:
        result = [raw for _, raw in out]
    for _ in range(rnd.choice([0, 0, 1, 3])):
        result.insert(rnd.randint(0, len(result)), random_unknown(rnd, used))
    return b"".join(result)


def group_key(field, number):
    if field is not None and field.containing_oneof is not None:
        return "oneof " + field.containing_oneof.full_name
    return number


def corrupt(rnd, data):
    data = bytearray(data)
    for _ in range(rnd.choice([1, 1, 2, 3])):
        kind = rnd.randrange(6)
        if kind == 0 and data:
            j = rnd.randrange(len(data))
            data[j] ^= 1 << rnd.randrange(8)
        elif kind == 1 and data:
            data[rnd.randrange(len(data))] = rnd.choice(
                [0, 0x7F, 0x80, 0xFF, rnd.randrange(256)])
        elif kind == 2 and data:
            del data[rnd.randrange(len(data)):]
        elif kind == 3:
            j = rnd.randint(0, len(data))
            data[j:j] = bytes(rnd.choice([0x80, 0xFF, 0x01, 0x0A])
                              for _ in range(rnd.randint(1, 4)))
        elif kind == 4 and data:
            j = rnd.randrange(len(data))
            del data[j:j + rnd.randint(1, 4)]
        elif data:
            j = rnd.randrange(len(data))
            data[j:j] = data[j:j + rnd.randint(1, 8)]
    return bytes(data)


# ------------------------------------------------------------- reference

def normalize(msg, bounds):
    """Drop unknown and ignored fields, the way the SPARK code reads it."""
    msg.DiscardUnknownFields()
    for field in msg.DESCRIPTOR.fields:
        if bounds.ignored(field):
            msg.ClearField(field.name)
        elif field.type == FD.TYPE_MESSAGE:
            if is_map(field):
                if field.message_type.fields_by_name["value"].type \
                        == FD.TYPE_MESSAGE:
                    for v in getattr(msg, field.name).values():
                        normalize(v, bounds)
            elif is_repeated(field):
                for v in getattr(msg, field.name):
                    normalize(v, bounds)
            elif msg.HasField(field.name):
                normalize(getattr(msg, field.name), bounds)


class Malformed(Exception):
    pass


class Facts:
    """What a strict reading of the wire format finds in an input: the
    reasons the SPARK code has to reject it. Python's parser is lenient in
    places (it stops at a tag of field number 0, for example), and it keeps
    only the last of repeated occurrences, while the SPARK code checks every
    occurrence against the bounds and the enum policy."""

    def __init__(self):
        self.malformed = False
        self.over = False
        self.unknown_enum = False
        self.first_unknown = False
        self.bad_utf8 = False
        self.entry_unknown = False
        self.duplicate_key = False


def strict_varint(data, pos, end):
    result = 0
    for j in range(10):
        if pos >= end:
            raise Malformed("truncated varint")
        b = data[pos]
        pos += 1
        result |= (b & 127) << (7 * j)
        if b < 128:
            return result & (2**64 - 1), pos
    raise Malformed("varint over 10 bytes")


def strict_key(data, pos, end):
    start = pos
    key, pos = strict_varint(data, pos, end)
    number, wire = key >> 3, key & 7
    if pos - start > 5 or not 1 <= number <= 2**29 - 1 or wire > 5:
        raise Malformed("bad key")
    return number, wire, pos


def skip_value(data, pos, end, number, wire, depth=0):
    if wire == VARINT:
        _, pos = strict_varint(data, pos, end)
    elif wire == FIXED64:
        pos += 8
    elif wire == FIXED32:
        pos += 4
    elif wire == DELIMITED:
        length, pos = strict_varint(data, pos, end)
        pos += length
    elif wire == START_GROUP:
        if depth > 32:
            raise Malformed("groups nested too deeply")
        while True:
            n, w, pos = strict_key(data, pos, end)
            if w == END_GROUP:
                if n != number:
                    raise Malformed("unmatched end group")
                return pos
            pos = skip_value(data, pos, end, n, w, depth + 1)
    else:
        raise Malformed("unexpected end group")
    if pos > end:
        raise Malformed("truncated value")
    return pos


def map_key(field, data, pos, end):
    """The value of the last key of a map entry, the default for none."""
    key_f = field.message_type.fields_by_name["key"]
    text = key_f.type in (FD.TYPE_STRING, FD.TYPE_BYTES)
    key = b"" if text else 0
    try:
        while pos < end:
            number, wire, start = strict_key(data, pos, end)
            pos = skip_value(data, start, end, number, wire)
            if number != 1:
                continue
            if text and wire == DELIMITED:
                _, value_start = strict_varint(data, start, pos)
                key = bytes(data[value_start:pos])
            elif not text and wire == VARINT:
                key, _ = strict_varint(data, start, pos)
                if key_f.type == FD.TYPE_BOOL:
                    key = int(key != 0)
                elif key_f.type in (FD.TYPE_INT32, FD.TYPE_UINT32,
                                    FD.TYPE_SINT32):
                    key &= 2**32 - 1
            elif not text and wire in (FIXED32, FIXED64):
                key = int.from_bytes(data[start:pos], "little")
    except Malformed:
        pass
    return key


class Walker:
    def __init__(self, schema, bounds):
        self.schema, self.bounds = schema, bounds

    def run(self, desc, data):
        facts = Facts()
        try:
            self.message(desc, data, 0, len(data), facts, {})
        except Malformed:
            facts.malformed = True
        return facts

    def message(self, desc, data, pos, end, facts, counts):
        """counts holds the number of elements of each repeated field of this
        message instance, over all occurrences that merge into it, and under
        ("message", number) the counts of a singular message field."""
        while pos < end:
            number, wire, pos = strict_key(data, pos, end)
            field = desc.fields_by_number.get(number)
            if field is None or self.bounds.ignored(field) \
                    or not self.wire_fits(field, wire):
                if desc.GetOptions().map_entry:
                    # Unknown to Python too, a wrong wire type included
                    facts.entry_unknown = True
                pos = skip_value(data, pos, end, number, wire)
                continue
            packed = wire == DELIMITED and field.type not in (
                FD.TYPE_MESSAGE, FD.TYPE_STRING, FD.TYPE_BYTES)
            if is_repeated(field) and not packed:
                # The SPARK code checks for room before it reads a value
                self.full(field, counts, facts)
            if wire == DELIMITED:
                length, pos = strict_varint(data, pos, end)
                if pos + length > end:
                    raise Malformed("truncated field")
                start, pos = pos, pos + length
                if field.type == FD.TYPE_MESSAGE:
                    if is_repeated(field):
                        self.count(field, 1, counts, facts)
                        if is_map(field):
                            keys = counts.setdefault(("keys", number), set())
                            key = map_key(field, data, start, pos)
                            if key in keys:
                                facts.duplicate_key = True
                            keys.add(key)
                        self.message(field.message_type, data, start, pos,
                                     facts, {})
                    else:
                        oneof = field.containing_oneof
                        if oneof is not None and \
                                counts.get(("oneof", oneof.name)) != number:
                            # Setting another field of a oneof clears it
                            counts[("message", number)] = {}
                            counts[("oneof", oneof.name)] = number
                        sub = counts.setdefault(("message", number), {})
                        self.message(field.message_type, data, start, pos,
                                     facts, sub)
                elif field.type in (FD.TYPE_STRING, FD.TYPE_BYTES):
                    self.text(field, data[start:pos], facts)
                    if is_repeated(field):
                        self.count(field, 1, counts, facts)
                else:
                    self.packed(field, data, start, pos, facts, counts)
            else:
                value, pos = self.scalar(data, pos, end, wire)
                kept = field.type != FD.TYPE_ENUM \
                    or self.enum(field, value, facts)
                if field.containing_oneof is not None:
                    counts[("oneof", field.containing_oneof.name)] = number
                if is_repeated(field) and kept:
                    self.count(field, 1, counts, facts)
        return pos

    def wire_fits(self, field, wire):
        if field.type in (FD.TYPE_MESSAGE, FD.TYPE_STRING, FD.TYPE_BYTES):
            return wire == DELIMITED
        natural = VARINT if field.type in VARINT_TYPES else \
            FIXED32 if field.type in FIXED32_TYPES else FIXED64
        return wire == natural or (is_repeated(field) and wire == DELIMITED)

    def scalar(self, data, pos, end, wire):
        if wire == VARINT:
            return strict_varint(data, pos, end)
        size = 4 if wire == FIXED32 else 8
        if pos + size > end:
            raise Malformed("truncated fixed value")
        return int.from_bytes(data[pos:pos + size], "little"), pos + size

    def packed(self, field, data, pos, end, facts, counts):
        """Count each value as it is read: the SPARK code stops at the first
        one over the bound, maybe before a broken value after it."""
        wire = VARINT if field.type in VARINT_TYPES else \
            FIXED32 if field.type in FIXED32_TYPES else FIXED64
        while pos < end:
            self.full(field, counts, facts)
            value, pos = self.scalar(data, pos, end, wire)
            if field.type != FD.TYPE_ENUM or self.enum(field, value, facts):
                self.count(field, 1, counts, facts)

    def full(self, field, counts, facts):
        limit = self.bounds.count(field)
        if limit is not None and counts.get(field.number, 0) >= limit:
            facts.over = True

    def count(self, field, n, counts, facts):
        counts[field.number] = counts.get(field.number, 0) + n
        limit = self.bounds.count(field)
        if limit is not None and counts[field.number] > limit:
            facts.over = True

    def text(self, field, value, facts):
        cap = self.bounds.capacity(field)
        if cap is not None and len(value) > cap:
            facts.over = True
        if field.type == FD.TYPE_STRING:
            try:
                value.decode("utf-8")
            except UnicodeDecodeError:
                facts.bad_utf8 = True

    def enum(self, field, value, facts):
        """Return False for a value that is dropped: an unknown value of a
        proto2 enum is an unknown field."""
        known = {v.number & (2**32 - 1) for v in field.enum_type.values}
        if value & (2**32 - 1) in known:
            return True
        if not self.schema.proto3(field.enum_type):
            return False
        if self.bounds.first_policy(field):
            facts.first_unknown = True
        else:
            facts.unknown_enum = True
        return True


# ------------------------------------------------------------------ driver

class Runner:
    def __init__(self, args, schema, bounds, cls):
        self.args, self.schema, self.bounds, self.cls = \
            args, schema, bounds, cls
        self.counts = {}
        self.failures = []
        self.walker = Walker(schema, bounds)

    def count(self, what):
        self.counts[what] = self.counts.get(what, 0) + 1

    def fail(self, what, data, detail=""):
        self.count("FAIL " + what)
        n = len(self.failures)
        if n < 5:
            path = os.path.join(self.args.workdir, "fail%d.bin" % n)
            with open(path, "wb") as f:
                f.write(data)
            self.failures.append("%s: %s (input %s)" % (what, detail, path))

    def ada(self, data):
        work = self.args.workdir
        inp, out = os.path.join(work, "in.bin"), os.path.join(work, "out.bin")
        with open(inp, "wb") as f:
            f.write(data)
        if os.path.exists(out):
            os.remove(out)
        r = subprocess.run([self.args.roundtrip, inp, out],
                           capture_output=True, text=True, timeout=20)
        text = (r.stdout + r.stderr).strip()
        if r.returncode == 0:
            with open(out, "rb") as f:
                return "OK", f.read()
        if text in STATUSES:
            return text, None
        return "CRASH", text[:200]

    def reference(self, data):
        """Python's reading of data without unknown and ignored fields, or
        None if Python rejects it; and whether required fields are set."""
        msg = self.cls()
        try:
            msg.ParseFromString(data)
        except Exception:
            return None, True
        initialized = msg.IsInitialized()
        try:
            normalize(msg, self.bounds)
            msg.SerializeToString(deterministic=True)
        except Exception:
            # Proto2 strings that aren't UTF-8, which Python reads but
            # can't turn into str
            return None, initialized
        return msg, initialized

    def check(self, data, corrupted):
        status, result = self.ada(data)
        ref, initialized = self.reference(data)
        facts = self.walker.run(self.cls.DESCRIPTOR, data)
        kind = "corrupted" if corrupted else "valid"
        if status == "CRASH":
            self.fail(kind + ": crash", data, result)
            return
        if status == "OK":
            reasons = [what for what, found in (
                ("malformed", facts.malformed),
                # With the first policy, whether an unknown value counts
                # as an element is left open
                ("over a bound", facts.over and not facts.first_unknown),
                ("unknown enum value", facts.unknown_enum),
                ("string not UTF-8", facts.bad_utf8),
                ("required field missing", not initialized)) if found]
            if reasons:
                self.fail(kind + ": accepts input that is "
                          + " and ".join(reasons), data)
                return
            if ref is None:
                self.fail(kind + ": accepts what Python rejects", data)
                return
            got = self.cls()
            try:
                got.ParseFromString(result)
            except Exception as e:
                self.fail(kind + ": output not valid", data, str(e))
                return
            want_b = ref.SerializeToString(deterministic=True)
            got_b = got.SerializeToString(deterministic=True)
            if want_b == got_b:
                self.count(kind + ": same values")
            elif facts.first_unknown:
                self.count(kind + ": differs after unknown enum value "
                           "(first policy)")
            elif facts.entry_unknown:
                # Python drops a map entry with unknown fields into the
                # unknown fields of the map's message; the SPARK code skips
                # the unknown fields, as in any message, and keeps the entry
                self.count(kind + ": differs, map entry with unknown fields")
            else:
                self.fail(kind + ": values differ", data,
                          "want %s got %s" % (want_b.hex(), got_b.hex()))
            return
        reason = {
            "MALFORMED": facts.malformed,
            "TRUNCATED": facts.malformed,
            "LIMIT_EXCEEDED": facts.over,
            "UNKNOWN_ENUM": facts.unknown_enum,
            "INVALID_UTF8": facts.bad_utf8,
            "MISSING_REQUIRED": not initialized,
        }[status]
        if reason:
            self.count(kind + ": rejected, " + status)
        elif facts.entry_unknown:
            # What Python moved to unknown fields can't be checked against
            # Python; protoc (C++) reads such entries as the SPARK code does
            self.count(kind + ": rejected, " + status
                       + ", in a map entry with unknown fields")
        elif facts.duplicate_key:
            # The SPARK code keeps every entry and checks each, Python only
            # the last one of each key
            self.count(kind + ": rejected, " + status
                       + ", with a duplicate map key")
        elif ref is None:
            self.fail(kind + ": rejected with no reason, Python rejects too",
                      data, status)
        else:
            self.fail(kind + ": rejects what Python accepts", data, status)

    def run(self):
        rnd = random.Random(self.args.seed)
        gen = Generator(self.schema, self.bounds, rnd)
        for _ in range(self.args.count):
            msg, extra = self.cls(), self.cls()
            gen.fill(msg)
            gen.fill(extra)
            data = msg.SerializeToString()
            self.check(data, False)
            self.check(variant(rnd, msg, extra), False)
            for _ in range(3):
                self.check(corrupt(rnd, data), True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("descriptor_set")
    p.add_argument("options_dir")
    p.add_argument("message")
    p.add_argument("roundtrip")
    p.add_argument("workdir")
    p.add_argument("--count", type=int, default=100)
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args()
    os.makedirs(args.workdir, exist_ok=True)
    schema = Schema(args.descriptor_set)
    bounds = Bounds(args.options_dir)
    runner = Runner(args, schema, bounds, schema.message_class(args.message))
    runner.run()
    for what in sorted(runner.counts):
        print("  %6d %s" % (runner.counts[what], what))
    for line in runner.failures:
        print("  " + line)
    return 1 if runner.failures else 0


if __name__ == "__main__":
    sys.exit(main())

Ada Generated Code
==================

## Compiler Invocation

The protocol buffer compiler produces Ada output when invoked with
the `--ada_out=` command-line flag (be sure the `protoc-gen-ada`
plugin in the `PATH`).  The compiler creates a specification file
(`.ads`) and an implementation file (`.adb`) for each `.proto` file
input. The names of the output files are computed by taking the name
of the `.proto` file and a name from a `package` directive, if any.

## Packages

If a `.proto` file contains a package declaration, then it will be used as
a prefix of the corresponding Ada package.
For example, given the `package` declaration in `xxx.proto` file:

```protobuf
package foo.bar;
```

All declarations in the file will reside in the `Foo.Bar.Xxx` package.

## Messages

Given a simple message declaration:
```protobuf
message Blah {}
```

The protocol buffer compiler generates a record type called `Blah`
and corresponding `'Read`/`'Write` aspects to serialize to/from
`Ada.Streams.Root_Stream_Type`. For parsing from and serializing
to a binary stream use corresponding Ada streaming:

```ada
declare
   Stream : Ada.Streams.Stream_IO.Stream_Access :=
      Ada.Streams.Stream_IO.Stream (Input);
   Data : Foo.Bar.Blah;
begin
   Foo.Bar.Blah'Read (Stream, Data);   --  Parsing
   Foo.Bar.Blah'Write (Stream, Data);  --  Serializing
end;
```

Also, for each message declaration the compiler creates corresponding
_vector_ and _optional_ types. An optional type looks like this:

```ada
   type Optional_Blah (Is_Set : Boolean := False) is
     record
        case Is_Set is
           when True =>
              Value : Blah;
           when False =>
              null;
        end case;
     end record;
```
A user can check if an optional field is present by checking its discriminant.

```ada
procedure Process (V : in out Optional_Blah) is
begin
   if V.Is_Set then  --  Check if the field is present
      Print (V.Value);  --  Access the field value
      V := (Is_Set => False);  --  Clear the field
   else
      V := (Is_Set => True, Value => 123);  --  Assign
   end if;
end Process;
```
A vector type is a bit more complex. To allow indexing on the vector,
the compiler generates Ada 2012 `Variable_Indexing` and `Constant_Indexing`
aspects and all related constructs.
These are mostly meaningless for the user, but make the Ada compiler happy.
It also generates `Length`, `Clear` and `Append` routines.

```ada
   type Blah_Vector is tagged private
     with
       Variable_Indexing => Get_Blah_Variable_Reference,
       Constant_Indexing => Get_Blah_Constant_Reference;

   type Blah_Variable_Reference
     (Element : not null access Blah) is null record
       with Implicit_Dereference => Element;

   function Get_Blah_Variable_Reference
    (Self  : aliased in out Blah_Vector;
     Index : Positive) return Blah_Variable_Reference
       with Inline;

   type Blah_Constant_Reference
     (Element : not null access constant Blah) is
       null record
         with Implicit_Dereference => Element;

   function Get_Blah_Constant_Reference
    (Self  : aliased in out Blah_Vector;
     Index : Positive) return Blah_Constant_Reference
       with Inline;

   function Length (Self : Blah_Vector) return Natural;

   procedure Clear (Self : in out Blah_Vector);

   procedure Append
    (Self  : in out Blah_Vector;
     Value : Blah);
```

With these declarations, a user can process vectors like this:
```ada
procedure Process (V : in out Blah_Vector) is
begin
   for J in 1 .. V.Length loop
      Print (V (J));
   end loop;
   V.Clear;
   V.Append (123);
end Process;
```


## Nested Types
A message can be declared inside another message. For example:
`message Foo { message Bar { } }`. In this case, the compiler generates
two types: `Foo` and `Bar`. The compiler can change declaration order to
follow forward-declare restriction.

## Fields
For each message field the protocol buffer compiler generates
a record component. The component has default initialization when
this is required.

### Fields of Predefined Types
The compiler uses this mapping for predefined types:

| .proto type | Ada type      |
| ----------- | ------------- |
| double      | Interfaces.IEEE_Float_64 |
| float       | Interfaces.IEEE_Float_32 |
| int32/64    | Interfaces.Integer_32/64 |
| uint32/64   | Interfaces.Unsigned_32/64 |
| sint32/64   | Interfaces.Integer_32/64 (unimplemented) |
| fixed32/64  | Interfaces.Unsigned_32/64 (little endian only)|
| sfixed32/64 | Interfaces.Integer_32/64 (little endian only)|
| bool        | Boolean |
| string      | League.Strings.Universal_String |
| bytes       | League.Stream_Element_Vectors.Stream_Element_Vector |

For singular `proto3` fields and required `proto2` fields the compiler
generates just a component of the corresponding type. For instance:

```protobuf
int32 foo = 1; # proto3
required int32 foo = 1;  # proto2
````

```ada
type Blah is record
   Foo : Interfaces.Integer_32 := 0;
```

For optional proto2 fields the compiler uses an optional type from
corresponding generic package instantiation. Such instantiations are
parts of a protobuf support library provided by `protobuf_runtime.gpr`
project. All optional types have the same shape:
```ada
   type Option (Is_Set : Boolean := False) is record
      case Is_Set is
         when True =>
            Value : Element_Type;
         when False =>
            null;
      end case;
   end record;
```

### Singular Enum Fields

Given the enum type:
```protobuf
enum Bar {
  BAR_VALUE = 0;
  OTHER_VALUE = 1;
}
```

For this field definition:
```protobuf
Bar foo = 1;
```

The compiler will generate the following component:
```ada
type Blah is record
   Foo : Bar := BAR_VALUE;
end record;
```

Note: enumeration parsing procedure uses `Ada.Unchecked_Convention`, so
read value could be invalid when `enum` definition changed and new literals
are added. To detect such situation, you can check the component value
with `X.Foo'Valid` attribute before using.


### Singular Embedded Message Fields
Given the message type `Bar`, for any of these field definitions:

```protobuf
optional Bar foo1 = 1;
required Bar foo2 = 2;
```

The compiler will generate the following accessor components:
```ada
type Blah is record
  Foo_1 : Optional_Bar;
  Foo_2 : Bar;
end record;
```

#### Partial support for mutual dependent messages.
With such representation, we can't have mutual dependent message declarations,
because this is not allowed in Ada. But if the field is repeated then all
works fine, because a vector type breaks circular dependency.
To give at least a minimum support for such case, the compiler tries to
break a circle by replacing a singular message field with a repeated one.
User should ensure that the vector contains the required number of elements
(exactly one for a `required` field and zero-or-one for an `optional` field).

### Repeated Fields of Predefined Types
For repeated fields of predefined types, the compiler uses the corresponding
vector type from a package instantiation provided by the support library,
like this:

```ada
type Location is record
   Path : PB_Support.Unsigned_32_Vectors.Vector;
```

There is an exception for the string type.

### Repeated String Fields
For repeated fields of the string type the compiler uses
`Universal_String_Vector` type declared in `League.String_Vectors` package.

### Repeated Enum Fields
For repeated fields of an `enum` type the compiler uses
a vector type from corresponding generic instantiation.

### Repeated Embedded Message Fields
For repeated fields of a message type the compiler uses
a vector type declared with the message type.

### Oneof Fields
For now, we support only single `Oneof` construction per message.
The compiler generates a component with name `Variant` of a corresponding type.
This component has a discriminant with the name `Oneof`.
There is a single component for each discriminant value.

### Map Fields
There is no special support for map fields for now.

## Any
`Any` type isn't provided yet.

## Oneof
Currently, we support only a single `Oneof` construction per message.
For such a construction, the compiler generates an enumeration type and
a discriminated record type. Inside a message it generates one component
with name `Variant`. For example:
```protobuf
message Value {
  // The kind of value.
  oneof kind {
    // Represents a null value.
    NullValue null_value = 1;
    // Represents a double value.
    double number_value = 2;
  }
}
```

The generated code looks like:
```ada
type Value_Variant_Kind is
  (Kind_Not_Set,
   Null_Value_Kind,
   Number_Value_Kind);

type Value_Variant (Kind : Value_Variant_Kind := Kind_Not_Set) is record
   case Kind is
      when Kind_Not_Set =>
         null;
      when Null_Value_Kind =>
         Null_Value : Google.Protobuf.Struct.Null_Value :=
           Google.Protobuf.Struct.PB_NULL_VALUE;
      when Number_Value_Kind =>
         Number_Value : Interfaces.IEEE_Float_64 := 0.0;
   end case;
end record;

type Value is record
   Variant : Value_Variant;
end record;
```

A dedicated enumeration literal `<oneof_name>_Not_Set` represents a case
when none of the fields is set.

## Enumerations
Given an enum definition like:

```protobuf
enum Foo {
  VALUE_A = 0;
  VALUE_B = 5;
  VALUE_C = 1234;
}
```

The protocol buffer compiler will generate an Ada enumeration type
called `Foo` with the same set of values. It also generates a
corresponding vector instantiation:
```ada
type Foo is (VALUE_A, VALUE_B, VALUE_C);
for Foo use (VALUE_A => 0, VALUE_B => 5, VALUE_C => 1234);

package Foo_Vectors is new PB_Support.Vectors (Foo);
```

## SPARK Output

With `runtime=spark` the compiler generates SPARK packages instead. They
use no heap, exceptions, secondary stack, finalization, tasking or
`Ada.Streams`, so they work with light and bare-metal Ada runtimes. They
depend only on the SPARK runtime (`gnat/protobuf_spark_runtime.gpr`, crate
`protobuf_spark_runtime`), not on Matreshka League.

```sh
protoc --ada_out=out --ada_opt=runtime=spark,options=my.options my.proto
```

Without `runtime=spark` the generated code is the same as before.

### Plugin Parameters

The parameter given with `--ada_opt` is a comma-separated list:

| Parameter                | Meaning |
| ------------------------ | ------- |
| `runtime=spark`          | Generate SPARK code. The default is `runtime=league` |
| `options=<file>`         | Read generator options from this file. `%s` stands for the name of the `.proto` file without its extension. Can be given more than once |
| `options_path=<dir>`     | Look for options files in this directory. Can be given more than once. The default is the current directory |
| `ignore_unknown_options` | Don't report unknown keys in options files |

Without `options=`, the file `%s.options` is read if it exists. A file named
without `%s` must exist, because it can only be there on purpose.

### Options Files

The SPARK output has no unbounded fields, so every string, bytes, repeated
and map field needs a bound. Bounds are given in an options file, in a
format close to that of nanopb:

```
# Comments start with "#" or "//"
my.pkg.Message.name    max_length:32
Message.items          max_count:8
Message.*              max_size:16
Message.debug_info     type:ignore
*.status               on_unknown_enum:first
```

Each line holds a pattern and `key:value` pairs. A pattern is matched
against the full name of a field (`my.pkg.Message.field`), its name without
the package (`Message.field`) and the name of its `.proto` file. `*` matches
any sequence of characters, dots included, and `?` matches one character.
When several lines match a field, later lines override earlier ones. A
pattern that matches no field causes a warning.

| Key               | Applies to       | Meaning |
| ----------------- | ---------------- | ------- |
| `max_length`      | string           | Capacity in bytes of UTF-8 text |
| `max_size`        | string, bytes    | Capacity in bytes. For strings the capacity is `N-1`, as in nanopb, where it includes a terminating zero |
| `max_count`       | repeated, map    | Maximum number of elements or entries |
| `type`            | any field        | `default` or `static`: generate the field. `ignore`: don't generate it, and skip it like an unknown field when decoding |
| `on_unknown_enum` | proto3 enum      | `reject` (the default): decoding fails with `Unknown_Enum`. `first`: the field keeps its default value |

`max_length` and `max_size` can't be on the same line. `callback` and
`pointer` types are not supported. A required field can't be ignored.

The compiler checks the whole schema, including imported files, and reports
all problems at once in `CodeGeneratorResponse.error`:

* a string, bytes or repeated field without a bound;
* a `group` field that isn't ignored;
* recursive messages, with the cycle, for example
  `google.protobuf.Value.list_value -> google.protobuf.ListValue.values ->
  google.protobuf.Value`. Ignoring one field of the cycle breaks it;
* a message whose maximum encoded size is over 2^30 bytes;
* names that would clash in Ada.

### Generated Declarations

For each message `Blah` the package declares:

```ada
   type Blah is record ... end record;

   Blah_Max_Encoded_Size : constant := 42;

   procedure Clear (V : out Blah);

   procedure Encode
    (V      : Blah;
     Buffer : in out PB_SPARK.Byte_Array;
     Last   : out PB_SPARK.Index)
     with Pre  =>
       PB_SPARK.Valid_Buffer (Buffer)
         and then Buffer'Last >= Blah_Max_Encoded_Size,
     Post => Last <= Blah_Max_Encoded_Size;

   procedure Append
    (V      : Blah;
     Buffer : in out PB_SPARK.Byte_Array;
     Last   : in out PB_SPARK.Index);
   --  Encode after Last, which must leave room for Blah_Max_Encoded_Size

   procedure Decode
    (Buffer : PB_SPARK.Byte_Array;
     V      : out Blah;
     Status : out PB_SPARK.Status_Kind)
     with Pre => PB_SPARK.Valid_Buffer (Buffer);

   procedure Merge
    (Buffer : PB_SPARK.Byte_Array;
     Limit  : PB_SPARK.Index;
     Pos    : in out PB_SPARK.Index;
     V      : in out Blah;
     Status : out PB_SPARK.Status_Kind);
   --  Decode Buffer (Pos .. Limit) into V, as a repeated occurrence of the
   --  message would
```

Buffers are arrays of `Interfaces.Unsigned_8` indexed by `PB_SPARK.Index`,
starting at 1. `Encode` can't fail when the buffer has room for
`Blah_Max_Encoded_Size` bytes, the size of the largest message that fits
the bounds. Only decoding, which reads untrusted input, returns a status.
`Decode` clears the message first and, for proto2, checks required fields,
which `Is_Initialized (V)` also reports.

```ada
declare
   Buffer : PB_SPARK.Byte_Array (1 .. Foo.Bar.Blah_Max_Encoded_Size);
   Last   : PB_SPARK.Index;
   Data   : Foo.Bar.Blah;
   Status : PB_SPARK.Status_Kind;
begin
   Foo.Bar.Encode (Data, Buffer, Last);                --  Serializing
   Foo.Bar.Decode (Buffer (1 .. Last), Data, Status);  --  Parsing

   if Status /= PB_SPARK.OK then
      ...
   end if;
end;
```

| Status             | Meaning |
| ------------------ | ------- |
| `OK`               | The message was decoded |
| `Truncated`        | The input ends in the middle of a value |
| `Malformed`        | The input is not valid protobuf: a varint over 10 bytes, a key over 5 bytes, field number 0 or above 2^29-1, wire type 6 or 7, unbalanced or too deeply nested groups |
| `Limit_Exceeded`   | The input doesn't fit the bounds of the options file |
| `Invalid_UTF8`     | A string is not valid UTF-8. This includes proto2 strings, which other implementations don't check |
| `Missing_Required` | A proto2 required field is missing |
| `Unknown_Enum`     | A proto3 enum field holds a value the schema doesn't define, with `on_unknown_enum:reject` |

Decoding accepts fields in any order and packed or unpacked repeated
fields. It skips unknown fields and fields with the wrong wire type,
including unknown groups nested up to 32 deep. When a field occurs more
than once, the last scalar wins, messages are merged and repeated fields
are appended to, as protobuf requires. Encoding writes fields in the order
of the `.proto` file.

Fields map to components like this:

| .proto field | Ada components |
| ------------ | -------------- |
| `int32`, `sint32`, `sfixed32` | `Interfaces.Integer_32` |
| `int64`, `sint64`, `sfixed64` | `Interfaces.Integer_64` |
| `uint32`, `fixed32` | `Interfaces.Unsigned_32` |
| `uint64`, `fixed64` | `Interfaces.Unsigned_64` |
| `bool` | `Boolean` |
| `float`, `double` | `PB_SPARK.Float_32_Bits`, `PB_SPARK.Float_64_Bits` |
| `string`, `bytes` | a record with `Length` and `Data (1 .. Capacity)` |
| enum | the Ada enumeration, see below |
| message | the message record |
| `optional`, proto2 singular, proto3 message | `Has_Foo : Boolean` and `Foo` |
| `repeated`, map | `Foo : array (1 .. Max_Count)` and `Foo_Count` |
| `oneof kind` | `Kind`, a discriminated record with discriminant `Kind`, which is `Kind_Not_Set` or `Foo_Kind` for field `foo` |

`float` and `double` fields hold IEEE bits, so the generated code never
uses floating point and keeps NaNs, infinities and `-0.0` intact.
`PB_SPARK.Float_Bits` converts between bits and `IEEE_Float_32`/`64`.
Proto2 defaults are the initial values of the components.

A map is a repeated field of entries with `Key` and `Value` components.
Entries are kept in input order, duplicate keys included, so a lookup
should use the last entry with the key, as protobuf does.

Where protobuf leaves room, decoding is stricter than other implementations:

* Every occurrence of a field is checked, not only the one that wins. A
  string over its bound or an unknown proto3 enum value fails decoding even
  if a later occurrence of the field replaces it.
* Bounds and proto2 required fields are checked for every map entry,
  duplicate keys included.
* A tag with field number 0 is `Malformed`. Python's upb parser stops
  reading there instead.
* Unknown fields inside a map entry are skipped and the entry is kept, as
  `protoc` (C++) does. Python's upb parser instead moves the whole entry to
  the unknown fields of the message that holds the map.

For each enum `Foo` the package also declares `Foo_To_Wire` and
`Foo_From_Wire`. They convert with a `case` statement rather than
`Unchecked_Conversion`, so decoding can't create an invalid enum value.
Unknown values of proto2 enums are dropped, like unknown fields.

### What Is Proved

`gnatprove --mode=all --level=2` proves the runtime and the generated code
at the Silver level: no run-time error can happen on any input and there
are no reads of uninitialized data. There is no recursion and every `while`
loop has a proved variant, so `Decode` and `Merge` always end. The
contracts above are proved too, so a buffer of `Blah_Max_Encoded_Size`
bytes is always large enough for `Encode`. There is no `pragma Assume` and
no unproved check. The generated code suppresses only GNATprove flow
warnings about values that are set but not used. Proof is per schema, so
prove the code generated for yours. `testsuite_spark/run_all.sh` shows the
switches to use.

That decoding gives back what was encoded is not proved. Tests check it:

* `testsuite_spark/run_all.sh` round-trips `protoc`-encoded input.
* With `DIFFERENTIAL=N` it also runs `testsuite_spark/differential.py`,
  which compares with Python protobuf. For N random messages within the
  bounds it checks:
  * their encodings and variants of them, with fields reordered, unknown
    fields added, packed fields sent unpacked, and fields sent twice;
  * corrupted copies, which must not crash, must decode to Python's values
    when both accept them, and must only be rejected for a reason found by
    a strict reading of the input, as listed above.
* `conformance_spark.sh` runs Google's conformance tests against code
  generated for `test_messages_proto2.proto` and `test_messages_proto3.proto`.

These are trusted rather than proved:

* The body of `PB_SPARK.Float_Bits`, the only unit with `SPARK_Mode => Off`,
  because SPARK doesn't allow converting bits to floating-point values.
  Only applications that call it depend on it.
* The Ada compiler and runtime, and GNATprove.
* `protoc-gen-ada` itself. Its output is proved each time GNATprove runs
  on it.
* Stack usage, which SPARK doesn't check. Large bounds make large records,
  so pass them by reference and check the stack with `-fstack-usage`. The
  generated code makes no temporary copies of a message: `Clear` copies a
  constant `Blah_Default` from the package body, written out in full so
  that it needs no elaboration code.

To check the runtime against the restrictions of light runtimes in
`source/spark_runtime/restrictions.adc`, build it with
`PB_SPARK_RESTRICTIONS=enabled`. The restrictions apply to a whole program,
so they are off by default to let host programs use the runtime.

### Not Supported

* Unbounded fields
* Recursive messages, except by ignoring a field of the cycle
* Groups, except by ignoring them
* Extensions: their fields are skipped as unknown fields
* Keeping unknown fields for re-encoding, which the League output doesn't
  do either
* JSON and text format

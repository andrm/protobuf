--  MIT License
--
--  Copyright (c) 2026 Konsec GmbH
--
--  Permission is hereby granted, free of charge, to any person obtaining a
--  copy of this software and associated documentation files (the "Software"),
--  to deal in the Software without restriction, including without limitation
--  the rights to use, copy, modify, merge, publish, distribute, sublicense,
--  and/or sell copies of the Software, and to permit persons to whom the
--  Software is furnished to do so, subject to the following conditions:
--
--  The above copyright notice and this permission notice shall be included in
--  all copies or substantial portions of the Software.
--
--  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
--  THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
--  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--  DEALINGS IN THE SOFTWARE.

--  The protobuf wire format.
--
--  Encoders append after Last, which is the last position written so far.
--  Decoders read from Pos up to and including Limit. Limit is explicit so
--  that nested messages can be decoded in place from the same buffer.

with Interfaces; use Interfaces;

package PB_SPARK.Wire with SPARK_Mode, Pure is

   type Wire_Type is
     (Varint, Fixed_64, Length_Delimited, Start_Group, End_Group, Fixed_32);
   --  Positions of these literals are the values used on the wire

   subtype Field_Number is Unsigned_32 range 1 .. 536_870_911;

   subtype Varint_Length is Index range 1 .. 10;

   subtype Tag_Length is Index range 1 .. 5;

   Max_Group_Depth : constant := 32;
   --  Unknown groups nested deeper than this are rejected

   ------------------------
   -- Sizes and contracts --
   ------------------------

   function Varint_Size (Value : Unsigned_64) return Varint_Length is
     (if Value < 2 ** 7 then 1
      elsif Value < 2 ** 14 then 2
      elsif Value < 2 ** 21 then 3
      elsif Value < 2 ** 28 then 4
      elsif Value < 2 ** 35 then 5
      elsif Value < 2 ** 42 then 6
      elsif Value < 2 ** 49 then 7
      elsif Value < 2 ** 56 then 8
      elsif Value < 2 ** 63 then 9
      else 10);

   function Length_Size (Value : Index) return Varint_Length is
     (Varint_Size (Unsigned_64 (Value)));

   function Tag_Size (Field : Field_Number) return Tag_Length is
     (if Field < 16 then 1
      elsif Field < 2_048 then 2
      elsif Field < 262_144 then 3
      elsif Field < 33_554_432 then 4
      else 5);

   function Bytes_Field_Size
     (Field    : Field_Number;
      Capacity : Buffer_Last) return Index'Base is
     (Tag_Size (Field) + Length_Size (Capacity) + Capacity);
   --  Maximum encoded size of a bytes or string field

   function Valid_Reader
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : Index) return Boolean is
     (Valid_Buffer (Buffer)
      and then Limit <= Buffer'Last
      and then Pos in 1 .. Limit + 1);

   -----------------
   -- Conversions --
   -----------------

   function From_Integer_32 (Value : Integer_32) return Unsigned_64 is
     (if Value >= 0 then Unsigned_64 (Value)
      else Unsigned_64'Last - Unsigned_64 (-(Value + 1)));
   --  Value of an int32 or enum varint, which sign-extends negative numbers

   function From_Integer_64 (Value : Integer_64) return Unsigned_64 is
     (if Value >= 0 then Unsigned_64 (Value)
      else Unsigned_64'Last - Unsigned_64 (-(Value + 1)));

   function Zigzag_32 (Value : Integer_32) return Unsigned_64 is
     (if Value >= 0 then Unsigned_64 (Value) * 2
      else Unsigned_64 (-(Value + 1)) * 2 + 1);

   function Zigzag_64 (Value : Integer_64) return Unsigned_64 is
     (if Value >= 0 then Unsigned_64 (Value) * 2
      else Unsigned_64 (-(Value + 1)) * 2 + 1);

   function To_Integer_32 (Value : Unsigned_64) return Integer_32;
   --  Keep the low 32 bits of a varint, as protobuf parsers do

   function To_Integer_64 (Value : Unsigned_64) return Integer_64;

   function To_Unsigned_32 (Value : Unsigned_64) return Unsigned_32 is
     (Unsigned_32 (Value and 16#FFFF_FFFF#));

   function Unzigzag_32 (Value : Unsigned_64) return Integer_32;

   function Unzigzag_64 (Value : Unsigned_64) return Integer_64;

   function To_Boolean (Value : Unsigned_64) return Boolean is (Value /= 0);

   function Bits_Of (Value : Integer_32) return Unsigned_32;
   --  The two's complement bits of an sfixed32

   function Bits_Of (Value : Integer_64) return Unsigned_64;

   function Signed_Of (Bits : Unsigned_32) return Integer_32;

   function Signed_Of (Bits : Unsigned_64) return Integer_64;

   --------------
   -- Encoding --
   --------------

   procedure Put_Varint
     (Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <= Buffer'Last - Varint_Size (Value),
          Post => Last = Last'Old + Varint_Size (Value);

   procedure Put_Tag
     (Field  : Field_Number;
      Wire   : Wire_Type;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <= Buffer'Last - Tag_Size (Field),
          Post => Last = Last'Old + Tag_Size (Field);

   procedure Put_Fixed_32
     (Value  : Unsigned_32;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer) and then Last <= Buffer'Last - 4,
          Post => Last = Last'Old + 4;
   --  Write a fixed32 value without a tag, as in packed fields

   procedure Put_Fixed_64
     (Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer) and then Last <= Buffer'Last - 8,
          Post => Last = Last'Old + 8;

   procedure Put_Varint_Field
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <=
                    Buffer'Last - (Tag_Size (Field) + Varint_Size (Value)),
          Post => Last = Last'Old + Tag_Size (Field) + Varint_Size (Value);

   procedure Put_Varint_Option
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <=
                    Buffer'Last - (Tag_Size (Field) + Varint_Size (Value)),
          Post => Last in Last'Old
                    .. Last'Old + Tag_Size (Field) + Varint_Size (Value);
   --  Write the field unless Value is zero

   procedure Put_Fixed_32_Field
     (Field  : Field_Number;
      Value  : Unsigned_32;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <= Buffer'Last - (Tag_Size (Field) + 4),
          Post => Last = Last'Old + Tag_Size (Field) + 4;

   procedure Put_Fixed_32_Option
     (Field  : Field_Number;
      Value  : Unsigned_32;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <= Buffer'Last - (Tag_Size (Field) + 4),
          Post => Last in Last'Old .. Last'Old + Tag_Size (Field) + 4;
   --  Write the field unless all bits are zero. Float -0.0 is written.

   procedure Put_Fixed_64_Field
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <= Buffer'Last - (Tag_Size (Field) + 8),
          Post => Last = Last'Old + Tag_Size (Field) + 8;

   procedure Put_Fixed_64_Option
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <= Buffer'Last - (Tag_Size (Field) + 8),
          Post => Last in Last'Old .. Last'Old + Tag_Size (Field) + 8;

   procedure Put_Bytes_Field
     (Field  : Field_Number;
      Data   : Byte_Array;
      Length : Index;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Valid_Buffer (Data)
                  and then Length <= Data'Last
                  and then Last <=
                    Buffer'Last - Bytes_Field_Size (Field, Data'Last),
          Post => Last in Last'Old + 2
                    .. Last'Old + Bytes_Field_Size (Field, Data'Last);

   procedure Put_Bytes_Option
     (Field  : Field_Number;
      Data   : Byte_Array;
      Length : Index;
      Buffer : in out Byte_Array;
      Last   : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Valid_Buffer (Data)
                  and then Length <= Data'Last
                  and then Last <=
                    Buffer'Last - Bytes_Field_Size (Field, Data'Last),
          Post => Last in Last'Old
                    .. Last'Old + Bytes_Field_Size (Field, Data'Last);
   --  Write the field unless Length is zero

   procedure Reserve_Delimited
     (Field     : Field_Number;
      Max_Body  : Buffer_Last;
      Buffer    : in out Byte_Array;
      Last      : in out Index;
      Body_Last : out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Last <=
                    Buffer'Last - Bytes_Field_Size (Field, Max_Body),
          Post => Last = Last'Old + Tag_Size (Field)
                  and then Body_Last = Last + Length_Size (Max_Body);
   --  Write a tag and leave room for the largest length prefix. Write the
   --  body after Body_Last, then call Finish_Delimited.

   procedure Finish_Delimited
     (Max_Body  : Buffer_Last;
      Body_Last : Index;
      Buffer    : in out Byte_Array;
      Last      : in out Index)
     with Pre  => Valid_Buffer (Buffer)
                  and then Body_Last <= Buffer'Last
                  and then Last <= Buffer'Last - Length_Size (Max_Body)
                  and then Body_Last >= Last + Length_Size (Max_Body)
                  and then Body_Last - (Last + Length_Size (Max_Body))
                    <= Max_Body,
          Post => Last in Last'Old + 1 .. Body_Last;
   --  Write the length prefix after Last and move the body next to it

   --------------
   -- Decoding --
   --------------

   procedure Get_Varint
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Value  : out Unsigned_64;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1
                  and then (if Status = OK then Pos > Pos'Old);

   procedure Get_Key
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Field  : out Unsigned_32;
      Wire   : out Wire_Type;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1
                  and then (if Status = OK
                            then Pos > Pos'Old and then Field in Field_Number);

   procedure Get_Fixed_32
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Value  : out Unsigned_32;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1
                  and then (if Status = OK then Pos = Pos'Old + 4);

   procedure Get_Fixed_64
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Value  : out Unsigned_64;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1
                  and then (if Status = OK then Pos = Pos'Old + 8);

   procedure Get_Delimited
     (Buffer      : Byte_Array;
      Limit       : Index;
      Pos         : in out Index;
      Inner_Limit : out Index;
      Status      : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1
                  and then Inner_Limit in Pos - 1 .. Limit;
   --  Read a length prefix. Its content is Pos .. Inner_Limit. Set Pos to
   --  Inner_Limit + 1 to continue after it.

   procedure Skip_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1;
   --  Skip the value of a field whose key was just read

   procedure Read_Varint_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Value  : in out Unsigned_64;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1;
   --  Read a varint, or skip the field if it has another wire type

   procedure Read_Fixed_32_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Value  : in out Unsigned_32;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1;

   procedure Read_Fixed_64_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Value  : in out Unsigned_64;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1;

   procedure Read_Bytes_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Data   : in out Byte_Array;
      Length : in out Index;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos)
                  and then Valid_Buffer (Data)
                  and then Length <= Data'Last,
          Post => Pos in Pos'Old .. Limit + 1
                  and then Length <= Data'Last;

   procedure Read_String_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Data   : in out Byte_Array;
      Length : in out Index;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos)
                  and then Valid_Buffer (Data)
                  and then Length <= Data'Last,
          Post => Pos in Pos'Old .. Limit + 1
                  and then Length <= Data'Last;
   --  Like Read_Bytes_Field, and the content must be valid UTF-8

end PB_SPARK.Wire;

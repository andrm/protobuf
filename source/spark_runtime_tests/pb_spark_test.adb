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

--  Tests of what proofs don't cover: that the bytes written and the values
--  read are the right ones. Expected encodings come from the protobuf
--  encoding documentation or are worked out by hand.

with Ada.Command_Line;
with Ada.Text_IO;

with Interfaces; use Interfaces;

with PB_SPARK;            use PB_SPARK;
with PB_SPARK.Float_Bits;
with PB_SPARK.UTF8;
with PB_SPARK.Wire;       use PB_SPARK.Wire;

procedure PB_SPARK_Test is

   Failures : Natural := 0;

   Max_U64 : constant Unsigned_64 := Unsigned_64'Last;

   Text_ABC : constant Byte_Array := (16#61#, 16#62#, 16#63#);

   procedure Check (Condition : Boolean; Name : String);

   procedure Check_Varint
     (Value    : Unsigned_64;
      Expected : Byte_Array;
      Name     : String);

   procedure Check_Tag
     (Field    : Field_Number;
      Wire     : Wire_Type;
      Expected : Byte_Array;
      Name     : String);

   procedure Check_UTF8
     (Data     : Byte_Array;
      Expected : Boolean;
      Name     : String);

   function Same
     (Buffer   : Byte_Array;
      Last     : Index;
      Expected : Byte_Array) return Boolean is
     (Last = Expected'Length and then Buffer (1 .. Last) = Expected);

   function Repeat (Item : Byte; Count : Index) return Byte_Array is
     (Position range 1 .. Count => Item);

   procedure Skip_Test
     (Data       : Byte_Array;
      Wire       : Wire_Type;
      Expect_Pos : Index;
      Expected   : Status_Kind;
      Name       : String);

   procedure Group_Test
     (Data     : Byte_Array;
      Expected : Status_Kind;
      Name     : String);

   procedure Key_Test
     (Data       : Byte_Array;
      Expected   : Status_Kind;
      Expect_Num : Unsigned_32;
      Expect_W   : Wire_Type;
      Name       : String);

   procedure Test_Varints;
   procedure Test_Tags;
   procedure Test_Documented_Examples;
   procedure Test_Conversions;
   procedure Test_Fixed;
   procedure Test_Options;
   procedure Test_Delimited;
   procedure Test_Decode_Errors;
   procedure Test_Skip;
   procedure Test_Read_Fields;
   procedure Test_UTF8;
   procedure Test_Float;
   procedure Test_Round_Trip;

   -----------
   -- Check --
   -----------

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("FAILED: " & Name);
      end if;
   end Check;

   ---------------
   -- Check_Tag --
   ---------------

   procedure Check_Tag
     (Field    : Field_Number;
      Wire     : Wire_Type;
      Expected : Byte_Array;
      Name     : String)
   is
      Buffer : Byte_Array (1 .. 8) := (others => 0);
      Last   : Index := 0;
      Pos    : Index := 1;
      Number : Unsigned_32;
      Kind   : Wire_Type;
      Status : Status_Kind;
   begin
      Put_Tag (Field, Wire, Buffer, Last);
      Check (Same (Buffer, Last, Expected), Name & " bytes");
      Check (Last = Tag_Size (Field), Name & " size");
      Get_Key (Buffer, Last, Pos, Number, Kind, Status);
      Check (Status = OK and Number = Field and Kind = Wire, Name & " key");
   end Check_Tag;

   ----------------
   -- Check_UTF8 --
   ----------------

   procedure Check_UTF8
     (Data     : Byte_Array;
      Expected : Boolean;
      Name     : String) is
   begin
      Check (UTF8.Is_Valid (Data, Data'Length) = Expected, Name);
   end Check_UTF8;

   ------------------
   -- Check_Varint --
   ------------------

   procedure Check_Varint
     (Value    : Unsigned_64;
      Expected : Byte_Array;
      Name     : String)
   is
      Buffer : Byte_Array (1 .. 16) := (others => 0);
      Last   : Index := 0;
      Pos    : Index := 1;
      Item   : Unsigned_64;
      Status : Status_Kind;
   begin
      Put_Varint (Value, Buffer, Last);
      Check (Same (Buffer, Last, Expected), Name & " bytes");
      Check (Last = Varint_Size (Value), Name & " size");
      Get_Varint (Buffer, Last, Pos, Item, Status);
      Check (Status = OK and Item = Value and Pos = Last + 1, Name & " get");
   end Check_Varint;

   ----------------
   -- Group_Test --
   ----------------

   procedure Group_Test
     (Data     : Byte_Array;
      Expected : Status_Kind;
      Name     : String)
   is
      Pos    : Index := 1;
      Status : Status_Kind;
   begin
      Skip_Field (Data, Data'Last, 1, Start_Group, Pos, Status);
      Check (Status = Expected, Name);

      if Expected = OK then
         Check (Pos = Data'Last + 1, Name & " consumes the group");
      end if;
   end Group_Test;

   --------------
   -- Key_Test --
   --------------

   procedure Key_Test
     (Data       : Byte_Array;
      Expected   : Status_Kind;
      Expect_Num : Unsigned_32;
      Expect_W   : Wire_Type;
      Name       : String)
   is
      Pos    : Index := 1;
      Number : Unsigned_32;
      Kind   : Wire_Type;
      Status : Status_Kind;
   begin
      Get_Key (Data, Data'Last, Pos, Number, Kind, Status);
      Check (Status = Expected, Name);

      if Expected = OK then
         Check (Number = Expect_Num and Kind = Expect_W, Name & " value");
      end if;
   end Key_Test;

   ---------------
   -- Skip_Test --
   ---------------

   procedure Skip_Test
     (Data       : Byte_Array;
      Wire       : Wire_Type;
      Expect_Pos : Index;
      Expected   : Status_Kind;
      Name       : String)
   is
      Pos    : Index := 1;
      Status : Status_Kind;
   begin
      Skip_Field (Data, Data'Last, 1, Wire, Pos, Status);
      Check (Status = Expected, Name);

      if Expected = OK then
         Check (Pos = Expect_Pos, Name & " position");
      end if;
   end Skip_Test;

   ----------------------
   -- Test_Conversions --
   ----------------------

   procedure Test_Conversions is
   begin
      Check (From_Integer_32 (0) = 0, "int32 zero");
      Check (From_Integer_32 (150) = 150, "int32 positive");
      Check (From_Integer_32 (-1) = Max_U64, "int32 -1");
      Check (From_Integer_32 (-2) = 16#FFFF_FFFF_FFFF_FFFE#, "int32 -2");
      Check (From_Integer_32 (Integer_32'First) = 16#FFFF_FFFF_8000_0000#,
             "int32 first");
      Check (From_Integer_64 (Integer_64'First) = 16#8000_0000_0000_0000#,
             "int64 first");
      Check (From_Integer_64 (Integer_64'Last) = 16#7FFF_FFFF_FFFF_FFFF#,
             "int64 last");

      --  The table from the encoding documentation
      Check (Zigzag_32 (0) = 0, "zigzag 0");
      Check (Zigzag_32 (-1) = 1, "zigzag -1");
      Check (Zigzag_32 (1) = 2, "zigzag 1");
      Check (Zigzag_32 (-2) = 3, "zigzag -2");
      Check (Zigzag_32 (Integer_32'Last) = 16#FFFF_FFFE#, "zigzag last");
      Check (Zigzag_32 (Integer_32'First) = 16#FFFF_FFFF#, "zigzag first");
      Check (Zigzag_64 (Integer_64'Last) = 16#FFFF_FFFF_FFFF_FFFE#,
             "zigzag64 last");
      Check (Zigzag_64 (Integer_64'First) = Max_U64, "zigzag64 first");

      Check (Unzigzag_32 (0) = 0, "unzigzag 0");
      Check (Unzigzag_32 (1) = -1, "unzigzag 1");
      Check (Unzigzag_32 (2) = 1, "unzigzag 2");
      Check (Unzigzag_32 (3) = -2, "unzigzag 3");
      Check (Unzigzag_32 (16#FFFF_FFFE#) = Integer_32'Last, "unzigzag last");
      Check (Unzigzag_32 (16#FFFF_FFFF#) = Integer_32'First, "unzigzag first");
      Check (Unzigzag_32 (16#1_0000_0002#) = 1, "unzigzag keeps low bits");
      Check (Unzigzag_64 (16#FFFF_FFFF_FFFF_FFFE#) = Integer_64'Last,
             "unzigzag64 last");
      Check (Unzigzag_64 (Max_U64) = Integer_64'First, "unzigzag64 first");

      Check (To_Integer_32 (16#FFFF_FFFF_FFFF_FFFE#) = -2, "to int32 -2");
      Check (To_Integer_32 (16#1_0000_0001#) = 1, "to int32 keeps low bits");
      Check (To_Integer_32 (16#8000_0000#) = Integer_32'First,
             "to int32 first");
      Check (To_Integer_32 (16#7FFF_FFFF#) = Integer_32'Last, "to int32 last");
      Check (To_Integer_64 (Max_U64) = -1, "to int64 -1");
      Check (To_Integer_64 (16#8000_0000_0000_0000#) = Integer_64'First,
             "to int64 first");
      Check (To_Unsigned_32 (16#1_0000_0005#) = 5, "to uint32 keeps low bits");
      Check (To_Boolean (2 ** 40), "any non-zero value is true");
      Check (not To_Boolean (0), "zero is false");

      Check (Bits_Of (Integer_32'(-1)) = 16#FFFF_FFFF#, "bits -1");
      Check (Bits_Of (Integer_32'First) = 16#8000_0000#, "bits first");
      Check (Bits_Of (Integer_64'(-2)) = 16#FFFF_FFFF_FFFF_FFFE#, "bits64");
      Check (Signed_Of (Unsigned_32'(16#FFFF_FFFF#)) = -1, "signed -1");
      Check (Signed_Of (Unsigned_32'(16#8000_0000#)) = Integer_32'First,
             "signed first");
      Check (Signed_Of (Unsigned_64'(Max_U64)) = -1, "signed64 -1");
      Check (Signed_Of (Unsigned_64'(16#8000_0000_0000_0000#))
             = Integer_64'First, "signed64 first");
   end Test_Conversions;

   ------------------------
   -- Test_Decode_Errors --
   ------------------------

   procedure Test_Decode_Errors is
      Pos    : Index;
      Inner  : Index;
      Value  : Unsigned_64;
      Fixed  : Unsigned_32;
      Status : Status_Kind;
      Empty  : constant Byte_Array (1 .. 0) := (others => 0);
      Short  : constant Byte_Array := (16#96#, 16#01#);
      Long   : constant Byte_Array :=
        Repeat (16#FF#, 10) & Byte_Array'(1 => 16#01#);
      Ten    : constant Byte_Array :=
        Repeat (16#FF#, 9) & Byte_Array'(1 => 16#01#);
   begin
      Pos := 1;
      Get_Varint (Empty, 0, Pos, Value, Status);
      Check (Status = Truncated and Pos = 1, "empty varint");

      Pos := 1;
      Get_Varint ((1 => 16#80#), 1, Pos, Value, Status);
      Check (Status = Truncated, "unterminated varint");

      Pos := 1;
      Get_Varint (Long, Long'Last, Pos, Value, Status);
      Check (Status = Malformed, "11 byte varint");

      Pos := 1;
      Get_Varint (Ten, Ten'Last, Pos, Value, Status);
      Check (Status = OK and Value = Max_U64 and Pos = 11, "10 byte varint");

      Pos := 1;
      Get_Varint (Short, 1, Pos, Value, Status);
      Check (Status = Truncated and Pos = 2, "varint stops at limit");

      Pos := 2;
      Get_Varint (Byte_Array'(16#FF#, 16#05#), 2, Pos, Value, Status);
      Check (Status = OK and Value = 5 and Pos = 3, "varint from position");

      Key_Test ((1 => 16#08#), OK, 1, Varint, "key field 1");
      Key_Test ((1 => 16#12#), OK, 2, Length_Delimited, "key field 2");
      Key_Test ((1 => 16#00#), Malformed, 0, Varint, "key field 0");
      Key_Test ((1 => 16#0E#), Malformed, 0, Varint, "wire type 6");
      Key_Test ((1 => 16#0F#), Malformed, 0, Varint, "wire type 7");
      Key_Test
        ((16#FD#, 16#FF#, 16#FF#, 16#FF#, 16#0F#),
         OK, 536_870_911, Fixed_32, "largest field number");
      Key_Test
        ((16#80#, 16#80#, 16#80#, 16#80#, 16#10#),
         Malformed, 0, Varint, "field number too large");
      Key_Test ((1 => 16#80#), Truncated, 0, Varint, "unterminated key");

      Pos := 1;
      Get_Delimited ((16#05#, 16#61#), 2, Pos, Inner, Status);
      Check (Status = Truncated, "length past limit");

      Pos := 1;
      Get_Delimited ((16#02#, 16#61#, 16#62#, 16#63#), 4, Pos, Inner, Status);
      Check (Status = OK and Pos = 2 and Inner = 3, "delimited range");

      Pos := 1;
      Get_Delimited ((16#02#, 16#61#, 16#62#), 2, Pos, Inner, Status);
      Check (Status = Truncated, "length checks limit, not buffer");

      Pos := 1;
      Get_Delimited ((1 => 16#00#), 1, Pos, Inner, Status);
      Check (Status = OK and Pos = 2 and Inner = 1, "empty delimited");

      Pos := 1;
      Get_Delimited (Ten, Ten'Last, Pos, Inner, Status);
      Check (Status = Truncated, "huge length");

      Pos := 1;
      Get_Fixed_32 ((16#01#, 16#02#, 16#03#), 3, Pos, Fixed, Status);
      Check (Status = Truncated and Pos = 1, "short fixed32");

      Pos := 1;
      Get_Fixed_64
        ((1, 2, 3, 4, 5, 6, 7), 7, Pos, Value, Status);
      Check (Status = Truncated and Pos = 1, "short fixed64");
   end Test_Decode_Errors;

   --------------------
   -- Test_Delimited --
   --------------------

   procedure Test_Delimited is
      Buffer    : Byte_Array (1 .. 300);
      Last      : Index;
      Body_Last : Index;
   begin
      --  A short body moves back over the unused byte of the prefix
      Buffer := (others => 0);
      Last := 0;
      Reserve_Delimited (2, 200, Buffer, Last, Body_Last);
      Check (Last = 1 and Body_Last = 3, "reserve");
      Buffer (4 .. 6) := Text_ABC;
      Finish_Delimited (200, 6, Buffer, Last);
      Check
        (Same (Buffer, Last, (16#12#, 16#03#, 16#61#, 16#62#, 16#63#)),
         "short body moves");

      --  Nothing moves when the whole prefix is needed
      Buffer := (others => 0);
      Last := 0;
      Reserve_Delimited (1, 200, Buffer, Last, Body_Last);
      Buffer (4 .. 153) := (others => 16#41#);
      Finish_Delimited (200, 153, Buffer, Last);
      Check (Last = 153, "long body size");
      Check (Buffer (1 .. 3) = Byte_Array'(16#0A#, 16#96#, 16#01#),
             "long body prefix");
      Check (Buffer (153) = 16#41#, "long body stays");

      --  An empty body
      Buffer := (others => 0);
      Last := 0;
      Reserve_Delimited (1, 200, Buffer, Last, Body_Last);
      Finish_Delimited (200, Body_Last, Buffer, Last);
      Check (Same (Buffer, Last, (16#0A#, 16#00#)), "empty body");

      --  Earlier content is left alone
      Buffer := (others => 0);
      Last := 0;
      Put_Varint_Field (1, 7, Buffer, Last);
      Reserve_Delimited (2, 200, Buffer, Last, Body_Last);
      Check (Last = 3 and Body_Last = 5, "reserve after a field");
      Buffer (6 .. 6) := (1 => 16#2A#);
      Finish_Delimited (200, 6, Buffer, Last);
      Check
        (Same (Buffer, Last, (16#08#, 16#07#, 16#12#, 16#01#, 16#2A#)),
         "earlier field is kept");
   end Test_Delimited;

   ------------------------------
   -- Test_Documented_Examples --
   ------------------------------

   procedure Test_Documented_Examples is
      Buffer : Byte_Array (1 .. 32) := (others => 0);
      Last   : Index := 0;
      Text   : constant Byte_Array :=
        (16#74#, 16#65#, 16#73#, 16#74#, 16#69#, 16#6E#, 16#67#);
   begin
      Put_Varint_Field (1, 150, Buffer, Last);
      Check (Same (Buffer, Last, (16#08#, 16#96#, 16#01#)), "field 1 = 150");

      Buffer := (others => 0);
      Last := 0;
      Put_Bytes_Field (2, Text, Text'Length, Buffer, Last);
      Check
        (Same (Buffer, Last, Byte_Array'(16#12#, 16#07#) & Text),
         "field 2 = testing");

      Buffer := (others => 0);
      Last := 0;
      Put_Varint (From_Integer_32 (-2), Buffer, Last);
      Check
        (Same (Buffer, Last,
               Byte_Array'(1 => 16#FE#) & Repeat (16#FF#, 8)
               & Byte_Array'(1 => 16#01#)),
         "negative int32 takes 10 bytes");

      --  A packed field with values 3, 270 and 86942 in field 4
      Buffer := (others => 0);
      Last := 0;

      declare
         Body_Last : Index;
      begin
         Reserve_Delimited (4, 30, Buffer, Last, Body_Last);
         Put_Varint (3, Buffer, Body_Last);
         Put_Varint (270, Buffer, Body_Last);
         Put_Varint (86_942, Buffer, Body_Last);
         Finish_Delimited (30, Body_Last, Buffer, Last);
      end;

      Check
        (Same (Buffer, Last,
               (16#22#, 16#06#, 16#03#, 16#8E#, 16#02#, 16#9E#, 16#A7#,
                16#05#)),
         "packed example");
   end Test_Documented_Examples;

   ----------------
   -- Test_Fixed --
   ----------------

   procedure Test_Fixed is
      Buffer : Byte_Array (1 .. 16) := (others => 0);
      Last   : Index := 0;
      Pos    : Index;
      Value  : Unsigned_64;
      Small  : Unsigned_32;
      Status : Status_Kind;
   begin
      Put_Fixed_32_Field (1, 16#1234_5678#, Buffer, Last);
      Check
        (Same (Buffer, Last, (16#0D#, 16#78#, 16#56#, 16#34#, 16#12#)),
         "fixed32 is little endian");
      Pos := 2;
      Get_Fixed_32 (Buffer, Last, Pos, Small, Status);
      Check (Status = OK and Small = 16#1234_5678# and Pos = 6, "get fixed32");

      Buffer := (others => 0);
      Last := 0;
      Put_Fixed_64_Field (1, 16#0102_0304_0506_0708#, Buffer, Last);
      Check
        (Same (Buffer, Last,
               (16#09#, 16#08#, 16#07#, 16#06#, 16#05#, 16#04#, 16#03#,
                16#02#, 16#01#)),
         "fixed64 is little endian");
      Pos := 2;
      Get_Fixed_64 (Buffer, Last, Pos, Value, Status);
      Check (Status = OK and Value = 16#0102_0304_0506_0708# and Pos = 10,
             "get fixed64");

      Buffer := (others => 0);
      Last := 0;
      Put_Fixed_64_Field (1, Max_U64, Buffer, Last);
      Pos := 2;
      Get_Fixed_64 (Buffer, Last, Pos, Value, Status);
      Check (Value = Max_U64, "fixed64 high bits");

      --  Packed values have no tag
      Buffer := (others => 0);
      Last := 0;
      Put_Fixed_32 (16#0A0B_0C0D#, Buffer, Last);
      Put_Fixed_64 (16#0102_0304_0506_0708#, Buffer, Last);
      Check
        (Same (Buffer, Last,
               (16#0D#, 16#0C#, 16#0B#, 16#0A#, 16#08#, 16#07#, 16#06#,
                16#05#, 16#04#, 16#03#, 16#02#, 16#01#)),
         "fixed values without tags");
   end Test_Fixed;

   ----------------
   -- Test_Float --
   ----------------

   procedure Test_Float is
      use PB_SPARK.Float_Bits;
   begin
      Check (To_Bits (IEEE_Float_32'(1.5)) = 16#3FC0_0000#, "float bits");
      Check (To_Bits (IEEE_Float_64'(1.5)) = 16#3FF8_0000_0000_0000#,
             "double bits");
      Check (To_Float_32 (16#3FC0_0000#) = 1.5, "float value");
      Check (To_Float_64 (16#3FF8_0000_0000_0000#) = 1.5, "double value");
      Check (To_Bits (To_Float_32 (16#8000_0000#)) = 16#8000_0000#,
             "float -0.0 keeps its sign");
      Check (Is_Finite (Unsigned_32'(16#3FC0_0000#)), "finite float");
      Check (not Is_Finite (Unsigned_32'(16#7F80_0000#)), "float infinity");
      Check (not Is_Finite (Unsigned_32'(16#FF80_0000#)), "float -infinity");
      Check (not Is_Finite (Unsigned_32'(16#7FC0_0000#)), "float NaN");
      Check (Is_Finite (Unsigned_64'(16#3FF8_0000_0000_0000#)),
             "finite double");
      Check (not Is_Finite (Unsigned_64'(16#7FF0_0000_0000_0000#)),
             "double infinity");
      Check (not Is_Finite (Unsigned_64'(16#7FF8_0000_0000_0000#)),
             "double NaN");
   end Test_Float;

   ------------------
   -- Test_Options --
   ------------------

   procedure Test_Options is
      Buffer : Byte_Array (1 .. 32) := (others => 0);
      Last   : Index := 0;
      Empty  : constant Byte_Array (1 .. 4) := (others => 0);
   begin
      Put_Varint_Option (1, 0, Buffer, Last);
      Put_Fixed_32_Option (2, 0, Buffer, Last);
      Put_Fixed_64_Option (3, 0, Buffer, Last);
      Put_Bytes_Option (4, Empty, 0, Buffer, Last);
      Check (Last = 0, "default values are not written");

      Put_Varint_Option (1, 1, Buffer, Last);
      Check (Same (Buffer, Last, (16#08#, 16#01#)), "varint option");

      Buffer := (others => 0);
      Last := 0;
      Put_Fixed_32_Option (1, 16#8000_0000#, Buffer, Last);
      Check
        (Same (Buffer, Last, (16#0D#, 0, 0, 0, 16#80#)),
         "float -0.0 is written");

      Buffer := (others => 0);
      Last := 0;
      Put_Fixed_64_Option (1, 16#8000_0000_0000_0000#, Buffer, Last);
      Check (Last = 9 and Buffer (9) = 16#80#, "double -0.0 is written");

      Buffer := (others => 0);
      Last := 0;
      Put_Bytes_Option (1, Text_ABC, 2, Buffer, Last);
      Check
        (Same (Buffer, Last, (16#0A#, 16#02#, 16#61#, 16#62#)),
         "bytes option uses length");

      Buffer := (others => 0);
      Last := 0;
      Put_Bytes_Field (1, Empty, 0, Buffer, Last);
      Check (Same (Buffer, Last, (16#0A#, 16#00#)), "empty bytes field");
   end Test_Options;

   ----------------------
   -- Test_Read_Fields --
   ----------------------

   procedure Test_Read_Fields is
      Pos    : Index;
      Value  : Unsigned_64;
      Small  : Unsigned_32;
      Data   : Byte_Array (1 .. 4);
      Length : Index;
      Status : Status_Kind;
      Four   : constant Byte_Array := (1, 2, 3, 4);
   begin
      Pos := 1;
      Value := 9;
      Read_Varint_Field
        ((16#96#, 16#01#), 2, 1, Varint, Pos, Value, Status);
      Check (Status = OK and Value = 150, "read varint");

      Pos := 1;
      Value := 9;
      Read_Varint_Field (Four, 4, 1, Fixed_32, Pos, Value, Status);
      Check (Status = OK and Value = 9 and Pos = 5,
             "other wire type is skipped and keeps the value");

      Pos := 1;
      Value := 9;
      Read_Varint_Field ((1 => 16#80#), 1, 1, Varint, Pos, Value, Status);
      Check (Status = Truncated and Value = 9, "truncation keeps the value");

      Pos := 1;
      Value := 9;
      Read_Varint_Field (Four, 4, 1, End_Group, Pos, Value, Status);
      Check (Status = Malformed, "stray end group");

      Pos := 1;
      Small := 9;
      Read_Fixed_32_Field (Four, 4, 1, Fixed_32, Pos, Small, Status);
      Check (Status = OK and Small = 16#0403_0201#, "read fixed32");

      Pos := 1;
      Small := 9;
      Read_Fixed_32_Field (Four, 4, 1, Fixed_64, Pos, Small, Status);
      Check (Status = Truncated and Small = 9, "fixed32 with other type");

      Pos := 1;
      Value := 9;
      Read_Fixed_64_Field
        ((1, 0, 0, 0, 0, 0, 0, 0), 8, 1, Fixed_64, Pos, Value, Status);
      Check (Status = OK and Value = 1, "read fixed64");

      Pos := 1;
      Length := 0;
      Read_Bytes_Field
        ((16#04#, 16#61#, 16#62#, 16#63#, 16#64#),
         5, 1, Length_Delimited, Pos, Data, Length, Status);
      Check (Status = OK and Length = 4 and Pos = 6, "bytes at capacity");
      Check (Data = Byte_Array'(16#61#, 16#62#, 16#63#, 16#64#),
             "bytes content");

      Pos := 1;
      Length := 3;
      Read_Bytes_Field
        ((16#05#, 1, 2, 3, 4, 5),
         6, 1, Length_Delimited, Pos, Data, Length, Status);
      Check (Status = Limit_Exceeded and Length = 3, "bytes over capacity");

      Pos := 1;
      Length := 3;
      Read_Bytes_Field
        ((1 => 16#00#), 1, 1, Length_Delimited, Pos, Data, Length, Status);
      Check (Status = OK and Length = 0 and Pos = 2, "empty bytes");

      Pos := 1;
      Length := 3;
      Read_Bytes_Field (Four, 4, 1, Fixed_32, Pos, Data, Length, Status);
      Check (Status = OK and Length = 3 and Pos = 5, "bytes other type");

      Pos := 1;
      Length := 0;
      Read_String_Field
        ((16#02#, 16#61#, 16#62#),
         3, 1, Length_Delimited, Pos, Data, Length, Status);
      Check (Status = OK and Length = 2, "valid string");

      Pos := 1;
      Length := 0;
      Read_String_Field
        ((16#01#, 16#FF#),
         2, 1, Length_Delimited, Pos, Data, Length, Status);
      Check (Status = Invalid_UTF8, "invalid string");

      Pos := 1;
      Length := 0;
      Read_String_Field
        ((16#FF#, 16#FF#, 16#FF#, 16#FF#),
         4, 1, Fixed_32, Pos, Data, Length, Status);
      Check (Status = OK and Length = 0, "string with other wire type");
   end Test_Read_Fields;

   ---------------------
   -- Test_Round_Trip --
   ---------------------

   procedure Test_Round_Trip is
      State : Unsigned_64 := 16#9E37_79B9_7F4A_7C15#;

      function Next return Unsigned_64;

      function Next return Unsigned_64 is
      begin
         State := State xor Shift_Left (State, 13);
         State := State xor Shift_Right (State, 7);
         State := State xor Shift_Left (State, 17);
         return State;
      end Next;

      Buffer : Byte_Array (1 .. 32);
   begin
      for J in 1 .. 20_000 loop
         declare
            --  Vary the size of values, because most random numbers are big
            Raw    : constant Unsigned_64 := Next;
            Value  : constant Unsigned_64 := Shift_Right (Raw, J mod 64);
            Last   : Index := 0;
            Pos    : Index := 1;
            Item   : Unsigned_64;
            Status : Status_Kind;
            Signed : constant Integer_64 := Signed_Of (Value);
            Small  : constant Integer_32 := To_Integer_32 (Value);
         begin
            Put_Varint (Value, Buffer, Last);
            Get_Varint (Buffer, Last, Pos, Item, Status);

            if Status /= OK or Item /= Value or Pos /= Last + 1 then
               Check (False, "varint round trip");
            end if;

            if Unzigzag_64 (Zigzag_64 (Signed)) /= Signed
              or Unzigzag_32 (Zigzag_32 (Small)) /= Small
              or To_Integer_32 (From_Integer_32 (Small)) /= Small
              or To_Integer_64 (From_Integer_64 (Signed)) /= Signed
              or Signed_Of (Bits_Of (Signed)) /= Signed
              or Signed_Of (Bits_Of (Small)) /= Small
            then
               Check (False, "conversion round trip");
            end if;
         end;
      end loop;
   end Test_Round_Trip;

   ---------------
   -- Test_Skip --
   ---------------

   procedure Test_Skip is
      Nest_31 : constant Byte_Array :=
        Repeat (16#13#, 31) & Repeat (16#14#, 31) & Byte_Array'(1 => 16#0C#);
      Nest_32 : constant Byte_Array :=
        Repeat (16#13#, 32) & Repeat (16#14#, 32) & Byte_Array'(1 => 16#0C#);
   begin
      Skip_Test ((16#96#, 16#01#), Varint, 3, OK, "skip varint");
      Skip_Test ((1 => 16#80#), Varint, 0, Truncated, "skip short varint");
      Skip_Test ((1, 2, 3, 4, 5, 6, 7, 8), Fixed_64, 9, OK, "skip fixed64");
      Skip_Test ((1, 2, 3, 4, 5, 6, 7), Fixed_64, 0, Truncated,
                 "skip short fixed64");
      Skip_Test ((1, 2, 3, 4), Fixed_32, 5, OK, "skip fixed32");
      Skip_Test ((1, 2, 3), Fixed_32, 0, Truncated, "skip short fixed32");
      Skip_Test ((16#02#, 7, 8), Length_Delimited, 4, OK, "skip bytes");
      Skip_Test ((16#03#, 7, 8), Length_Delimited, 0, Truncated,
                 "skip short bytes");
      Skip_Test ((1 => 0), End_Group, 0, Malformed, "skip end group");

      Group_Test ((16#08#, 16#01#, 16#0C#), OK, "group");
      Group_Test ((1 => 16#0C#), OK, "empty group");
      Group_Test ((16#13#, 16#14#, 16#0C#), OK, "nested group");
      Group_Test
        ((16#15#, 1, 2, 3, 4, 16#11#, 1, 2, 3, 4, 5, 6, 7, 8,
          16#12#, 16#01#, 16#AA#, 16#0C#),
         OK, "group with every kind of field");
      Group_Test ((1 => 16#14#), Malformed, "wrong end group");
      Group_Test ((16#13#, 16#0C#), Malformed, "crossed groups");
      Group_Test ((16#08#, 16#01#), Truncated, "unterminated group");
      Group_Test ((1 .. 0 => 0), Truncated, "empty input group");
      Group_Test ((1 => 16#0E#), Malformed, "bad key in group");
      Group_Test ((16#12#, 16#05#, 16#0C#), Truncated, "bad value in group");
      Group_Test (Nest_31, OK, "deepest group");
      Group_Test (Nest_32, Limit_Exceeded, "group too deep");
   end Test_Skip;

   ---------------
   -- Test_Tags --
   ---------------

   procedure Test_Tags is
   begin
      Check_Tag (1, Varint, (1 => 16#08#), "field 1 varint");
      Check_Tag (2, Length_Delimited, (1 => 16#12#), "field 2 delimited");
      Check_Tag (1, Fixed_64, (1 => 16#09#), "field 1 fixed64");
      Check_Tag (1, Fixed_32, (1 => 16#0D#), "field 1 fixed32");
      Check_Tag (1, Start_Group, (1 => 16#0B#), "field 1 start group");
      Check_Tag (1, End_Group, (1 => 16#0C#), "field 1 end group");
      Check_Tag (15, Varint, (1 => 16#78#), "field 15");
      Check_Tag (16, Varint, (16#80#, 16#01#), "field 16");
      Check_Tag (2_047, Varint, (16#F8#, 16#7F#), "field 2047");
      Check_Tag (2_048, Varint, (16#80#, 16#80#, 16#01#), "field 2048");
      Check_Tag
        (536_870_911, Fixed_32,
         (16#FD#, 16#FF#, 16#FF#, 16#FF#, 16#0F#), "largest field");
   end Test_Tags;

   ---------------
   -- Test_UTF8 --
   ---------------

   procedure Test_UTF8 is
      Data : constant Byte_Array := (16#61#, 16#FF#);
   begin
      Check_UTF8 ((1 .. 0 => 0), True, "empty");
      Check_UTF8 ((16#00#, 16#7F#), True, "ascii");
      Check_UTF8 ((16#C2#, 16#80#), True, "U+0080");
      Check_UTF8 ((16#DF#, 16#BF#), True, "U+07FF");
      Check_UTF8 ((16#E0#, 16#A0#, 16#80#), True, "U+0800");
      Check_UTF8 ((16#ED#, 16#9F#, 16#BF#), True, "U+D7FF");
      Check_UTF8 ((16#EE#, 16#80#, 16#80#), True, "U+E000");
      Check_UTF8 ((16#EF#, 16#BF#, 16#BF#), True, "U+FFFF");
      Check_UTF8 ((16#F0#, 16#90#, 16#80#, 16#80#), True, "U+10000");
      Check_UTF8 ((16#F4#, 16#8F#, 16#BF#, 16#BF#), True, "U+10FFFF");
      Check_UTF8
        ((16#61#, 16#C3#, 16#A4#, 16#E2#, 16#82#, 16#AC#, 16#F0#, 16#9F#,
          16#98#, 16#80#),
         True, "mixed");

      Check_UTF8 ((1 => 16#80#), False, "lone continuation");
      Check_UTF8 ((1 => 16#FF#), False, "FF");
      Check_UTF8 ((16#C0#, 16#80#), False, "overlong C0");
      Check_UTF8 ((16#C1#, 16#BF#), False, "overlong C1");
      Check_UTF8 ((16#E0#, 16#80#, 16#80#), False, "overlong E0 80");
      Check_UTF8 ((16#E0#, 16#9F#, 16#BF#), False, "overlong E0 9F");
      Check_UTF8 ((16#ED#, 16#A0#, 16#80#), False, "surrogate first");
      Check_UTF8 ((16#ED#, 16#BF#, 16#BF#), False, "surrogate last");
      Check_UTF8 ((16#F0#, 16#80#, 16#80#, 16#80#), False, "overlong F0 80");
      Check_UTF8 ((16#F0#, 16#8F#, 16#BF#, 16#BF#), False, "overlong F0 8F");
      Check_UTF8 ((16#F4#, 16#90#, 16#80#, 16#80#), False, "above U+10FFFF");
      Check_UTF8 ((16#F5#, 16#80#, 16#80#, 16#80#), False, "F5");
      Check_UTF8 ((1 => 16#C2#), False, "truncated 2 bytes");
      Check_UTF8 ((16#E2#, 16#82#), False, "truncated 3 bytes");
      Check_UTF8 ((16#F0#, 16#9F#, 16#98#), False, "truncated 4 bytes");
      Check_UTF8 ((16#C2#, 16#41#), False, "bad second byte");
      Check_UTF8 ((16#E2#, 16#82#, 16#41#), False, "bad third byte");
      Check_UTF8 ((16#F0#, 16#9F#, 16#98#, 16#41#), False, "bad fourth byte");

      Check (UTF8.Is_Valid (Data, 1), "bytes after Length are not checked");
      Check (not UTF8.Is_Valid (Data, 2), "bytes up to Length are checked");
   end Test_UTF8;

   ------------------
   -- Test_Varints --
   ------------------

   procedure Test_Varints is
   begin
      Check_Varint (0, (1 => 16#00#), "0");
      Check_Varint (1, (1 => 16#01#), "1");
      Check_Varint (127, (1 => 16#7F#), "127");
      Check_Varint (128, (16#80#, 16#01#), "128");
      Check_Varint (150, (16#96#, 16#01#), "150");
      Check_Varint (300, (16#AC#, 16#02#), "300");
      Check_Varint (16_383, (16#FF#, 16#7F#), "16383");
      Check_Varint (16_384, (16#80#, 16#80#, 16#01#), "16384");
      Check_Varint
        (2 ** 63 - 1, Repeat (16#FF#, 8) & Byte_Array'(1 => 16#7F#),
         "2**63-1");
      Check_Varint
        (2 ** 63, Repeat (16#80#, 9) & Byte_Array'(1 => 16#01#), "2**63");
      Check_Varint
        (Max_U64, Repeat (16#FF#, 9) & Byte_Array'(1 => 16#01#), "maximum");
   end Test_Varints;

begin
   Test_Varints;
   Test_Tags;
   Test_Documented_Examples;
   Test_Conversions;
   Test_Fixed;
   Test_Options;
   Test_Delimited;
   Test_Decode_Errors;
   Test_Skip;
   Test_Read_Fields;
   Test_UTF8;
   Test_Float;
   Test_Round_Trip;

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("SPARK runtime tests OK");
   else
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end PB_SPARK_Test;

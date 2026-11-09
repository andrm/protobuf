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

with PB_SPARK.UTF8;

package body PB_SPARK.Wire with SPARK_Mode is

   procedure Advance
     (Limit  : Index;
      Count  : Index;
      Pos    : in out Index;
      Status : out Status_Kind)
     with Pre  => Pos in 1 .. Limit + 1 and then Limit <= Buffer_Last'Last,
          Post => Pos in Pos'Old .. Limit + 1;

   procedure Get_Bytes_Value
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Data   : in out Byte_Array;
      Length : in out Index;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos)
                  and then Valid_Buffer (Data)
                  and then Length <= Data'Last,
          Post => Pos in Pos'Old .. Limit + 1
                  and then Length <= Data'Last;

   procedure Skip_Group
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Pos    : in out Index;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos),
          Post => Pos in Pos'Old .. Limit + 1;

   procedure Skip_Value
     (Buffer : Byte_Array;
      Limit  : Index;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Status : out Status_Kind)
     with Pre  => Valid_Reader (Buffer, Limit, Pos)
                  and then Wire in Varint | Fixed_64 | Length_Delimited
                                 | Fixed_32,
          Post => Pos in Pos'Old .. Limit + 1;

   -------------
   -- Advance --
   -------------

   procedure Advance
     (Limit  : Index;
      Count  : Index;
      Pos    : in out Index;
      Status : out Status_Kind) is
   begin
      if Limit + 1 - Pos < Count then
         Status := Truncated;
      else
         Pos := Pos + Count;
         Status := OK;
      end if;
   end Advance;

   -------------
   -- Bits_Of --
   -------------

   function Bits_Of (Value : Integer_32) return Unsigned_32 is
     (if Value >= 0 then Unsigned_32 (Value)
      else Unsigned_32'Last - Unsigned_32 (-(Value + 1)));

   function Bits_Of (Value : Integer_64) return Unsigned_64 is
     (From_Integer_64 (Value));

   ----------------------
   -- Finish_Delimited --
   ----------------------

   procedure Finish_Delimited
     (Max_Body  : Buffer_Last;
      Body_Last : Index;
      Buffer    : in out Byte_Array;
      Last      : in out Index)
   is
      Body_First : constant Index := Last + Length_Size (Max_Body) + 1;
      Length     : constant Index := Body_Last - (Body_First - 1);
   begin
      Put_Varint (Unsigned_64 (Length), Buffer, Last);

      if Last + 1 /= Body_First and then Length > 0 then
         Buffer (Last + 1 .. Last + Length) :=
           Buffer (Body_First .. Body_Last);
      end if;

      Last := Last + Length;
   end Finish_Delimited;

   ---------------------
   -- Get_Bytes_Value --
   ---------------------

   procedure Get_Bytes_Value
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Data   : in out Byte_Array;
      Length : in out Index;
      Status : out Status_Kind)
   is
      Inner : Index;
      Count : Index;
   begin
      Get_Delimited (Buffer, Limit, Pos, Inner, Status);

      if Status /= OK then
         return;
      end if;

      Count := Inner + 1 - Pos;

      if Count > Data'Last then
         Status := Limit_Exceeded;
         return;
      end if;

      Data (1 .. Count) := Buffer (Pos .. Inner);
      Length := Count;
      Pos := Inner + 1;
   end Get_Bytes_Value;

   -------------------
   -- Get_Delimited --
   -------------------

   procedure Get_Delimited
     (Buffer      : Byte_Array;
      Limit       : Index;
      Pos         : in out Index;
      Inner_Limit : out Index;
      Status      : out Status_Kind)
   is
      Value : Unsigned_64;
   begin
      Get_Varint (Buffer, Limit, Pos, Value, Status);
      Inner_Limit := Pos - 1;

      if Status = OK then
         if Value > Unsigned_64 (Limit + 1 - Pos) then
            Status := Truncated;
         else
            Inner_Limit := Pos - 1 + Index (Value);
         end if;
      end if;
   end Get_Delimited;

   ------------------
   -- Get_Fixed_32 --
   ------------------

   procedure Get_Fixed_32
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Value  : out Unsigned_32;
      Status : out Status_Kind) is
   begin
      Value := 0;

      if Limit + 1 - Pos < 4 then
         Status := Truncated;
         return;
      end if;

      for J in Index range 0 .. 3 loop
         pragma Loop_Invariant (Pos + 3 <= Limit);
         Value := Value
           or Shift_Left (Unsigned_32 (Buffer (Pos + J)), Natural (J) * 8);
      end loop;

      Pos := Pos + 4;
      Status := OK;
   end Get_Fixed_32;

   ------------------
   -- Get_Fixed_64 --
   ------------------

   procedure Get_Fixed_64
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Value  : out Unsigned_64;
      Status : out Status_Kind) is
   begin
      Value := 0;

      if Limit + 1 - Pos < 8 then
         Status := Truncated;
         return;
      end if;

      for J in Index range 0 .. 7 loop
         pragma Loop_Invariant (Pos + 7 <= Limit);
         Value := Value
           or Shift_Left (Unsigned_64 (Buffer (Pos + J)), Natural (J) * 8);
      end loop;

      Pos := Pos + 8;
      Status := OK;
   end Get_Fixed_64;

   -------------
   -- Get_Key --
   -------------

   procedure Get_Key
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Field  : out Unsigned_32;
      Wire   : out Wire_Type;
      Status : out Status_Kind)
   is
      Value  : Unsigned_64;
      Number : Unsigned_64;
      Kind   : Unsigned_64;
   begin
      Field := 0;
      Wire := Varint;
      Get_Varint (Buffer, Limit, Pos, Value, Status);

      if Status /= OK then
         return;
      end if;

      Number := Shift_Right (Value, 3);
      Kind := Value and 7;

      if Number not in 1 .. Unsigned_64 (Field_Number'Last) or else Kind > 5
      then
         Status := Malformed;
         return;
      end if;

      Field := Unsigned_32 (Number);
      Wire := Wire_Type'Val (Kind);
   end Get_Key;

   ----------------
   -- Get_Varint --
   ----------------

   procedure Get_Varint
     (Buffer : Byte_Array;
      Limit  : Index;
      Pos    : in out Index;
      Value  : out Unsigned_64;
      Status : out Status_Kind)
   is
      Start : constant Index := Pos with Ghost;
      Item  : Unsigned_64;
   begin
      Value := 0;

      for J in 0 .. 9 loop
         pragma Loop_Invariant (Pos = Start + Index (J));
         pragma Loop_Invariant (Pos in 1 .. Limit + 1);

         if Pos > Limit then
            Status := Truncated;
            return;
         end if;

         Item := Unsigned_64 (Buffer (Pos));
         Pos := Pos + 1;
         Value := Value or Shift_Left (Item and 127, 7 * J);

         if Item < 128 then
            Status := OK;
            return;
         end if;
      end loop;

      Status := Malformed;
   end Get_Varint;

   -------------
   -- Put_Tag --
   -------------

   procedure Put_Tag
     (Field  : Field_Number;
      Wire   : Wire_Type;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      Put_Varint
        (Unsigned_64 (Field) * 8 + Unsigned_64 (Wire_Type'Pos (Wire)),
         Buffer,
         Last);
   end Put_Tag;

   ---------------------
   -- Put_Bytes_Field --
   ---------------------

   procedure Put_Bytes_Field
     (Field  : Field_Number;
      Data   : Byte_Array;
      Length : Index;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      Put_Tag (Field, Length_Delimited, Buffer, Last);
      Put_Varint (Unsigned_64 (Length), Buffer, Last);

      if Length > 0 then
         Buffer (Last + 1 .. Last + Length) := Data (1 .. Length);
         Last := Last + Length;
      end if;
   end Put_Bytes_Field;

   ----------------------
   -- Put_Bytes_Option --
   ----------------------

   procedure Put_Bytes_Option
     (Field  : Field_Number;
      Data   : Byte_Array;
      Length : Index;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      if Length > 0 then
         Put_Bytes_Field (Field, Data, Length, Buffer, Last);
      end if;
   end Put_Bytes_Option;

   ------------------------
   -- Put_Fixed_32_Field --
   ------------------------

   procedure Put_Fixed_32_Field
     (Field  : Field_Number;
      Value  : Unsigned_32;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      Put_Tag (Field, Fixed_32, Buffer, Last);

      for J in Index range 1 .. 4 loop
         Buffer (Last + J) :=
           Byte (Shift_Right (Value, (Natural (J) - 1) * 8) and 255);
      end loop;

      Last := Last + 4;
   end Put_Fixed_32_Field;

   -------------------------
   -- Put_Fixed_32_Option --
   -------------------------

   procedure Put_Fixed_32_Option
     (Field  : Field_Number;
      Value  : Unsigned_32;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      if Value /= 0 then
         Put_Fixed_32_Field (Field, Value, Buffer, Last);
      end if;
   end Put_Fixed_32_Option;

   ------------------------
   -- Put_Fixed_64_Field --
   ------------------------

   procedure Put_Fixed_64_Field
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      Put_Tag (Field, Fixed_64, Buffer, Last);

      for J in Index range 1 .. 8 loop
         Buffer (Last + J) :=
           Byte (Shift_Right (Value, (Natural (J) - 1) * 8) and 255);
      end loop;

      Last := Last + 8;
   end Put_Fixed_64_Field;

   -------------------------
   -- Put_Fixed_64_Option --
   -------------------------

   procedure Put_Fixed_64_Option
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      if Value /= 0 then
         Put_Fixed_64_Field (Field, Value, Buffer, Last);
      end if;
   end Put_Fixed_64_Option;

   ----------------
   -- Put_Varint --
   ----------------

   procedure Put_Varint
     (Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index)
   is
      Size : constant Varint_Length := Varint_Size (Value);
      Rest : Unsigned_64 := Value;
   begin
      for J in 1 .. Size - 1 loop
         Buffer (Last + J) := Byte ((Rest and 127) or 128);
         Rest := Shift_Right (Rest, 7);
      end loop;

      Buffer (Last + Size) := Byte (Rest and 127);
      Last := Last + Size;
   end Put_Varint;

   ----------------------
   -- Put_Varint_Field --
   ----------------------

   procedure Put_Varint_Field
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      Put_Tag (Field, Varint, Buffer, Last);
      Put_Varint (Value, Buffer, Last);
   end Put_Varint_Field;

   -----------------------
   -- Put_Varint_Option --
   -----------------------

   procedure Put_Varint_Option
     (Field  : Field_Number;
      Value  : Unsigned_64;
      Buffer : in out Byte_Array;
      Last   : in out Index) is
   begin
      if Value /= 0 then
         Put_Varint_Field (Field, Value, Buffer, Last);
      end if;
   end Put_Varint_Option;

   ----------------------
   -- Read_Bytes_Field --
   ----------------------

   procedure Read_Bytes_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Data   : in out Byte_Array;
      Length : in out Index;
      Status : out Status_Kind) is
   begin
      if Wire = Length_Delimited then
         Get_Bytes_Value (Buffer, Limit, Pos, Data, Length, Status);
      else
         Skip_Field (Buffer, Limit, Field, Wire, Pos, Status);
      end if;
   end Read_Bytes_Field;

   -------------------------
   -- Read_Fixed_32_Field --
   -------------------------

   procedure Read_Fixed_32_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Value  : in out Unsigned_32;
      Status : out Status_Kind) is
   begin
      if Wire = Fixed_32 then
         Get_Fixed_32 (Buffer, Limit, Pos, Value, Status);
      else
         Skip_Field (Buffer, Limit, Field, Wire, Pos, Status);
      end if;
   end Read_Fixed_32_Field;

   -------------------------
   -- Read_Fixed_64_Field --
   -------------------------

   procedure Read_Fixed_64_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Value  : in out Unsigned_64;
      Status : out Status_Kind) is
   begin
      if Wire = Fixed_64 then
         Get_Fixed_64 (Buffer, Limit, Pos, Value, Status);
      else
         Skip_Field (Buffer, Limit, Field, Wire, Pos, Status);
      end if;
   end Read_Fixed_64_Field;

   -----------------------
   -- Read_String_Field --
   -----------------------

   procedure Read_String_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Data   : in out Byte_Array;
      Length : in out Index;
      Status : out Status_Kind) is
   begin
      Read_Bytes_Field
        (Buffer, Limit, Field, Wire, Pos, Data, Length, Status);

      if Status = OK
        and then Wire = Length_Delimited
        and then not PB_SPARK.UTF8.Is_Valid (Data, Length)
      then
         Status := Invalid_UTF8;
      end if;
   end Read_String_Field;

   -----------------------
   -- Read_Varint_Field --
   -----------------------

   procedure Read_Varint_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Value  : in out Unsigned_64;
      Status : out Status_Kind) is
   begin
      if Wire = Varint then
         declare
            Item : Unsigned_64;
         begin
            Get_Varint (Buffer, Limit, Pos, Item, Status);

            if Status = OK then
               Value := Item;
            end if;
         end;
      else
         Skip_Field (Buffer, Limit, Field, Wire, Pos, Status);
      end if;
   end Read_Varint_Field;

   -----------------------
   -- Reserve_Delimited --
   -----------------------

   procedure Reserve_Delimited
     (Field     : Field_Number;
      Max_Body  : Buffer_Last;
      Buffer    : in out Byte_Array;
      Last      : in out Index;
      Body_Last : out Index) is
   begin
      Put_Tag (Field, Length_Delimited, Buffer, Last);
      Body_Last := Last + Length_Size (Max_Body);
   end Reserve_Delimited;

   ---------------
   -- Signed_Of --
   ---------------

   function Signed_Of (Bits : Unsigned_32) return Integer_32 is
     (if Bits < 2 ** 31 then Integer_32 (Bits)
      else -Integer_32 (Unsigned_32'Last - Bits) - 1);

   function Signed_Of (Bits : Unsigned_64) return Integer_64 is
     (if Bits < 2 ** 63 then Integer_64 (Bits)
      else -Integer_64 (Unsigned_64'Last - Bits) - 1);

   ----------------
   -- Skip_Field --
   ----------------

   procedure Skip_Field
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Status : out Status_Kind) is
   begin
      case Wire is
         when Start_Group =>
            Skip_Group (Buffer, Limit, Field, Pos, Status);
         when End_Group =>
            Status := Malformed;
         when Varint | Fixed_64 | Length_Delimited | Fixed_32 =>
            Skip_Value (Buffer, Limit, Wire, Pos, Status);
      end case;
   end Skip_Field;

   ----------------
   -- Skip_Group --
   ----------------

   procedure Skip_Group
     (Buffer : Byte_Array;
      Limit  : Index;
      Field  : Unsigned_32;
      Pos    : in out Index;
      Status : out Status_Kind)
   is
      subtype Depth_Range is Natural range 1 .. Max_Group_Depth;
      Open  : array (Depth_Range) of Unsigned_32 := (others => 0);
      Depth : Depth_Range := 1;
      Inner : Unsigned_32;
      Wire  : Wire_Type;
   begin
      Open (1) := Field;
      Status := Truncated;

      while Pos <= Limit loop
         pragma Loop_Invariant (Pos in Pos'Loop_Entry .. Limit);
         pragma Loop_Variant (Increases => Pos);

         Get_Key (Buffer, Limit, Pos, Inner, Wire, Status);

         if Status /= OK then
            return;
         end if;

         case Wire is
            when End_Group =>
               if Inner /= Open (Depth) then
                  Status := Malformed;
                  return;
               elsif Depth = 1 then
                  return;
               end if;

               Depth := Depth - 1;

            when Start_Group =>
               if Depth = Max_Group_Depth then
                  Status := Limit_Exceeded;
                  return;
               end if;

               Depth := Depth + 1;
               Open (Depth) := Inner;

            when Varint | Fixed_64 | Length_Delimited | Fixed_32 =>
               Skip_Value (Buffer, Limit, Wire, Pos, Status);

               if Status /= OK then
                  return;
               end if;
         end case;

         Status := Truncated;
      end loop;
   end Skip_Group;

   ----------------
   -- Skip_Value --
   ----------------

   procedure Skip_Value
     (Buffer : Byte_Array;
      Limit  : Index;
      Wire   : Wire_Type;
      Pos    : in out Index;
      Status : out Status_Kind)
   is
      Value : Unsigned_64;
      Inner : Index;
   begin
      case Wire is
         when Varint =>
            pragma Warnings
              (GNATprove, Off, "*is set by*but not used after the call",
               Reason => "Skipping a varint only needs its new position");
            Get_Varint (Buffer, Limit, Pos, Value, Status);
            pragma Warnings
              (GNATprove, On, "*is set by*but not used after the call");
         when Fixed_64 =>
            Advance (Limit, 8, Pos, Status);
         when Fixed_32 =>
            Advance (Limit, 4, Pos, Status);
         when Length_Delimited =>
            Get_Delimited (Buffer, Limit, Pos, Inner, Status);

            if Status = OK then
               Pos := Inner + 1;
            end if;
         when Start_Group | End_Group =>
            Status := Malformed;  --  Excluded by the precondition
      end case;
   end Skip_Value;

   -------------------
   -- To_Integer_32 --
   -------------------

   function To_Integer_32 (Value : Unsigned_64) return Integer_32 is
     (Signed_Of (To_Unsigned_32 (Value)));

   -------------------
   -- To_Integer_64 --
   -------------------

   function To_Integer_64 (Value : Unsigned_64) return Integer_64 is
     (Signed_Of (Value));

   -----------------
   -- Unzigzag_32 --
   -----------------

   function Unzigzag_32 (Value : Unsigned_64) return Integer_32 is
      Low  : constant Unsigned_64 := Value and 16#FFFF_FFFF#;
      Half : constant Unsigned_64 := Shift_Right (Low, 1);
   begin
      pragma Assert (Half <= 2 ** 31 - 1);

      if (Low and 1) = 0 then
         return Integer_32 (Half);
      else
         return -Integer_32 (Half) - 1;
      end if;
   end Unzigzag_32;

   -----------------
   -- Unzigzag_64 --
   -----------------

   function Unzigzag_64 (Value : Unsigned_64) return Integer_64 is
      Half : constant Unsigned_64 := Shift_Right (Value, 1);
   begin
      pragma Assert (Half <= 2 ** 63 - 1);

      if (Value and 1) = 0 then
         return Integer_64 (Half);
      else
         return -Integer_64 (Half) - 1;
      end if;
   end Unzigzag_64;

end PB_SPARK.Wire;

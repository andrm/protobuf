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

with Compiler.Context;

package body Compiler.SPARK_Fields is

   use all type Google.Protobuf.Descriptor.Label;
   use all type Google.Protobuf.Descriptor.PB_Type;
   use type League.Strings.Universal_String;

   subtype Field_Descriptor is
     Google.Protobuf.Descriptor.Field_Descriptor_Proto;
   subtype Universal_String is League.Strings.Universal_String;

   F : Ada_Pretty.Factory renames Compiler.Context.Factory;

   Wire : constant Wide_Wide_String := "PB_SPARK.Wire.";

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   function Call
     (Name      : Universal_String;
      Arguments : League.String_Vectors.Universal_String_Vector)
      return Ada_Pretty.Node_Access;
   --  Return a procedure call statement

   function Component_Name (Item : Field_Descriptor) return Universal_String
     is (Compiler.Context.To_Ada_Name (Item.Name.Value));

   function Formal_Name (Item : Field_Descriptor) return Universal_String
     is ("F_" & Component_Name (Item));
   --  The prefix keeps fields from clashing with other parameters

   function Number (Item : Field_Descriptor) return Universal_String;
   --  Return the field number as text

   function Is_Fixed_32 (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in TYPE_FIXED32 | TYPE_SFIXED32 | TYPE_FLOAT);

   function Is_Fixed_64 (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in TYPE_FIXED64 | TYPE_SFIXED64 | TYPE_DOUBLE);

   function Is_Direct (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in
        TYPE_UINT64 | TYPE_FIXED32 | TYPE_FLOAT | TYPE_FIXED64 | TYPE_DOUBLE);
   --  Return True if the component has the same type as the wire value

   function Type_Text (Item : Field_Descriptor) return Universal_String;

   function To_Wire
     (Item  : Field_Descriptor;
      Value : Universal_String) return Universal_String;
   --  Convert a component to the type used to encode it

   function From_Wire
     (Item  : Field_Descriptor;
      Value : Universal_String) return Universal_String;
   --  Convert a decoded value to the type of the component

   ------------
   -- Actual --
   ------------

   function Actual (Item : Field_Descriptor) return Ada_Pretty.Node_Access is
     (F.New_Argument_Association
        (F.New_Selected_Name ("V." & Component_Name (Item))));

   ----------
   -- Call --
   ----------

   function Call
     (Name      : Universal_String;
      Arguments : League.String_Vectors.Universal_String_Vector)
      return Ada_Pretty.Node_Access
   is
      List : Ada_Pretty.Node_Access;
   begin
      for J in 1 .. Arguments.Length loop
         List := F.New_List
           (List, F.New_Argument_Association (F.New_Name (Arguments (J))));
      end loop;

      return F.New_Statement (F.New_Apply (F.New_Selected_Name (Name), List));
   end Call;

   ---------------------
   -- Check_Supported --
   ---------------------

   procedure Check_Supported
     (Item       : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Full_Name  : League.Strings.Universal_String;
      Is_Proto_3 : Boolean;
      Errors     : in out League.String_Vectors.Universal_String_Vector)
   is
      procedure Report (Kind : Wide_Wide_String);

      procedure Report (Kind : Wide_Wide_String) is
      begin
         Errors.Append
           (Full_Name & ": " & Kind
            & " are not supported by the SPARK back end yet");
      end Report;

   begin
      if Item.Label.Is_Set and then Item.Label.Value = LABEL_REPEATED then
         Report ("repeated fields");
      elsif Item.Label.Is_Set and then Item.Label.Value = LABEL_REQUIRED then
         Report ("required fields");
      elsif Item.Oneof_Index.Is_Set then
         Report ("oneof and optional fields");
      elsif not Is_Proto_3 then
         Report ("proto2 optional fields");
      elsif Item.PB_Type.Value in TYPE_STRING | TYPE_BYTES then
         Report ("string and bytes fields");
      elsif Item.PB_Type.Value in TYPE_MESSAGE | TYPE_GROUP then
         Report ("message fields");
      elsif Item.PB_Type.Value = TYPE_ENUM then
         Report ("enum fields");
      end if;
   end Check_Supported;

   -----------
   -- Clear --
   -----------

   function Clear (Item : Field_Descriptor) return Ada_Pretty.Node_Access is
     (F.New_Assignment
        (F.New_Selected_Name ("V." & Component_Name (Item)),
         F.New_Name
           (if Item.PB_Type.Value = TYPE_BOOL then +"False" else +"0")));

   ---------------
   -- Component --
   ---------------

   function Component
     (Item : Field_Descriptor) return Ada_Pretty.Node_Access is
     (F.New_Variable
        (Name            => F.New_Name (Component_Name (Item)),
         Type_Definition => F.New_Selected_Name (Type_Text (Item)),
         Initialization  => F.New_Name
           (if Item.PB_Type.Value = TYPE_BOOL then +"False" else +"0")));

   ------------
   -- Encode --
   ------------

   function Encode (Item : Field_Descriptor) return Ada_Pretty.Node_Access is
      Name      : constant Wide_Wide_String :=
        (if Is_Fixed_32 (Item) then "Put_Fixed_32_Option"
         elsif Is_Fixed_64 (Item) then "Put_Fixed_64_Option"
         else "Put_Varint_Option");
      Arguments : League.String_Vectors.Universal_String_Vector;
   begin
      Arguments.Append (Number (Item));
      Arguments.Append (To_Wire (Item, Formal_Name (Item)));
      Arguments.Append (+"Buffer");
      Arguments.Append (+"Last");
      return Call (+Wire & Name, Arguments);
   end Encode;

   ---------------
   -- From_Wire --
   ---------------

   function From_Wire
     (Item  : Field_Descriptor;
      Value : Universal_String) return Universal_String
   is
      Name : constant Wide_Wide_String :=
        (case Item.PB_Type.Value is
            when TYPE_INT32               => "To_Integer_32",
            when TYPE_INT64               => "To_Integer_64",
            when TYPE_UINT32              => "To_Unsigned_32",
            when TYPE_SINT32              => "Unzigzag_32",
            when TYPE_SINT64              => "Unzigzag_64",
            when TYPE_BOOL                => "To_Boolean",
            when TYPE_SFIXED32 | TYPE_SFIXED64 => "Signed_Of",
            when others                   => "");
   begin
      if Name = "" then
         return Value;
      else
         return +Wire & Name & " (" & Value & ")";
      end if;
   end From_Wire;

   -----------
   -- Merge --
   -----------

   function Merge (Item : Field_Descriptor) return Ada_Pretty.Node_Access is
      Formal : constant Universal_String := "V." & Component_Name (Item);
      Target : constant Universal_String :=
        (if Is_Direct (Item) then Formal else +"Raw");
      Name   : constant Wide_Wide_String :=
        (if Is_Fixed_32 (Item) then "Read_Fixed_32_Field"
         elsif Is_Fixed_64 (Item) then "Read_Fixed_64_Field"
         else "Read_Varint_Field");
      Arguments : League.String_Vectors.Universal_String_Vector;
   begin
      Arguments.Append (+"Buffer");
      Arguments.Append (+"Limit");
      Arguments.Append (+"Field");
      Arguments.Append (+"Wire");
      Arguments.Append (+"Pos");
      Arguments.Append (Target);
      Arguments.Append (+"Status");

      if Is_Direct (Item) then
         return Call (+Wire & Name, Arguments);
      end if;

      --  Raw starts as the current value, so if the field is skipped because
      --  it has another wire type then the component is left as it was.
      return F.New_Block
        (Declarations => F.New_Variable
           (Name            => F.New_Name (+"Raw"),
            Type_Definition => F.New_Selected_Name
              (if Is_Fixed_32 (Item) then +"Interfaces.Unsigned_32"
               else +"Interfaces.Unsigned_64"),
            Initialization  => F.New_Name (To_Wire (Item, Formal))),
         Statements   => F.New_List
           (Call (+Wire & Name, Arguments),
            F.New_Assignment
              (F.New_Selected_Name (Formal),
               F.New_Name (From_Wire (Item, +"Raw")))));
   end Merge;

   ------------
   -- Number --
   ------------

   function Number (Item : Field_Descriptor) return Universal_String is
      Text : constant Wide_Wide_String :=
        Integer'Wide_Wide_Image (Integer (Item.Number.Value));
   begin
      return +Text (Text'First + 1 .. Text'Last);
   end Number;

   ---------------
   -- Parameter --
   ---------------

   function Parameter
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access is
     (F.New_Parameter
        (Name            => F.New_Name (Formal_Name (Item)),
         Type_Definition => F.New_Selected_Name (Type_Text (Item))));

   -------------
   -- To_Wire --
   -------------

   function To_Wire
     (Item  : Field_Descriptor;
      Value : Universal_String) return Universal_String is
   begin
      case Item.PB_Type.Value is
         when TYPE_INT32 =>
            return +Wire & "From_Integer_32 (" & Value & ")";
         when TYPE_INT64 =>
            return +Wire & "From_Integer_64 (" & Value & ")";
         when TYPE_UINT32 =>
            return "Interfaces.Unsigned_64 (" & Value & ")";
         when TYPE_SINT32 =>
            return +Wire & "Zigzag_32 (" & Value & ")";
         when TYPE_SINT64 =>
            return +Wire & "Zigzag_64 (" & Value & ")";
         when TYPE_BOOL =>
            return "(if " & Value & " then 1 else 0)";
         when TYPE_SFIXED32 | TYPE_SFIXED64 =>
            return +Wire & "Bits_Of (" & Value & ")";
         when others =>
            return Value;
      end case;
   end To_Wire;

   ---------------
   -- Type_Text --
   ---------------

   function Type_Text (Item : Field_Descriptor) return Universal_String is
   begin
      case Item.PB_Type.Value is
         when TYPE_INT32 | TYPE_SINT32 | TYPE_SFIXED32 =>
            return +"Interfaces.Integer_32";
         when TYPE_INT64 | TYPE_SINT64 | TYPE_SFIXED64 =>
            return +"Interfaces.Integer_64";
         when TYPE_UINT32 | TYPE_FIXED32 =>
            return +"Interfaces.Unsigned_32";
         when TYPE_UINT64 | TYPE_FIXED64 =>
            return +"Interfaces.Unsigned_64";
         when TYPE_FLOAT =>
            return +"PB_SPARK.Float_32_Bits";
         when TYPE_DOUBLE =>
            return +"PB_SPARK.Float_64_Bits";
         when TYPE_BOOL =>
            return +"Boolean";
         when others =>
            raise Program_Error;  --  Rejected by Check_Supported
      end case;
   end Type_Text;

end Compiler.SPARK_Fields;

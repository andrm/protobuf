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

with Ada.Containers.Hashed_Maps;
with Ada.Unchecked_Conversion;

with Interfaces;

with League.Strings.Hash;

with Compiler.Context;
with Compiler.Field_Descriptors;
with Compiler.Options;
with Compiler.SPARK_Enums;

package body Compiler.SPARK_Fields is

   use all type Google.Protobuf.Descriptor.Label;
   use all type Google.Protobuf.Descriptor.PB_Type;
   use type Ada_Pretty.Node_Access;
   use type Compiler.Options.Unknown_Enum_Policy;
   use type League.Strings.Universal_String;

   subtype Field_Descriptor is
     Google.Protobuf.Descriptor.Field_Descriptor_Proto;
   subtype Universal_String is League.Strings.Universal_String;
   subtype String_Vector is League.String_Vectors.Universal_String_Vector;
   subtype Node is Ada_Pretty.Node_Access;

   F : Ada_Pretty.Factory renames Compiler.Context.Factory;

   Wire : constant Wide_Wide_String := "PB_SPARK.Wire.";

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   function N (Text : Universal_String) return Node is (F.New_Name (Text));

   function N (Text : Wide_Wide_String) return Node is (N (+Text));

   function Join (Head, Tail : Node) return Node is
     (if Tail = null then Head else F.New_List (Head, Tail));
   --  Like F.New_List, which needs a Tail

   type Message_Info is record
      Descriptor : Google.Protobuf.Descriptor.Descriptor_Proto;
      Full_Name  : Universal_String;  --  Like my.pkg.Message
   end record;

   package Message_Maps is new Ada.Containers.Hashed_Maps
     (Universal_String,
      Message_Info,
      League.Strings.Hash,
      League.Strings."=");

   Messages : Message_Maps.Map;

   Package_Names : Compiler.Context.String_Sets.Set;
   --  Names declared by the package being generated, in lower case

   function Expanded
     (Full_Name : Universal_String;
      Ctx       : Context) return Universal_String;
   --  Return how to write the name of an entity of a package, so that the
   --  package being generated doesn't hide it

   function Call
     (Name      : Universal_String;
      Arguments : Universal_String) return Node;
   --  Return a procedure call statement. Arguments are separated by "|".

   function Image (Value : Natural) return Universal_String;

   function Number (Item : Field_Descriptor) return Universal_String is
     (Image (Natural (Item.Number.Value)));

   ------------------------------
   -- Names of the Ada entities --
   ------------------------------

   function Component_Name (Item : Field_Descriptor) return Universal_String
     is (Compiler.Context.To_Ada_Name (Item.Name.Value));

   function Has_Name (Item : Field_Descriptor) return Universal_String is
     ("Has_" & Component_Name (Item));

   function Count_Name (Item : Field_Descriptor) return Universal_String is
     (Component_Name (Item) & "_Count");

   function Formal (Name : Universal_String) return Universal_String is
     ("F_" & Name);
   --  The prefix keeps fields from clashing with other parameters

   function Literal (Item : Field_Descriptor) return Universal_String is
     (Component_Name (Item) & "_Kind");
   --  The literal that tells that a field of a oneof is set

   function Not_Set (Self : Item) return Universal_String is
     (Self.Name & "_Not_Set");

   function Kind_Type (Self : Item; Ctx : Context) return Universal_String is
     (Ctx.Type_Name & "_" & Self.Name & "_Kind");

   function Variant_Type (Self : Item; Ctx : Context) return Universal_String
     is (Ctx.Type_Name & "_" & Self.Name & "_Variant");

   --------------------
   -- Kinds of fields --
   --------------------

   function Is_Required (Item : Field_Descriptor) return Boolean is
     (Item.Label.Is_Set and then Item.Label.Value = LABEL_REQUIRED);

   function Is_Repeated (Item : Field_Descriptor) return Boolean is
     (Item.Label.Is_Set and then Item.Label.Value = LABEL_REPEATED);

   function Is_Message (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value = TYPE_MESSAGE);

   function Is_Text (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in TYPE_STRING | TYPE_BYTES);
   --  Return True for a string or bytes field

   function Is_Packable (Item : Field_Descriptor) return Boolean is
     (Is_Repeated (Item) and not Is_Text (Item) and not Is_Message (Item));
   --  Return True if values of the field may arrive packed

   function Has_Presence
     (Item : Field_Descriptor;
      Ctx  : Context) return Boolean is
     (not Ctx.Is_Map_Entry
      and then not Is_Repeated (Item)
      and then (Is_Required (Item)
                or else Is_Message (Item)
                or else (Item.Proto_3_Optional.Is_Set
                         and then Item.Proto_3_Optional.Value)
                or else not Ctx.Is_Proto_3));

   function Is_Always_Written
     (Item : Field_Descriptor;
      Ctx  : Context) return Boolean is
     (Has_Presence (Item, Ctx) or Ctx.Is_Map_Entry);
   --  Return True if a value equal to the default is written too

   function Has_Flag_Parameter
     (Item : Field_Descriptor;
      Ctx  : Context) return Boolean is
     (Has_Presence (Item, Ctx) and not Is_Required (Item));
   --  Encoding of a field depends on Has_<Name> unless it is required

   function Is_Fixed_32 (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in TYPE_FIXED32 | TYPE_SFIXED32 | TYPE_FLOAT);

   function Is_Fixed_64 (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in TYPE_FIXED64 | TYPE_SFIXED64 | TYPE_DOUBLE);

   function Is_Direct (Item : Field_Descriptor) return Boolean is
     (Item.PB_Type.Value in
        TYPE_UINT64 | TYPE_FIXED32 | TYPE_FLOAT | TYPE_FIXED64 | TYPE_DOUBLE);
   --  Return True if the component has the same type as the wire value

   function Kind_Name (Item : Field_Descriptor) return Wide_Wide_String is
     (if Is_Fixed_32 (Item) then "Fixed_32"
      elsif Is_Fixed_64 (Item) then "Fixed_64"
      else "Varint");
   --  Return the wire type of a scalar value

   function Wire_Kind (Item : Field_Descriptor) return Universal_String is
     (if Is_Message (Item) or Is_Text (Item) then +Wire & "Length_Delimited"
      else +Wire & Kind_Name (Item));

   function Raw_Type (Item : Field_Descriptor) return Universal_String is
     (if Is_Fixed_32 (Item) then +"Interfaces.Unsigned_32"
      else +"Interfaces.Unsigned_64");
   --  Return the type of a scalar value on the wire

   function Bounds_Of
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Compiler.Bounds.Field_Bounds
   is (Compiler.Bounds.Field (Bounds, Ctx.Message & "." & Item.Name.Value));

   -----------
   -- Types --
   -----------

   function Qualified
     (Type_Name : Universal_String;
      Name      : Universal_String;
      Ctx       : Context) return Universal_String;
   --  Return how to name an entity declared next to a type, from the package
   --  being generated

   function Scalar_Type
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String;
   --  Return the type of a value that is not a string or bytes

   function Element_Type
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String is
     (if Is_Text (Item)
      then Ctx.Type_Name & "_" & Component_Name (Item)
        & (if Item.PB_Type.Value = TYPE_STRING then "_String" else "_Bytes")
      else Scalar_Type (Item, Ctx));
   --  Return the type of one value of the field

   function Array_Type
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String is
     (Ctx.Type_Name & "_" & Component_Name (Item) & "_Array");

   function Component_Type
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String is
     (if Is_Repeated (Item) then Array_Type (Item, Ctx)
      else Element_Type (Item, Ctx));

   ------------
   -- Values --
   ------------

   function Default_Text
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String;
   --  Return the initial value of a value, or "" if its type gives it

   function Element_Default
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String is
     (if Is_Text (Item) or Is_Message (Item) then +"<>"
      else Default_Text (Item, Ctx));
   --  Return the initial value of the elements of a repeated field

   function Default_Bytes (Item : Field_Descriptor) return String;
   --  Return the bytes of a proto2 default of a string or bytes field

   function To_Wire
     (Item  : Field_Descriptor;
      Ctx   : Context;
      Value : Universal_String) return Universal_String;
   --  Convert a value to the type used to encode it

   function From_Wire
     (Item  : Field_Descriptor;
      Value : Universal_String) return Universal_String;
   --  Convert a decoded value to the type of the component

   function Float_Bits
     (Text    : Universal_String;
      Is_Long : Boolean) return Universal_String;
   --  Return the IEEE bits of a float or double default as an Ada literal

   function Integer_Text (Text : Universal_String) return Universal_String;
   --  Return an integer default as an Ada expression

   function Is_Initialized
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Target : Universal_String) return Universal_String is
     (Qualified (Item.Type_Name.Value, +"Is_Initialized", Ctx)
      & " (" & Target & ")");

   function Needs_Check
     (Item   : Field_Descriptor;
      Bounds : Compiler.Bounds.Analysis) return Boolean is
     (Is_Message (Item) and then Needs_Check (Item.Type_Name.Value, Bounds));

   --------------------------
   -- Parts of the encoding --
   --------------------------

   function Put_Value
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis;
      Value  : Universal_String;
      Always : Boolean) return Node;
   --  Return statements that write Value of a field with its tag. Unless
   --  Always is set, a value equal to the default isn't written.

   function Field_Encode
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;

   --------------------------
   -- Parts of the decoding --
   --------------------------

   function Skip_Unless (Kinds : Universal_String) return Node;
   --  Return statements that skip the field and return unless it has one of
   --  the wire types in Kinds

   function Return_Unless_OK return Node is
     (F.New_If
        (Condition => N (+"Status /= PB_SPARK.OK"),
         Then_Path => F.New_Return));

   function Read_Enum
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis;
      Limit  : Universal_String;
      Store  : Node) return Node;
   --  Return a block that reads an enum value into Value and then executes
   --  Store, if the value is to be kept, as the policy for unknown values says

   function Read_Message
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Limit  : Universal_String;
      Target : Universal_String;
      Before : Node;
      After  : Node) return Node;
   --  Return a block that merges a message from Buffer into Target. Before
   --  is executed once the length prefix is read, and After on success.

   function Field_Merge
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;

   function Repeated_Merge
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;

   function Member_Merge
     (Self   : Item;
      Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;
   --  Return statements that read a field of oneof Self

   -------------------------
   -- Items of one field --
   -------------------------

   function Field_Types
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;

   function Field_Component
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;

   function Field_Clear
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node;

   function Field_Initialized_Term
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Universal_String;

   -------------
   -- Actuals --
   -------------

   function Actuals
     (Self : Item;
      Ctx  : Context) return Ada_Pretty.Node_Access
   is
      Field  : Field_Descriptor;
      Result : Node;
   begin
      if Self.Is_Oneof then
         return F.New_Argument_Association (N ("V." & Self.Name));
      end if;

      Field := Self.Fields.First_Element;

      if Has_Flag_Parameter (Field, Ctx) then
         Result := F.New_Argument_Association (N ("V." & Has_Name (Field)));
      end if;

      Result := F.New_List
        (Result, F.New_Argument_Association (N ("V." & Component_Name (Field))));

      if Is_Repeated (Field) then
         Result := F.New_List
           (Result, F.New_Argument_Association (N ("V." & Count_Name (Field))));
      end if;

      return Result;
   end Actuals;

   ----------
   -- Call --
   ----------

   function Call
     (Name      : Universal_String;
      Arguments : Universal_String) return Node
   is
      List : Node;
      Text : constant String_Vector := Arguments.Split ('|');
   begin
      for J in 1 .. Text.Length loop
         List := F.New_List
           (List, F.New_Argument_Association (N (Text (J))));
      end loop;

      return F.New_Statement (F.New_Apply (F.New_Selected_Name (Name), List));
   end Call;

   ---------------------
   -- Check_Supported --
   ---------------------

   procedure Check_Supported
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis;
      Errors : in out League.String_Vectors.Universal_String_Vector) is
   begin
      for Field of Self.Fields loop
         if Is_Text (Field)
           and then not Ctx.Is_Proto_3
           and then Field.Default_Value.Is_Set
           and then Default_Bytes (Field)'Length
             > Bounds_Of (Field, Ctx, Bounds).Capacity
         then
            Errors.Append
              (Ctx.Message & "." & Field.Name.Value
               & ": the default value is longer than the field can hold");
         end if;

         if Self.Is_Oneof
           and then Component_Name (Field).To_Lowercase
             = Self.Name.To_Lowercase
         then
            Errors.Append
              (Ctx.Message & "." & Field.Name.Value
               & ": its Ada component clashes with its oneof: add "
               & "type:ignore to it");
         end if;
      end loop;
   end Check_Supported;

   -------------
   -- Choices --
   -------------

   function Choices
     (Self : Item) return League.String_Vectors.Universal_String_Vector
   is
      Result : String_Vector;
   begin
      for Field of Self.Fields loop
         Result.Append (Number (Field));
      end loop;

      return Result;
   end Choices;

   -----------
   -- Clear --
   -----------

   function Clear
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access is
   begin
      if Self.Is_Oneof then
         return F.New_Assignment
           (N ("V." & Self.Name),
            N ("(" & Self.Name & " => " & Not_Set (Self) & ")"));
      else
         return Field_Clear (Self.Fields.First_Element, Ctx, Bounds);
      end if;
   end Clear;

   ---------------
   -- Component --
   ---------------

   function Component
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access is
   begin
      if Self.Is_Oneof then
         return F.New_Variable
           (Name            => N (Self.Name),
            Type_Definition => N (Variant_Type (Self, Ctx)));
      else
         return Field_Component (Self.Fields.First_Element, Ctx, Bounds);
      end if;
   end Component;

   ---------------------
   -- Component_Names --
   ---------------------

   function Component_Names
     (Self : Item;
      Ctx  : Context) return League.String_Vectors.Universal_String_Vector
   is
      Result : String_Vector;
      Field  : Field_Descriptor;
   begin
      if Self.Is_Oneof then
         Result.Append (Self.Name);
         return Result;
      end if;

      Field := Self.Fields.First_Element;
      Result.Append (Component_Name (Field));

      if Has_Presence (Field, Ctx) then
         Result.Append (Has_Name (Field));
      end if;

      if Is_Repeated (Field) then
         Result.Append (Count_Name (Field));
      end if;

      return Result;
   end Component_Names;

   --------------------
   -- Declared_Names --
   --------------------

   procedure Declared_Names
     (Self         : Item;
      Ctx          : Context;
      Types        : in out League.String_Vectors.Universal_String_Vector;
      Overloadable : in out League.String_Vectors.Universal_String_Vector) is
   begin
      for Field of Self.Fields loop
         if Is_Text (Field) then
            Types.Append (Element_Type (Field, Ctx));
         end if;

         if Is_Repeated (Field) then
            Types.Append (Array_Type (Field, Ctx));
         end if;

         if Self.Is_Oneof then
            Overloadable.Append (Literal (Field));
         end if;
      end loop;

      if Self.Is_Oneof then
         Types.Append (Kind_Type (Self, Ctx));
         Types.Append (Variant_Type (Self, Ctx));
         Overloadable.Append (Not_Set (Self));
      end if;
   end Declared_Names;

   -------------------
   -- Default_Bytes --
   -------------------

   function Default_Bytes (Item : Field_Descriptor) return String is
      Text   : constant Wide_Wide_String :=
        Item.Default_Value.Value.To_Wide_Wide_String;
      Result : String (1 .. Text'Length);
      Last   : Natural := 0;
      J      : Positive := Text'First;

      procedure Add (Code : Natural);

      function Digit (C : Wide_Wide_Character) return Natural is
        (case C is
            when '0' .. '9' =>
              Wide_Wide_Character'Pos (C) - Wide_Wide_Character'Pos ('0'),
            when 'a' .. 'f' =>
              Wide_Wide_Character'Pos (C) - Wide_Wide_Character'Pos ('a') + 10,
            when 'A' .. 'F' =>
              Wide_Wide_Character'Pos (C) - Wide_Wide_Character'Pos ('A') + 10,
            when others => 16);

      procedure Add (Code : Natural) is
      begin
         Last := Last + 1;
         Result (Last) := Character'Val (Code mod 256);
      end Add;

   begin
      if Item.PB_Type.Value = TYPE_STRING then
         return Item.Default_Value.Value.To_UTF_8_String;
      end if;

      --  Defaults of bytes fields are escaped as in C
      while J <= Text'Last loop
         if Text (J) /= '\' or J = Text'Last then
            Add (Wide_Wide_Character'Pos (Text (J)));
            J := J + 1;
         else
            J := J + 1;

            case Text (J) is
               when 'n' => Add (10); J := J + 1;
               when 'r' => Add (13); J := J + 1;
               when 't' => Add (9); J := J + 1;
               when 'a' => Add (7); J := J + 1;
               when 'b' => Add (8); J := J + 1;
               when 'f' => Add (12); J := J + 1;
               when 'v' => Add (11); J := J + 1;
               when 'x' | 'X' =>
                  declare
                     Code : Natural := 0;
                  begin
                     J := J + 1;

                     while J <= Text'Last and then Digit (Text (J)) < 16 loop
                        Code := Code * 16 + Digit (Text (J));
                        J := J + 1;
                     end loop;

                     Add (Code);
                  end;
               when '0' .. '7' =>
                  declare
                     Code  : Natural := 0;
                     Count : Natural := 0;
                  begin
                     while J <= Text'Last
                       and then Count < 3
                       and then Text (J) in '0' .. '7'
                     loop
                        Code := Code * 8 + Digit (Text (J));
                        Count := Count + 1;
                        J := J + 1;
                     end loop;

                     Add (Code);
                  end;
               when others =>
                  Add (Wide_Wide_Character'Pos (Text (J)));
                  J := J + 1;
            end case;
         end if;
      end loop;

      return Result (1 .. Last);
   end Default_Bytes;

   ------------------
   -- Default_Text --
   ------------------

   function Default_Text
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String
   is
      Given : constant Boolean :=
        not Ctx.Is_Proto_3 and then Item.Default_Value.Is_Set;
      Text  : constant Universal_String :=
        (if Given then Item.Default_Value.Value else +"");
   begin
      case Item.PB_Type.Value is
         when TYPE_MESSAGE | TYPE_GROUP =>
            return +"";
         when TYPE_BOOL =>
            return (if Given and then Text = +"true" then +"True"
                    else +"False");
         when TYPE_ENUM =>
            declare
               Key : constant Universal_String := Item.Type_Name.Value;
            begin
               return Qualified
                 (Key,
                  (if Given then Compiler.SPARK_Enums.Literal (Key, Text)
                   else Compiler.Context.Named_Types (Key).Enum.Default),
                  Ctx);
            end;
         when TYPE_FLOAT =>
            return (if Given then Float_Bits (Text, False) else +"0");
         when TYPE_DOUBLE =>
            return (if Given then Float_Bits (Text, True) else +"0");
         when TYPE_SFIXED32 | TYPE_SFIXED64 | TYPE_INT32 | TYPE_INT64
            | TYPE_SINT32 | TYPE_SINT64 | TYPE_UINT32 | TYPE_UINT64
            | TYPE_FIXED32 | TYPE_FIXED64 =>
            return (if Given then Integer_Text (Text) else +"0");
         when TYPE_STRING | TYPE_BYTES =>
            declare
               Data   : constant String :=
                 (if Given then Default_Bytes (Item) else "");
               Result : Universal_String;
            begin
               if Data'Length = 0 then
                  return +"";
               end if;

               Result := "(Length => " & Image (Data'Length) & ", Data => (";

               for C of Data loop
                  Result.Append (Image (Character'Pos (C)) & ", ");
               end loop;

               return Result & "others => 0))";
            end;
      end case;
   end Default_Text;

   ------------
   -- Encode --
   ------------

   function Encode
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Value : constant Universal_String := Formal (Self.Name);
      Paths : Node;
   begin
      if not Self.Is_Oneof then
         return Field_Encode (Self.Fields.First_Element, Ctx, Bounds);
      end if;

      Paths := F.New_Case_Path (N (Not_Set (Self)), F.New_Statement);

      for Field of Self.Fields loop
         Paths := F.New_List
           (Paths,
            F.New_Case_Path
              (N (Literal (Field)),
               Put_Value
                 (Field, Ctx, Bounds, Value & "." & Component_Name (Field),
                  Always => True)));
      end loop;

      return F.New_Case (N (Value & "." & Self.Name), Paths);
   end Encode;

   --------------
   -- Expanded --
   --------------

   function Expanded
     (Full_Name : Universal_String;
      Ctx       : Context) return Universal_String
   is
      Result : constant Universal_String :=
        Compiler.Context.Relative_Name (Full_Name, Ctx.Package_Name);
   begin
      if Package_Names.Contains (Result.Split ('.') (1).To_Lowercase) then
         return "Standard." & Full_Name;
      else
         return Result;
      end if;
   end Expanded;

   ------------------
   -- Field_Clear --
   ------------------

   function Field_Clear
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      pragma Unreferenced (Bounds);
      Target  : constant Universal_String := "V." & Component_Name (Item);
      Default : constant Universal_String := Default_Text (Item, Ctx);
      Result  : Node;
   begin
      if Is_Repeated (Item) then
         return F.New_List
           (F.New_Assignment
              (N (Target),
               N ("(others => " & Element_Default (Item, Ctx) & ")")),
            F.New_Assignment (N ("V." & Count_Name (Item)), N (+"0")));
      elsif Is_Message (Item) then
         Result := F.New_Statement
           (F.New_Apply
              (N (Qualified (Item.Type_Name.Value, +"Clear", Ctx)),
               F.New_Argument_Association (N (Target))));
      elsif Is_Text (Item) then
         Result := F.New_Assignment
           (N (Target),
            N (if Default.Is_Empty then +"(others => <>)" else Default));
      else
         Result := F.New_Assignment (N (Target), N (Default));
      end if;

      if Has_Presence (Item, Ctx) then
         Result := F.New_List
           (F.New_Assignment (N ("V." & Has_Name (Item)), N (+"False")),
            Result);
      end if;

      return Result;
   end Field_Clear;

   ---------------------
   -- Field_Component --
   ---------------------

   function Field_Component
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      Default : constant Universal_String := Default_Text (Item, Ctx);
      Value   : Node;
   begin
      if Is_Repeated (Item) then
         declare
            Element : constant Universal_String := Element_Default (Item, Ctx);
         begin
            return F.New_List
              (F.New_Variable
                 (Name            => N (Component_Name (Item)),
                  Type_Definition => N (Array_Type (Item, Ctx)),
                  Initialization  =>
                    (if Element = +"<>" then null
                     else N ("(others => " & Element & ")"))),
               F.New_Variable
                 (Name            => N (Count_Name (Item)),
                  Type_Definition => N
                    ("PB_SPARK.Index range 0 .. "
                     & Image (Bounds_Of (Item, Ctx, Bounds).Count)),
                  Initialization  => N (+"0")));
         end;
      end if;

      Value := F.New_Variable
        (Name            => N (Component_Name (Item)),
         Type_Definition => N (Element_Type (Item, Ctx)),
         Initialization  =>
           (if Default.Is_Empty then null else N (Default)));

      if Has_Presence (Item, Ctx) then
         return F.New_List
           (F.New_Variable
              (Name            => N (Has_Name (Item)),
               Type_Definition => N (+"Boolean"),
               Initialization  => N (+"False")),
            Value);
      else
         return Value;
      end if;
   end Field_Component;

   ------------------
   -- Field_Encode --
   ------------------

   function Field_Encode
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      Value  : constant Universal_String := Formal (Component_Name (Item));
      Count  : constant Universal_String := Formal (Count_Name (Item));
      Limits : constant Compiler.Bounds.Field_Bounds :=
        Bounds_Of (Item, Ctx, Bounds);
      Result : Node;
   begin
      if Is_Repeated (Item) and Limits.Is_Packed then
         declare
            Payload : constant Universal_String :=
              Image (Limits.Count * Limits.Value_Size);
         begin
            --  The length prefix is written after the values, because its
            --  size depends on them
            return F.New_If
              (Condition => N (Count & " > 0"),
               Then_Path => F.New_Block
                 (Declarations => F.New_Variable
                    (Name            => N (+"Body_Last"),
                     Type_Definition => N (+"PB_SPARK.Index")),
                  Statements   => F.New_List
                    ((Call
                        (+Wire & "Reserve_Delimited",
                         Number (Item) & "|" & Payload
                         & "|Buffer|Last|Body_Last"),
                      F.New_For
                        (Name       => N (+"J"),
                         Iterator   => N ("1 .. " & Count),
                         Statements => F.New_List
                           (F.New_Pragma
                              (N (+"Loop_Invariant"),
                               N ("Body_Last in Body_Last'Loop_Entry .. "
                                  & "Body_Last'Loop_Entry + (J - 1) * "
                                  & Image (Limits.Value_Size))),
                            Call
                              (+Wire & "Put_" & Kind_Name (Item),
                               To_Wire (Item, Ctx, Value & " (J)")
                               & "|Buffer|Body_Last"))),
                      Call
                        (+Wire & "Finish_Delimited",
                         Payload & "|Body_Last|Buffer|Last")))));
         end;
      elsif Is_Repeated (Item) then
         return F.New_For
           (Name       => N (+"J"),
            Iterator   => N ("1 .. " & Count),
            Statements => F.New_List
              (F.New_Pragma
                 (N (+"Loop_Invariant"),
                  N ("Last in Last'Loop_Entry .. Last'Loop_Entry + (J - 1) * "
                     & Image (Limits.Max_Size / Limits.Count))),
               Put_Value (Item, Ctx, Bounds, Value & " (J)", Always => True)));
      end if;

      Result := Put_Value
        (Item, Ctx, Bounds, Value, Is_Always_Written (Item, Ctx));

      if Has_Flag_Parameter (Item, Ctx) then
         Result := F.New_If
           (Condition => N (Formal (Has_Name (Item))),
            Then_Path => Result);
      end if;

      return Result;
   end Field_Encode;

   ----------------------------
   -- Field_Initialized_Term --
   ----------------------------

   function Field_Initialized_Term
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Universal_String
   is
      Target : constant Universal_String := "V." & Component_Name (Item);
      Nested : constant Boolean := Needs_Check (Item, Bounds);
   begin
      if Is_Repeated (Item) then
         if Nested then
            return "(for all J in 1 .. V." & Count_Name (Item) & " => "
              & Is_Initialized (Item, Ctx, Target & " (J)") & ")";
         else
            return +"";
         end if;
      elsif Is_Required (Item) then
         return "V." & Has_Name (Item)
           & (if Nested then " and then " & Is_Initialized (Item, Ctx, Target)
              else +"");
      elsif Nested and Has_Presence (Item, Ctx) then
         return "(not V." & Has_Name (Item) & " or else "
           & Is_Initialized (Item, Ctx, Target) & ")";
      elsif Nested then
         return Is_Initialized (Item, Ctx, Target);
      else
         return +"";
      end if;
   end Field_Initialized_Term;

   -----------------
   -- Field_Merge --
   -----------------

   function Field_Merge
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      Target  : constant Universal_String := "V." & Component_Name (Item);
      Set_Has : constant Node :=
        (if Has_Presence (Item, Ctx)
         then F.New_Assignment (N ("V." & Has_Name (Item)), N (+"True"))
         else null);
      Arrived : constant Universal_String :=
        "Status = PB_SPARK.OK and then Wire in " & Wire_Kind (Item);
      Result  : Node;
   begin
      if Is_Repeated (Item) then
         return Repeated_Merge (Item, Ctx, Bounds);
      end if;

      --  Ada_Pretty doesn't print "else", so other wire types are skipped
      --  first, and Known and not Known are tested apart.
      if Is_Message (Item) then
         return F.New_List
           (Skip_Unless (Wire_Kind (Item)),
            Read_Message
              (Item, Ctx, +"Limit", Target,
               Before => null,
               After  => Join
                 (F.New_Assignment (N (+"Pos"), N (+"Inner + 1")), Set_Has)));
      elsif Is_Text (Item) then
         Result := Call
           (+Wire
            & (if Item.PB_Type.Value = TYPE_STRING then "Read_String_Field"
               else "Read_Bytes_Field"),
            "Buffer|Limit|Field|Wire|Pos|" & Target & ".Data|" & Target
            & ".Length|Status");
      elsif Item.PB_Type.Value = TYPE_ENUM then
         return F.New_List
           (Skip_Unless (Wire_Kind (Item)),
            Read_Enum
              (Item, Ctx, Bounds, +"Limit",
               Join (F.New_Assignment (N (Target), N (+"Value")), Set_Has)));
      elsif Is_Direct (Item) then
         Result := Call
           (+Wire & "Read_" & Kind_Name (Item) & "_Field",
            "Buffer|Limit|Field|Wire|Pos|" & Target & "|Status");
      else
         --  Raw starts as the current value, so if the field is skipped
         --  because it has another wire type then the component is left as
         --  it was.
         Result := F.New_Block
           (Declarations => F.New_Variable
              (Name            => N (+"Raw"),
               Type_Definition => N (Raw_Type (Item)),
               Initialization  => N (To_Wire (Item, Ctx, Target))),
            Statements   => F.New_List
              (Call
                 (+Wire & "Read_" & Kind_Name (Item) & "_Field",
                  +"Buffer|Limit|Field|Wire|Pos|Raw|Status"),
               F.New_Assignment (N (Target), N (From_Wire (Item, +"Raw")))));
      end if;

      if Set_Has /= null then
         Result := F.New_List
           (Result, F.New_If (Condition => N (Arrived), Then_Path => Set_Has));
      end if;

      return Result;
   end Field_Merge;

   -----------------
   -- Field_Types --
   -----------------

   function Field_Types
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      Limits : constant Compiler.Bounds.Field_Bounds :=
        Bounds_Of (Item, Ctx, Bounds);
      Result : Node;
   begin
      if Is_Text (Item) then
         Result := F.New_Type
           (Name       => N (Element_Type (Item, Ctx)),
            Definition => F.New_Record
              (Components => F.New_List
                 (F.New_Variable
                    (Name            => N (+"Length"),
                     Type_Definition => N
                       ("PB_SPARK.Index range 0 .. " & Image (Limits.Capacity)),
                     Initialization  => N (+"0")),
                  F.New_Variable
                    (Name            => N (+"Data"),
                     Type_Definition => N
                       ("PB_SPARK.Byte_Array (1 .. " & Image (Limits.Capacity)
                        & ")"),
                     Initialization  => N (+"(others => 0)")))));
      end if;

      if Is_Repeated (Item) then
         Result := F.New_List
           (Result,
            F.New_Type
              (Name       => N (Array_Type (Item, Ctx)),
               Definition => N
                 ("array (PB_SPARK.Index range 1 .. " & Image (Limits.Count)
                  & ") of " & Element_Type (Item, Ctx))));
      end if;

      return Result;
   end Field_Types;

   ----------------
   -- Float_Bits --
   ----------------

   function Float_Bits
     (Text    : Universal_String;
      Is_Long : Boolean) return Universal_String
   is
      use type Interfaces.Unsigned_64;

      function Cast is new Ada.Unchecked_Conversion
        (Interfaces.IEEE_Float_32, Interfaces.Unsigned_32);
      function Cast is new Ada.Unchecked_Conversion
        (Interfaces.IEEE_Float_64, Interfaces.Unsigned_64);

      Value : constant Wide_Wide_String := Text.To_Wide_Wide_String;
      Bits  : Interfaces.Unsigned_64;
   begin
      if Value = "inf" then
         Bits := (if Is_Long then 16#7FF0_0000_0000_0000# else 16#7F80_0000#);
      elsif Value = "-inf" then
         Bits := (if Is_Long then 16#FFF0_0000_0000_0000# else 16#FF80_0000#);
      elsif Value = "nan" then
         Bits := (if Is_Long then 16#7FF8_0000_0000_0000# else 16#7FC0_0000#);
      elsif Is_Long then
         Bits := Cast (Interfaces.IEEE_Float_64'Wide_Wide_Value (Value));
      else
         Bits := Interfaces.Unsigned_64
           (Cast (Interfaces.IEEE_Float_32'Wide_Wide_Value (Value)));
      end if;

      declare
         Image : constant Wide_Wide_String :=
           Interfaces.Unsigned_64'Wide_Wide_Image (Bits);
      begin
         return +Image (Image'First + 1 .. Image'Last);
      end;
   end Float_Bits;

   ---------------
   -- From_Wire --
   ---------------

   function From_Wire
     (Item  : Field_Descriptor;
      Value : Universal_String) return Universal_String
   is
      Name : constant Wide_Wide_String :=
        (case Item.PB_Type.Value is
            when TYPE_INT32                    => "To_Integer_32",
            when TYPE_INT64                    => "To_Integer_64",
            when TYPE_UINT32                   => "To_Unsigned_32",
            when TYPE_SINT32                   => "Unzigzag_32",
            when TYPE_SINT64                   => "Unzigzag_64",
            when TYPE_BOOL                     => "To_Boolean",
            when TYPE_SFIXED32 | TYPE_SFIXED64 => "Signed_Of",
            when others                        => "");
   begin
      if Name = "" then
         return Value;
      else
         return +Wire & Name & " (" & Value & ")";
      end if;
   end From_Wire;

   -----------
   -- Image --
   -----------

   function Image (Value : Natural) return Universal_String is
      Text : constant Wide_Wide_String := Natural'Wide_Wide_Image (Value);
   begin
      return +Text (Text'First + 1 .. Text'Last);
   end Image;

   ----------------------
   -- Initialized_Term --
   ----------------------

   function Initialized_Term
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis)
      return League.Strings.Universal_String
   is
      Result : String_Vector;
   begin
      if not Self.Is_Oneof then
         return Field_Initialized_Term (Self.Fields.First_Element, Ctx, Bounds);
      end if;

      for Field of Self.Fields loop
         if Needs_Check (Field, Bounds) then
            Result.Append
              ("(V." & Self.Name & "." & Self.Name & " /= " & Literal (Field)
               & " or else "
               & Is_Initialized
                 (Field, Ctx,
                  "V." & Self.Name & "." & Component_Name (Field))
               & ")");
         end if;
      end loop;

      return Result.Join (" and then ");
   end Initialized_Term;

   ------------------
   -- Integer_Text --
   ------------------

   function Integer_Text (Text : Universal_String) return Universal_String is
   begin
      if Text.Starts_With ("-") then
         return "Interfaces.""-"" (" & Text.Tail_From (2) & ")";
      else
         return Text;
      end if;
   end Integer_Text;

   -----------
   -- Items --
   -----------

   function Items
     (Message : Google.Protobuf.Descriptor.Descriptor_Proto;
      Ctx     : Context;
      Bounds  : Compiler.Bounds.Analysis) return Item_Vectors.Vector
   is
      Result : Item_Vectors.Vector;
      Done   : array (0 .. Message.Oneof_Decl.Length) of Boolean :=
        (others => False);
   begin
      for J in 1 .. Message.Field.Length loop
         declare
            Field : constant Field_Descriptor := Message.Field (J);
         begin
            if Bounds_Of (Field, Ctx, Bounds).Ignored then
               null;
            elsif not Compiler.Field_Descriptors.Is_One_Of (Field) then
               Result.Append
                 ((Is_Oneof => False,
                   Name     => <>,
                   Fields   => Field_Vectors.To_Vector (Field, 1)));
            elsif not Done (Natural (Field.Oneof_Index.Value)) then
               declare
                  Index : constant Natural := Natural (Field.Oneof_Index.Value);
                  Next  : Item;
               begin
                  Done (Index) := True;
                  Next.Is_Oneof := True;
                  Next.Name := Compiler.Context.To_Ada_Name
                    (Message.Oneof_Decl (Index + 1).Name.Value);

                  for K in J .. Message.Field.Length loop
                     declare
                        Member : constant Field_Descriptor :=
                          Message.Field (K);
                     begin
                        if Compiler.Field_Descriptors.Is_One_Of (Member)
                          and then Natural (Member.Oneof_Index.Value) = Index
                          and then not Bounds_Of (Member, Ctx, Bounds).Ignored
                        then
                           Next.Fields.Append (Member);
                        end if;
                     end;
                  end loop;

                  Result.Append (Next);
               end;
            end if;
         end;
      end loop;

      return Result;
   end Items;

   --------------
   -- Max_Size --
   --------------

   function Max_Size
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Natural
   is
      Result : Natural := 0;
   begin
      --  Only one field of a oneof is written
      for Field of Self.Fields loop
         Result := Natural'Max
           (Result, Bounds_Of (Field, Ctx, Bounds).Max_Size);
      end loop;

      return Result;
   end Max_Size;

   ------------------
   -- Member_Merge --
   ------------------

   function Member_Merge
     (Self   : Item;
      Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      Variant : constant Universal_String := "V." & Self.Name;
      Target  : constant Universal_String :=
        Variant & "." & Component_Name (Item);
      Switch  : constant Node := F.New_If
        (Condition => N
           (Variant & "." & Self.Name & " /= " & Literal (Item)),
         Then_Path => F.New_Assignment
           (N (Variant),
            N ("(" & Self.Name & " => " & Literal (Item) & ", "
               & Component_Name (Item) & " => <>)")));
      --  Select the field, so that its component can be written

      function Store (Value : Universal_String) return Node is
        (F.New_Assignment
           (N (Variant),
            N ("(" & Self.Name & " => " & Literal (Item) & ", "
               & Component_Name (Item) & " => " & Value & ")")));

      Result : Node := Skip_Unless (Wire_Kind (Item));
   begin
      if Is_Message (Item) then
         return F.New_List
           (Result,
            Read_Message
              (Item, Ctx, +"Limit", Target,
               Before => Switch,
               After  => F.New_Assignment (N (+"Pos"), N (+"Inner + 1"))));
      elsif Is_Text (Item) then
         return F.New_List
           ((Result,
             Switch,
             Call
               (+Wire
                & (if Item.PB_Type.Value = TYPE_STRING then "Read_String_Field"
                   else "Read_Bytes_Field"),
                "Buffer|Limit|Field|Wire|Pos|" & Target & ".Data|" & Target
                & ".Length|Status")));
      elsif Item.PB_Type.Value = TYPE_ENUM then
         return F.New_List
           (Result,
            Read_Enum (Item, Ctx, Bounds, +"Limit", Store (+"Value")));
      end if;

      Result := F.New_List
        (Result,
         F.New_Block
           (Declarations => F.New_Variable
              (Name            => N (+"Raw"),
               Type_Definition => N (Raw_Type (Item))),
            Statements   => F.New_List
              (Call
                 (+Wire & "Get_" & Kind_Name (Item),
                  +"Buffer|Limit|Pos|Raw|Status"),
               F.New_If
                 (Condition => N (+"Status = PB_SPARK.OK"),
                  Then_Path => Store (From_Wire (Item, +"Raw"))))));

      return Result;
   end Member_Merge;

   -----------
   -- Merge --
   -----------

   function Merge
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Result : Node;
   begin
      for Field of Self.Fields loop
         Result := F.New_List
           (Result,
            F.New_Case_Path
              (Choice => N (Number (Field)),
               List   =>
                 (if Self.Is_Oneof
                  then Member_Merge (Self, Field, Ctx, Bounds)
                  else Field_Merge (Field, Ctx, Bounds))));
      end loop;

      return Result;
   end Merge;

   -----------------
   -- Needs_Check --
   -----------------

   function Needs_Check
     (Type_Name : League.Strings.Universal_String;
      Bounds    : Compiler.Bounds.Analysis) return Boolean
   is
      Info : constant Message_Info := Messages (Type_Name);
   begin
      for J in 1 .. Info.Descriptor.Field.Length loop
         declare
            Item : constant Field_Descriptor := Info.Descriptor.Field (J);
         begin
            if Compiler.Bounds.Field
              (Bounds, Info.Full_Name & "." & Item.Name.Value).Ignored
            then
               null;
            elsif Is_Required (Item) or else Needs_Check (Item, Bounds) then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Needs_Check;

   ----------------
   -- Parameters --
   ----------------

   function Parameters
     (Self : Item;
      Ctx  : Context) return Ada_Pretty.Node_Access
   is
      Field  : Field_Descriptor;
      Result : Node;
   begin
      if Self.Is_Oneof then
         return F.New_Parameter
           (Name            => N (Formal (Self.Name)),
            Type_Definition => N (Variant_Type (Self, Ctx)));
      end if;

      Field := Self.Fields.First_Element;

      if Has_Flag_Parameter (Field, Ctx) then
         Result := F.New_Parameter
           (Name            => N (Formal (Has_Name (Field))),
            Type_Definition => N (+"Boolean"));
      end if;

      Result := F.New_List
        (Result,
         F.New_Parameter
           (Name            => N (Formal (Component_Name (Field))),
            Type_Definition => N (Component_Type (Field, Ctx))));

      if Is_Repeated (Field) then
         Result := F.New_List
           (Result,
            F.New_Parameter
              (Name            => N (Formal (Count_Name (Field))),
               Type_Definition => N (+"PB_SPARK.Index")));
      end if;

      return Result;
   end Parameters;

   ------------------
   -- Precondition --
   ------------------

   function Precondition
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis)
      return League.Strings.Universal_String
   is
      Field : constant Field_Descriptor := Self.Fields.First_Element;
   begin
      if not Self.Is_Oneof and then Is_Repeated (Field) then
         return Formal (Count_Name (Field)) & " <= "
           & Image (Bounds_Of (Field, Ctx, Bounds).Count);
      else
         return +"";
      end if;
   end Precondition;

   ---------------
   -- Put_Value --
   ---------------

   function Put_Value
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis;
      Value  : Universal_String;
      Always : Boolean) return Node
   is
      Form : constant Wide_Wide_String :=
        (if Always then "_Field" else "_Option");
   begin
      if Is_Message (Item) then
         declare
            Max : constant Universal_String := Image
              (Compiler.Bounds.Max_Encoded_Size
                 (Bounds, Item.Type_Name.Value));
         begin
            return F.New_Block
              (Declarations => F.New_Variable
                 (Name            => N (+"Body_Last"),
                  Type_Definition => N (+"PB_SPARK.Index")),
               Statements   => F.New_List
                 ((Call
                     (+Wire & "Reserve_Delimited",
                      Number (Item) & "|" & Max & "|Buffer|Last|Body_Last"),
                   Call
                     (Qualified (Item.Type_Name.Value, +"Append", Ctx),
                      Value & "|Buffer|Body_Last"),
                   Call
                     (+Wire & "Finish_Delimited",
                      Max & "|Body_Last|Buffer|Last"))));
         end;
      elsif Is_Text (Item) then
         return Call
           (+Wire & "Put_Bytes" & Form,
            Number (Item) & "|" & Value & ".Data|" & Value
            & ".Length|Buffer|Last");
      else
         return Call
           (+Wire & "Put_" & Kind_Name (Item) & Form,
            Number (Item) & "|" & To_Wire (Item, Ctx, Value) & "|Buffer|Last");
      end if;
   end Put_Value;

   ---------------
   -- Qualified --
   ---------------

   function Qualified
     (Type_Name : Universal_String;
      Name      : Universal_String;
      Ctx       : Context) return Universal_String
   is
      Owner : constant Universal_String :=
        Compiler.Context.Named_Types (Type_Name).Ada_Type.Package_Name;
   begin
      if Owner = Ctx.Package_Name then
         return Name;
      else
         return Expanded (Owner & "." & Name, Ctx);
      end if;
   end Qualified;

   ---------------
   -- Read_Enum --
   ---------------

   function Read_Enum
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis;
      Limit  : Universal_String;
      Store  : Node) return Node
   is
      Key     : constant Universal_String := Item.Type_Name.Value;
      Policy  : constant Compiler.Options.Unknown_Enum_Policy :=
        Bounds_Of (Item, Ctx, Bounds).On_Unknown_Enum;
      Convert : Node := Call
        (Qualified
           (Key,
            Compiler.Context.Named_Types (Key).Ada_Type.Type_Name
            & "_From_Wire",
            Ctx),
         +Wire & "To_Integer_32 (Raw)|Value|Known");
      Keep    : Node;
   begin
      --  Enums of proto3 accept any value, but an Ada enumeration can't hold
      --  one it doesn't define, so the policy decides. With "first" Value
      --  stays the default. Unknown values of proto2 enums are unknown
      --  fields, so they are dropped.
      if not Ctx.Is_Proto_3 then
         Keep := F.New_If (Condition => N (+"Known"), Then_Path => Store);
      elsif Policy = Compiler.Options.Reject then
         Keep := F.New_List
           (F.New_If
              (Condition => N (+"not Known"),
               Then_Path => F.New_Assignment
                 (N (+"Status"), N (+"PB_SPARK.Unknown_Enum"))),
            F.New_If (Condition => N (+"Known"), Then_Path => Store));
      else
         Keep := Store;
         Convert := F.New_List
           ((F.New_Pragma
               (N (+"Warnings"),
                N (+"GNATprove, Off, ""*""""Known"""" is set by*"", Reason "
                   & "=> ""Unknown values keep the default""")),
             Convert,
             F.New_Pragma
               (N (+"Warnings"),
                N (+"GNATprove, On, ""*""""Known"""" is set by*"""))));
      end if;

      return F.New_Block
        (Declarations => F.New_List
           ((F.New_Variable
               (Name            => N (+"Raw"),
                Type_Definition => N (+"Interfaces.Unsigned_64")),
             F.New_Variable
               (Name            => N (+"Value"),
                Type_Definition => N (Scalar_Type (Item, Ctx)),
                Initialization  => N (Default_Text (Item, Ctx))),
             F.New_Variable
               (Name            => N (+"Known"),
                Type_Definition => N (+"Boolean")))),
         Statements   => F.New_List
           ((Call
               (+Wire & "Get_Varint", "Buffer|" & Limit & "|Pos|Raw|Status"),
             F.New_If
               (Condition => N (+"Status = PB_SPARK.OK"),
                Then_Path => F.New_List (Convert, Keep)))));
   end Read_Enum;

   ------------------
   -- Read_Message --
   ------------------

   function Read_Message
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Limit  : Universal_String;
      Target : Universal_String;
      Before : Node;
      After  : Node) return Node is
   begin
      return F.New_Block
        (Declarations => F.New_Variable
           (Name            => N (+"Inner"),
            Type_Definition => N (+"PB_SPARK.Index")),
         Statements   => F.New_List
           (Call
              (+Wire & "Get_Delimited",
               "Buffer|" & Limit & "|Pos|Inner|Status"),
            F.New_If
              (Condition => N (+"Status = PB_SPARK.OK"),
               Then_Path => F.New_List
                 (Before,
                  F.New_List
                    (Call
                       (Qualified (Item.Type_Name.Value, +"Merge", Ctx),
                        "Buffer|Inner|Pos|" & Target & "|Status"),
                     F.New_If
                       (Condition => N (+"Status = PB_SPARK.OK"),
                        Then_Path => After))))));
   end Read_Message;

   --------------
   -- Register --
   --------------

   procedure Register
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request)
   is
      procedure Add
        (Prefix : Universal_String;
         Item   : Google.Protobuf.Descriptor.Descriptor_Proto);

      procedure Add
        (Prefix : Universal_String;
         Item   : Google.Protobuf.Descriptor.Descriptor_Proto)
      is
         Key : constant Universal_String :=
           Compiler.Context.Join (Prefix, Item.Name);
      begin
         Messages.Include (Key, (Item, Key.Tail_From (2)));

         for J in 1 .. Item.Nested_Type.Length loop
            Add (Key, Item.Nested_Type (J));
         end loop;
      end Add;

   begin
      Compiler.SPARK_Enums.Register (Request);

      for J in 1 .. Request.Proto_File.Length loop
         declare
            File   : constant Google.Protobuf.Descriptor.File_Descriptor_Proto
              := Request.Proto_File (J);
            Prefix : Universal_String;
         begin
            if File.PB_Package.Is_Set then
               Prefix := "." & File.PB_Package.Value;
            end if;

            for K in 1 .. File.Message_Type.Length loop
               Add (Prefix, File.Message_Type (K));
            end loop;
         end;
      end loop;
   end Register;

   -----------------------
   -- Set_Package_Names --
   -----------------------

   procedure Set_Package_Names
     (Names : League.String_Vectors.Universal_String_Vector) is
   begin
      Package_Names.Clear;

      for J in 1 .. Names.Length loop
         Package_Names.Include (Names (J).To_Lowercase);
      end loop;
   end Set_Package_Names;

   --------------------
   -- Repeated_Merge --
   --------------------

   function Repeated_Merge
     (Item   : Field_Descriptor;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Node
   is
      Values : constant Universal_String := "V." & Component_Name (Item);
      Count  : constant Universal_String := "V." & Count_Name (Item);
      Next   : constant Universal_String :=
        Values & " (" & Count & " + 1)";
      Full   : constant Node := F.New_If
        (Condition => N
           (Count & " = " & Image (Bounds_Of (Item, Ctx, Bounds).Count)),
         Then_Path => F.New_List
           (F.New_Assignment (N (+"Status"), N (+"PB_SPARK.Limit_Exceeded")),
            F.New_Return));
      Grow   : constant Node :=
        F.New_Assignment (N (Count), N (Count & " + 1"));

      function Append_One (Limit : Universal_String) return Node;
      --  Return statements that read one value into Next and count it

      function Append_One (Limit : Universal_String) return Node is
      begin
         if Is_Message (Item) then
            return Read_Message
              (Item, Ctx, Limit, Next,
               Before => F.New_Statement
                 (F.New_Apply
                    (N (Qualified (Item.Type_Name.Value, +"Clear", Ctx)),
                     F.New_Argument_Association (N (Next)))),
               After  => F.New_List
                 (F.New_Assignment (N (+"Pos"), N (+"Inner + 1")), Grow));
         elsif Is_Text (Item) then
            return F.New_List
              (Call
                 (+Wire
                  & (if Item.PB_Type.Value = TYPE_STRING
                     then "Read_String_Field" else "Read_Bytes_Field"),
                  "Buffer|" & Limit & "|Field|Wire|Pos|" & Next & ".Data|"
                  & Next & ".Length|Status"),
               F.New_If
                 (Condition => N (+"Status = PB_SPARK.OK"),
                  Then_Path => Grow));
         elsif Item.PB_Type.Value = TYPE_ENUM then
            return Read_Enum
              (Item, Ctx, Bounds, Limit,
               F.New_List
                 (Grow,
                  F.New_Assignment (N (Values & " (" & Count & ")"),
                                    N (+"Value"))));
         else
            return F.New_Block
              (Declarations => F.New_Variable
                 (Name            => N (+"Raw"),
                  Type_Definition => N (Raw_Type (Item))),
               Statements   => F.New_List
                 (Call
                    (+Wire & "Get_" & Kind_Name (Item),
                     "Buffer|" & Limit & "|Pos|Raw|Status"),
                  F.New_If
                    (Condition => N (+"Status = PB_SPARK.OK"),
                     Then_Path => F.New_List
                       (Grow,
                        F.New_Assignment
                          (N (Values & " (" & Count & ")"),
                           N (From_Wire (Item, +"Raw")))))));
         end if;
      end Append_One;

      Result : Node;
   begin
      if not Is_Packable (Item) then
         return F.New_List
           ((Skip_Unless (Wire_Kind (Item)), Full, Append_One (+"Limit")));
      end if;

      --  Values that can be packed are accepted either way
      Result := F.New_List
        ((Skip_Unless (Wire_Kind (Item) & " | " & Wire & "Length_Delimited"),
          F.New_If
            (Condition => N ("Wire in " & Wire & "Length_Delimited"),
             Then_Path => F.New_List
               (F.New_Block
                  (Declarations => F.New_Variable
                     (Name            => N (+"Inner"),
                      Type_Definition => N (+"PB_SPARK.Index")),
                   Statements   => F.New_List
                     (Call
                        (+Wire & "Get_Delimited",
                         +"Buffer|Limit|Pos|Inner|Status"),
                      F.New_Loop
                        (Condition  => N
                           (+"Status = PB_SPARK.OK and then Pos <= Inner"),
                         Statements => F.New_List
                           ((F.New_Pragma
                               (N (+"Loop_Invariant"),
                                N (+"Pos in Pos'Loop_Entry .. Inner")),
                             F.New_Pragma
                               (N (+"Loop_Variant"),
                                F.New_Argument_Association
                                  (N (+"Pos"), N (+"Increases"))),
                             Full,
                             Append_One (+"Inner")))))),
                F.New_Return)),
          Full,
          Append_One (+"Limit")));

      return Result;
   end Repeated_Merge;

   -----------------
   -- Scalar_Type --
   -----------------

   function Scalar_Type
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String is
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
         when TYPE_ENUM | TYPE_MESSAGE =>
            declare
               Named : constant Compiler.Context.Ada_Type_Name :=
                 Compiler.Context.Named_Types (Item.Type_Name.Value).Ada_Type;
            begin
               --  Any component of a record hides a type with the same name
               --  in the rest of the record, so types are always named with
               --  their package.
               return Expanded (Compiler.Context."+" (Named), Ctx);
            end;
         when TYPE_STRING | TYPE_BYTES | TYPE_GROUP =>
            raise Program_Error;  --  Handled by Element_Type, or rejected
      end case;
   end Scalar_Type;

   -----------------
   -- Skip_Unless --
   -----------------

   function Skip_Unless (Kinds : Universal_String) return Node is
     (F.New_If
        (Condition => N ("Wire not in " & Kinds),
         Then_Path => F.New_List
           (Call (+Wire & "Skip_Field", +"Buffer|Limit|Field|Wire|Pos|Status"),
            F.New_Return)));

   -------------
   -- To_Wire --
   -------------

   function To_Wire
     (Item  : Field_Descriptor;
      Ctx   : Context;
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
         when TYPE_ENUM =>
            return +Wire & "From_Integer_32 ("
              & Qualified
                  (Item.Type_Name.Value,
                   Compiler.Context.Named_Types (Item.Type_Name.Value)
                     .Ada_Type.Type_Name & "_To_Wire",
                   Ctx)
              & " (" & Value & "))";
         when others =>
            return Value;
      end case;
   end To_Wire;

   ------------------
   -- Type_Package --
   ------------------

   function Type_Package
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return League.Strings.Universal_String is
   begin
      if Item.PB_Type.Value in TYPE_ENUM | TYPE_MESSAGE then
         return Compiler.Context.Named_Types
           (Item.Type_Name.Value).Ada_Type.Package_Name;
      else
         return +"";
      end if;
   end Type_Package;

   -----------
   -- Types --
   -----------

   function Types
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Result   : Node;
      Literals : Node;
      Paths    : Node;
   begin
      for Field of Self.Fields loop
         Result := Join (Result, Field_Types (Field, Ctx, Bounds));
      end loop;

      if not Self.Is_Oneof then
         return Result;
      end if;

      Literals := F.New_Argument_Association (N (Not_Set (Self)));
      Paths := F.New_Case_Path (N (Not_Set (Self)), F.New_Statement);

      for Field of Self.Fields loop
         declare
            Default : constant Universal_String := Default_Text (Field, Ctx);
         begin
            Literals := F.New_List
              (Literals, F.New_Argument_Association (N (Literal (Field))));
            Paths := F.New_List
              (Paths,
               F.New_Case_Path
                 (N (Literal (Field)),
                  F.New_Variable
                    (Name            => N (Component_Name (Field)),
                     Type_Definition => N (Element_Type (Field, Ctx)),
                     Initialization  =>
                       (if Default.Is_Empty then null else N (Default)))));
         end;
      end loop;

      return F.New_List
        (Result,
         F.New_List
           (F.New_Type
              (Name       => N (Kind_Type (Self, Ctx)),
               Definition => F.New_Parentheses (Literals)),
            F.New_Type
              (Name          => N (Variant_Type (Self, Ctx)),
               Discriminants => F.New_Parameter
                 (Name            => N (Self.Name),
                  Type_Definition => N (Kind_Type (Self, Ctx)),
                  Initialization  => N (Not_Set (Self))),
               Definition    => F.New_Record
                 (Components => F.New_Case
                    (Expression => N (Self.Name),
                     List       => Paths)))));
   end Types;

end Compiler.SPARK_Fields;

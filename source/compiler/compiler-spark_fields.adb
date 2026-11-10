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

   function Call
     (Name      : Universal_String;
      Arguments : Wide_Wide_String) return Node;
   --  Return a procedure call statement. Arguments are separated by "|".

   function Component_Name (Item : Field_Descriptor) return Universal_String
     is (Compiler.Context.To_Ada_Name (Item.Name.Value));

   function Has_Name (Item : Field_Descriptor) return Universal_String is
     ("Has_" & Component_Name (Item));

   function Formal_Name (Item : Field_Descriptor) return Universal_String
     is ("F_" & Component_Name (Item));
   --  The prefix keeps fields from clashing with other parameters

   function Number (Item : Field_Descriptor) return Universal_String;
   --  Return the field number as text

   function Image (Value : Natural) return Universal_String;

   function Is_Required (Item : Field_Descriptor) return Boolean is
     (Item.Label.Is_Set and then Item.Label.Value = LABEL_REQUIRED);

   function Has_Presence
     (Item : Field_Descriptor;
      Ctx  : Context) return Boolean is
     (Is_Required (Item)
      or else Item.PB_Type.Value = TYPE_MESSAGE
      or else (Item.Proto_3_Optional.Is_Set
               and then Item.Proto_3_Optional.Value)
      or else not Ctx.Is_Proto_3);

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

   function Wire_Kind (Item : Field_Descriptor) return Universal_String is
     (if Is_Fixed_32 (Item) then +Wire & "Fixed_32"
      elsif Is_Fixed_64 (Item) then +Wire & "Fixed_64"
      elsif Item.PB_Type.Value = TYPE_MESSAGE then +Wire & "Length_Delimited"
      else +Wire & "Varint");

   function Qualified
     (Type_Name : Universal_String;
      Name      : Universal_String;
      Ctx       : Context) return Universal_String;
   --  Return how to name an entity declared next to a type, from the package
   --  being generated

   function Type_Text
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String;

   function Default_Text
     (Item : Field_Descriptor;
      Ctx  : Context) return Universal_String;
   --  Return the initial value of the component, or "" for a message

   function To_Wire
     (Item  : Field_Descriptor;
      Ctx   : Context;
      Value : Universal_String) return Universal_String;
   --  Convert a component to the type used to encode it

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

   -------------
   -- Actuals --
   -------------

   function Actuals
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access
   is
      Value : constant Node := F.New_Argument_Association
        (F.New_Selected_Name ("V." & Component_Name (Item)));
   begin
      if Has_Flag_Parameter (Item, Ctx) then
         return F.New_List
           (F.New_Argument_Association
              (F.New_Selected_Name ("V." & Has_Name (Item))),
            Value);
      else
         return Value;
      end if;
   end Actuals;

   ----------
   -- Call --
   ----------

   function Call
     (Name      : Universal_String;
      Arguments : Wide_Wide_String) return Node
   is
      List : Node;
      Text : constant String_Vector := Universal_String'(+Arguments).Split
        ('|');
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
     (Item      : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Full_Name : League.Strings.Universal_String;
      Errors    : in out League.String_Vectors.Universal_String_Vector)
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
         Report ("repeated and map fields");
      elsif Compiler.Field_Descriptors.Is_One_Of (Item) then
         Report ("oneof fields");
      elsif Item.PB_Type.Value in TYPE_STRING | TYPE_BYTES then
         Report ("string and bytes fields");
      end if;
   end Check_Supported;

   -----------
   -- Clear --
   -----------

   function Clear
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access
   is
      Target : constant Node :=
        F.New_Selected_Name ("V." & Component_Name (Item));
      Result : Node;
   begin
      if Item.PB_Type.Value = TYPE_MESSAGE then
         Result := F.New_Statement
           (F.New_Apply
              (N (Qualified (Item.Type_Name.Value, +"Clear", Ctx)),
               F.New_Argument_Association (Target)));
      else
         Result := F.New_Assignment (Target, N (Default_Text (Item, Ctx)));
      end if;

      if Has_Presence (Item, Ctx) then
         Result := F.New_List
           (F.New_Assignment
              (F.New_Selected_Name ("V." & Has_Name (Item)), N (+"False")),
            Result);
      end if;

      return Result;
   end Clear;

   ---------------
   -- Component --
   ---------------

   function Component
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access
   is
      Default : constant Universal_String := Default_Text (Item, Ctx);
      Value   : constant Node := F.New_Variable
        (Name            => N (Component_Name (Item)),
         Type_Definition => F.New_Selected_Name (Type_Text (Item, Ctx)),
         Initialization  =>
           (if Default.Is_Empty then null else N (Default)));
   begin
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
   end Component;

   ---------------------
   -- Component_Names --
   ---------------------

   function Component_Names
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return League.String_Vectors.Universal_String_Vector
   is
      Result : String_Vector;
   begin
      Result.Append (Component_Name (Item));

      if Has_Presence (Item, Ctx) then
         Result.Append (Has_Name (Item));
      end if;

      return Result;
   end Component_Names;

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
            raise Program_Error;  --  Rejected by Check_Supported
      end case;
   end Default_Text;

   ------------
   -- Encode --
   ------------

   function Encode
     (Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Formal : constant Universal_String := Formal_Name (Item);
      Result : Node;
   begin
      if Item.PB_Type.Value = TYPE_MESSAGE then
         declare
            Max : constant Universal_String := Image
              (Compiler.Bounds.Max_Encoded_Size
                 (Bounds, Item.Type_Name.Value));
         begin
            Result := F.New_Block
              (Declarations => F.New_Variable
                 (Name            => N (+"Body_Last"),
                  Type_Definition => F.New_Selected_Name (+"PB_SPARK.Index")),
               Statements   => F.New_List
                 ((Call
                     (+Wire & "Reserve_Delimited",
                      Number (Item).To_Wide_Wide_String & "|"
                      & Max.To_Wide_Wide_String
                      & "|Buffer|Last|Body_Last"),
                   Call
                     (Qualified (Item.Type_Name.Value, +"Append", Ctx),
                      Formal.To_Wide_Wide_String & "|Buffer|Body_Last"),
                   Call
                     (+Wire & "Finish_Delimited",
                      Max.To_Wide_Wide_String & "|Body_Last|Buffer|Last"))));
         end;
      else
         declare
            Kind : constant Wide_Wide_String :=
              (if Is_Fixed_32 (Item) then "Fixed_32"
               elsif Is_Fixed_64 (Item) then "Fixed_64"
               else "Varint");
            Name : constant Wide_Wide_String :=
              (if Has_Presence (Item, Ctx) then "_Field" else "_Option");
         begin
            Result := Call
              (+Wire & "Put_" & Kind & Name,
               Number (Item).To_Wide_Wide_String & "|"
               & To_Wire (Item, Ctx, Formal).To_Wide_Wide_String
               & "|Buffer|Last");
         end;
      end if;

      if Has_Flag_Parameter (Item, Ctx) then
         Result := F.New_If
           (Condition => N ("F_" & Has_Name (Item)),
            Then_Path => Result);
      end if;

      return Result;
   end Encode;

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
     (Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis)
      return League.Strings.Universal_String
   is
      Nested : constant Boolean :=
        Item.PB_Type.Value = TYPE_MESSAGE
        and then Needs_Check (Item.Type_Name.Value, Bounds);
      Check  : constant Universal_String :=
        (if Nested
         then Qualified (Item.Type_Name.Value, +"Is_Initialized", Ctx)
           & " (V." & Component_Name (Item) & ")"
         else +"");
   begin
      if Is_Required (Item) then
         return "V." & Has_Name (Item)
           & (if Nested then " and then " & Check else +"");
      elsif Nested then
         return "(not V." & Has_Name (Item) & " or else " & Check & ")";
      else
         return +"";
      end if;
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
   -- Merge --
   -----------

   function Merge
     (Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Target : constant Universal_String := "V." & Component_Name (Item);
      Has    : constant Universal_String := "V." & Has_Name (Item);
      Set_Has : constant Node :=
        F.New_Assignment (F.New_Selected_Name (Has), N (+"True"));
      Arrived : constant Universal_String :=
        "Status = PB_SPARK.OK and then Wire in " & Wire_Kind (Item);
      Name   : constant Wide_Wide_String :=
        (if Is_Fixed_32 (Item) then "Read_Fixed_32_Field"
         elsif Is_Fixed_64 (Item) then "Read_Fixed_64_Field"
         else "Read_Varint_Field");
      Read   : constant Node := Call
        (+Wire & Name,
         "Buffer|Limit|Field|Wire|Pos|"
         & (if Is_Direct (Item) then Target.To_Wide_Wide_String else "Raw")
         & "|Status");
   begin
      --  Ada_Pretty doesn't print "else", so other wire types are skipped
      --  first, and Known and not Known are tested apart.
      if Item.PB_Type.Value = TYPE_MESSAGE then
         return F.New_List
          (F.New_If
             (Condition => N ("Wire not in " & Wire_Kind (Item)),
              Then_Path => F.New_List
                (Call
                   (+Wire & "Skip_Field",
                    "Buffer|Limit|Field|Wire|Pos|Status"),
                 F.New_Return)),
           F.New_Block
              (Declarations => F.New_Variable
                 (Name            => N (+"Inner"),
                  Type_Definition => F.New_Selected_Name (+"PB_SPARK.Index")),
               Statements   => F.New_List
                 (Call
                    (+Wire & "Get_Delimited",
                     "Buffer|Limit|Pos|Inner|Status"),
                  F.New_If
                    (Condition => N (+"Status = PB_SPARK.OK"),
                     Then_Path => F.New_List
                       (Call
                          (Qualified (Item.Type_Name.Value, +"Merge", Ctx),
                           "Buffer|Inner|Pos|" & Target.To_Wide_Wide_String
                           & "|Status"),
                        F.New_If
                          (Condition => N (+"Status = PB_SPARK.OK"),
                           Then_Path => F.New_List
                             (F.New_Assignment
                                (N (+"Pos"), N (+"Inner + 1")),
                              Set_Has)))))));
      elsif Item.PB_Type.Value = TYPE_ENUM then
         declare
            Key     : constant Universal_String := Item.Type_Name.Value;
            Policy  : constant Compiler.Options.Unknown_Enum_Policy :=
              Compiler.Bounds.Field
                (Bounds, Ctx.Message & "." & Item.Name.Value).On_Unknown_Enum;
            Convert : constant Node := Call
              (Qualified
                 (Key,
                  Compiler.Context.Named_Types (Key).Ada_Type.Type_Name
                  & "_From_Wire",
                  Ctx),
               Wire & "To_Integer_32 (Raw)|" & Target.To_Wide_Wide_String
               & "|Known");
            Unknown : Node;
            Known   : Node;
         begin
            --  Enums of proto3 accept any value, but an Ada enumeration
            --  can't hold one it doesn't define, so the policy decides.
            --  Unknown values of proto2 enums are unknown fields.
            if not Ctx.Is_Proto_3 then
               null;
            elsif Policy = Compiler.Options.Reject then
               Unknown := F.New_Assignment
                 (N (+"Status"), F.New_Selected_Name (+"PB_SPARK.Unknown_Enum"));
            else
               Unknown := F.New_Assignment
                 (F.New_Selected_Name (Target), N (Default_Text (Item, Ctx)));

               if Has_Presence (Item, Ctx) then
                  Unknown := F.New_List (Unknown, Set_Has);
               end if;
            end if;

            if Has_Presence (Item, Ctx) then
               Known := Set_Has;
            end if;

            return F.New_Block
              (Declarations => F.New_List
                 (F.New_Variable
                    (Name            => N (+"Raw"),
                     Type_Definition => F.New_Selected_Name
                       (+"Interfaces.Unsigned_64"),
                     Initialization  => N (To_Wire (Item, Ctx, Target))),
                  F.New_Variable
                    (Name            => N (+"Known"),
                     Type_Definition => N (+"Boolean"))),
               Statements   => F.New_List
                 (Read,
                  F.New_If
                    (Condition => N (Arrived),
                     Then_Path => F.New_List
                       (Convert,
                        (if Known = null
                         then F.New_If
                           (Condition => N (+"not Known"),
                            Then_Path => Unknown)
                         elsif Unknown = null
                         then F.New_If
                           (Condition => N (+"Known"),
                            Then_Path => Known)
                         else F.New_List
                           (F.New_If
                              (Condition => N (+"Known"),
                               Then_Path => Known),
                            F.New_If
                              (Condition => N (+"not Known"),
                               Then_Path => Unknown)))))));
         end;
      end if;

      declare
         Result : Node;
      begin
         if Is_Direct (Item) then
            Result := Read;
         else
            --  Raw starts as the current value, so if the field is skipped
            --  because it has another wire type then the component is left
            --  as it was.
            Result := F.New_Block
              (Declarations => F.New_Variable
                 (Name            => N (+"Raw"),
                  Type_Definition => F.New_Selected_Name
                    (if Is_Fixed_32 (Item) then +"Interfaces.Unsigned_32"
                     else +"Interfaces.Unsigned_64"),
                  Initialization  => N (To_Wire (Item, Ctx, Target))),
               Statements   => F.New_List
                 (Read,
                  F.New_Assignment
                    (F.New_Selected_Name (Target),
                     N (From_Wire (Item, +"Raw")))));
         end if;

         if Has_Presence (Item, Ctx) then
            Result := F.New_List
              (Result,
               F.New_If (Condition => N (Arrived), Then_Path => Set_Has));
         end if;

         return Result;
      end;
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
            elsif Is_Required (Item) then
               return True;
            elsif Item.PB_Type.Value = TYPE_MESSAGE
              and then not (Item.Label.Is_Set
                            and then Item.Label.Value = LABEL_REPEATED)
              and then Needs_Check (Item.Type_Name.Value, Bounds)
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Needs_Check;

   ------------
   -- Number --
   ------------

   function Number (Item : Field_Descriptor) return Universal_String is
     (Image (Natural (Item.Number.Value)));

   ----------------
   -- Parameters --
   ----------------

   function Parameters
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access
   is
      Value : constant Node := F.New_Parameter
        (Name            => N (Formal_Name (Item)),
         Type_Definition => F.New_Selected_Name (Type_Text (Item, Ctx)));
   begin
      if Has_Flag_Parameter (Item, Ctx) then
         return F.New_List
           (F.New_Parameter
              (Name            => N ("F_" & Has_Name (Item)),
               Type_Definition => N (+"Boolean")),
            Value);
      else
         return Value;
      end if;
   end Parameters;

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
         return Compiler.Context.Relative_Name
           (Owner & "." & Name, Ctx.Package_Name);
      end if;
   end Qualified;

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

   ---------------
   -- Type_Text --
   ---------------

   function Type_Text
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
               return Compiler.Context.Relative_Name
                 (Compiler.Context."+" (Named), Ctx.Package_Name);
            end;
         when TYPE_STRING | TYPE_BYTES | TYPE_GROUP =>
            raise Program_Error;  --  Rejected by Check_Supported
      end case;
   end Type_Text;

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

end Compiler.SPARK_Fields;

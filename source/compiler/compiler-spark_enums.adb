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
with Ada.Containers.Ordered_Sets;

with League.Strings.Hash;

with Compiler.Context;
with Compiler.Enum_Descriptors;

package body Compiler.SPARK_Enums is

   use type League.Strings.Universal_String;

   subtype Universal_String is League.Strings.Universal_String;
   subtype Enum_Descriptor is Google.Protobuf.Descriptor.Enum_Descriptor_Proto;
   subtype Node is Ada_Pretty.Node_Access;

   F : Ada_Pretty.Factory renames Compiler.Context.Factory;

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   function N (Text : Universal_String) return Node is (F.New_Name (Text));

   package Enum_Maps is new Ada.Containers.Hashed_Maps
     (Universal_String,
      Enum_Descriptor,
      League.Strings.Hash,
      League.Strings."=",
      Google.Protobuf.Descriptor."=");

   Enums : Enum_Maps.Map;

   type Item is record
      Value : Integer;
      Name  : Universal_String;
   end record;

   function Less (Left, Right : Item) return Boolean is
     (Left.Value < Right.Value
      or else (Left.Value = Right.Value and then Left.Name < Right.Name));

   package Item_Sets is new Ada.Containers.Ordered_Sets (Item, Less);

   procedure Get_Items
     (Self    : Enum_Descriptor;
      Name    : Universal_String;
      Values  : out Item_Sets.Set;
      Aliases : out Item_Sets.Set);
   --  Return the literals of a type and the aliases of literals. Aliases are
   --  stored with the name of the literal they stand for in Value's place.

   function Type_Name
     (Self   : Enum_Descriptor;
      Prefix : Universal_String) return Universal_String is
     (Compiler.Context.Named_Types
        (Compiler.Context.Join (Prefix, Self.Name)).Ada_Type.Type_Name);

   function Number (Value : Integer) return Universal_String;
   --  Return a static expression of type Interfaces.Integer_32. Negative
   --  values are written with an expanded operator, so units don't need a
   --  use clause.

   ---------------
   -- Get_Items --
   ---------------

   procedure Get_Items
     (Self    : Enum_Descriptor;
      Name    : Universal_String;
      Values  : out Item_Sets.Set;
      Aliases : out Item_Sets.Set)
   is
      All_Items : Item_Sets.Set;
      Done      : Compiler.Context.String_Sets.Set;
      First     : Boolean := True;
      Previous  : Item;
   begin
      for J in 1 .. Self.Value.Length loop
         All_Items.Include
           ((Value => Integer (Self.Value (J).Number.Value),
             Name  => Compiler.Enum_Descriptors.Literal_Name
               (Self, J, Name)));
      end loop;

      --  The same choices as the code generated for the League runtime
      for J of All_Items loop
         if Done.Contains (J.Name.To_Lowercase) then
            null;  --  Skip a name that differs only in character case
         elsif not First and Previous.Value = J.Value then
            Done.Insert (J.Name.To_Lowercase);
            Aliases.Include (J);
         else
            Done.Insert (J.Name.To_Lowercase);
            Values.Include (J);
            Previous := J;
         end if;

         First := False;
      end loop;
   end Get_Items;

   -------------
   -- Literal --
   -------------

   function Literal
     (Type_Name  : League.Strings.Universal_String;
      Value_Name : League.Strings.Universal_String)
      return League.Strings.Universal_String
   is
      Self : constant Enum_Descriptor := Enums (Type_Name);
      Name : constant Universal_String :=
        Compiler.Context.Named_Types (Type_Name).Ada_Type.Type_Name;
   begin
      for J in 1 .. Self.Value.Length loop
         if Self.Value (J).Name.Value = Value_Name then
            return Compiler.Enum_Descriptors.Literal_Name (Self, J, Name);
         end if;
      end loop;

      raise Constraint_Error with "unknown enum value";
   end Literal;

   ------------
   -- Number --
   ------------

   function Number (Value : Integer) return Universal_String is
      Text : constant Wide_Wide_String := Integer'Wide_Wide_Image (abs Value);
      Digits_Only : constant Universal_String := +Text (2 .. Text'Last);
   begin
      if Value < 0 then
         return "Interfaces.""-"" (" & Digits_Only & ")";
      else
         return Digits_Only;
      end if;
   end Number;

   -----------------
   -- Public_Spec --
   -----------------

   function Public_Spec
     (Self   : Google.Protobuf.Descriptor.Enum_Descriptor_Proto;
      Prefix : League.Strings.Universal_String)
      return Ada_Pretty.Node_Access
   is
      Name    : constant Universal_String := Type_Name (Self, Prefix);
      Values  : Item_Sets.Set;
      Aliases : Item_Sets.Set;
      Literal : Node;
      Clause  : Node;
      Result  : Node;
   begin
      Get_Items (Self, Name, Values, Aliases);

      for J of Values loop
         Literal := F.New_List
           (Literal, F.New_Argument_Association (N (J.Name)));
         Clause := F.New_List
           (Clause,
            F.New_Argument_Association
              (Choice => N (J.Name),
               Value  => Compiler.Enum_Descriptors.Get_Literal (J.Value)));
      end loop;

      Result := F.New_List
        (F.New_Type
           (Name       => N (Name),
            Definition => F.New_Parentheses (Literal)),
         F.New_Statement (F.New_Apply (N ("for " & Name & " use"), Clause)));

      for J of Aliases loop
         for V of Values loop
            if V.Value = J.Value then
               Result := F.New_List
                 (Result,
                  F.New_Subprogram_Declaration
                    (Specification => F.New_Subprogram_Specification
                       (Name   => N (J.Name),
                        Result => N (Name)),
                     Expression    => N (V.Name)));
            end if;
         end loop;
      end loop;

      return F.New_List
        ((Result,
          F.New_Subprogram_Declaration
            (Specification => F.New_Subprogram_Specification
               (Name       => N (Name & "_To_Wire"),
                Parameters => F.New_Parameter
                  (Name            => N (+"Value"),
                   Type_Definition => N (Name)),
                Result     => F.New_Selected_Name
                  (+"Interfaces.Integer_32"))),
          F.New_Subprogram_Declaration
            (Specification => F.New_Subprogram_Specification
               (Name       => N (Name & "_From_Wire"),
                Parameters => F.New_List
                  ((F.New_Parameter
                      (Name            => N (+"Raw"),
                       Type_Definition => F.New_Selected_Name
                         (+"Interfaces.Integer_32")),
                    F.New_Parameter
                      (Name            => N (+"Value"),
                       Type_Definition => N (Name),
                       Is_In           => True,
                       Is_Out          => True),
                    F.New_Parameter
                      (Name            => N (+"Known"),
                       Type_Definition => N (+"Boolean"),
                       Is_Out          => True)))),
             Comment       => +"Set Known to False and keep Value if Raw is "
               & "not a value of the type")));
   end Public_Spec;

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
         for J in 1 .. Item.Enum_Type.Length loop
            Enums.Include
              (Compiler.Context.Join (Key, Item.Enum_Type (J).Name),
               Item.Enum_Type (J));
         end loop;

         for J in 1 .. Item.Nested_Type.Length loop
            Add (Key, Item.Nested_Type (J));
         end loop;
      end Add;

   begin
      for J in 1 .. Request.Proto_File.Length loop
         declare
            File   : constant Google.Protobuf.Descriptor.File_Descriptor_Proto
              := Request.Proto_File (J);
            Prefix : Universal_String;
         begin
            if File.PB_Package.Is_Set then
               Prefix := "." & File.PB_Package.Value;
            end if;

            for K in 1 .. File.Enum_Type.Length loop
               Enums.Include
                 (Compiler.Context.Join (Prefix, File.Enum_Type (K).Name),
                  File.Enum_Type (K));
            end loop;

            for K in 1 .. File.Message_Type.Length loop
               Add (Prefix, File.Message_Type (K));
            end loop;
         end;
      end loop;
   end Register;

   -----------------
   -- Subprograms --
   -----------------

   function Subprograms
     (Self   : Google.Protobuf.Descriptor.Enum_Descriptor_Proto;
      Prefix : League.Strings.Universal_String)
      return Ada_Pretty.Node_Access
   is
      Name    : constant Universal_String := Type_Name (Self, Prefix);
      Values  : Item_Sets.Set;
      Aliases : Item_Sets.Set;
      To_Wire : Node;
      From    : Node;
   begin
      Get_Items (Self, Name, Values, Aliases);

      for J of Values loop
         To_Wire := F.New_List
           (To_Wire,
            F.New_Case_Path
              (Choice => N (J.Name),
               List   => F.New_Return (N (Number (J.Value)))));
         From := F.New_List
           (From,
            F.New_Case_Path
              (Choice => N (Number (J.Value)),
               List   => F.New_Assignment (N (+"Value"), N (J.Name))));
      end loop;

      From := F.New_List
        (From,
         F.New_Case_Path
           (Choice => N (+"others"),
            List   => F.New_Assignment (N (+"Known"), N (+"False"))));

      return F.New_List
        (F.New_Subprogram_Body
           (Specification => F.New_Subprogram_Specification
              (Name       => N (Name & "_To_Wire"),
               Parameters => F.New_Parameter
                 (Name            => N (+"Value"),
                  Type_Definition => N (Name)),
               Result     => F.New_Selected_Name (+"Interfaces.Integer_32")),
            Statements    => F.New_Case (N (+"Value"), To_Wire)),
         F.New_Subprogram_Body
           (Specification => F.New_Subprogram_Specification
              (Name       => N (Name & "_From_Wire"),
               Parameters => F.New_List
                 ((F.New_Parameter
                     (Name            => N (+"Raw"),
                      Type_Definition => F.New_Selected_Name
                        (+"Interfaces.Integer_32")),
                   F.New_Parameter
                     (Name            => N (+"Value"),
                      Type_Definition => N (Name),
                      Is_In           => True,
                      Is_Out          => True),
                   F.New_Parameter
                     (Name            => N (+"Known"),
                      Type_Definition => N (+"Boolean"),
                      Is_Out          => True)))),
            Statements    => F.New_List
              (F.New_Assignment (N (+"Known"), N (+"True")),
               F.New_Case (N (+"Raw"), From))));
   end Subprograms;

end Compiler.SPARK_Enums;

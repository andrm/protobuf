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

with Ada.Characters.Wide_Wide_Latin_1;
with Ada.Containers.Vectors;

with Ada_Pretty;

with League.Strings;

with Google.Protobuf.Descriptor;

with Compiler.Context;
with Compiler.File_Descriptors;
with Compiler.SPARK_Enums;
with Compiler.SPARK_Fields;
with Compiler.SPARK_Messages;

package body Compiler.SPARK_Files is

   use type League.Strings.Universal_String;
   use type Google.Protobuf.Descriptor.PB_Type;

   subtype Universal_String is League.Strings.Universal_String;
   subtype String_Vector is League.String_Vectors.Universal_String_Vector;
   subtype File_Descriptor is
     Google.Protobuf.Descriptor.File_Descriptor_Proto;
   subtype Message_Descriptor is Google.Protobuf.Descriptor.Descriptor_Proto;
   subtype Node is Ada_Pretty.Node_Access;

   F : Ada_Pretty.Factory renames Compiler.Context.Factory;

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   LF : constant Wide_Wide_Character := Ada.Characters.Wide_Wide_Latin_1.LF;

   type Message_Item is record
      Descriptor : Message_Descriptor;
      Prefix     : Universal_String;  --  Type name of the enclosing scope
   end record;

   package Message_Vectors is new Ada.Containers.Vectors
     (Positive, Message_Item);

   type Enum_Item is record
      Descriptor : Google.Protobuf.Descriptor.Enum_Descriptor_Proto;
      Prefix     : Universal_String;
   end record;

   package Enum_Vectors is new Ada.Containers.Vectors (Positive, Enum_Item);

   function SPARK_Pragma return Node is
     (F.New_Pragma (F.New_Name (+"SPARK_Mode"), F.New_Name (+"On")));

   procedure Add_Lines
     (Text   : in out String_Vector;
      Item   : Node;
      Indent : Boolean := True);
   --  Render a declaration and append it to Text, followed by an empty line

   procedure Collect
     (File     : File_Descriptor;
      Bounds   : Compiler.Bounds.Analysis;
      Messages : out Message_Vectors.Vector;
      Enums    : out Enum_Vectors.Vector);
   --  Return all types of a file. A message comes after the messages of the
   --  same file that its fields use, because Ada needs them declared first.

   procedure Check_Supported
     (File     : File_Descriptor;
      Messages : Message_Vectors.Vector;
      Enums    : Enum_Vectors.Vector;
      Bounds   : Compiler.Bounds.Analysis;
      Errors   : in out League.String_Vectors.Universal_String_Vector);

   function Clauses
     (File     : File_Descriptor;
      Messages : Message_Vectors.Vector;
      Bounds   : Compiler.Bounds.Analysis) return Node;
   --  Return context clauses of the units of a file

   procedure Declared_Names
     (File         : File_Descriptor;
      Messages     : Message_Vectors.Vector;
      Enums        : Enum_Vectors.Vector;
      Bounds       : Compiler.Bounds.Analysis;
      Types        : out String_Vector;
      Overloadable : out String_Vector);
   --  Return names that the package of a file declares: names of types and
   --  constants, and names that can be overloaded

   function Full_Name
     (Prefix : Universal_String;
      Name   : Universal_String) return Universal_String is
     (Universal_String'(Prefix & "." & Name).Tail_From (2));

   function Is_Proto_3 (File : File_Descriptor) return Boolean is
     (File.Syntax.Is_Set and then File.Syntax.Value = +"proto3");

   ---------------
   -- Add_Lines --
   ---------------

   procedure Add_Lines
     (Text   : in out String_Vector;
      Item   : Node;
      Indent : Boolean := True)
   is
      Lines : constant String_Vector := F.To_Text (Item);
      Seen  : Boolean := False;
   begin
      for J in 1 .. Lines.Length loop
         if not Lines (J).Is_Empty then
            Seen := True;
            Text.Append (if Indent then "   " & Lines (J) else Lines (J));
         elsif Seen then
            Text.Append (Lines (J));
         end if;
      end loop;

      Text.Append (+"");
   end Add_Lines;

   ---------------------
   -- Check_Supported --
   ---------------------

   procedure Check_Supported
     (File     : File_Descriptor;
      Messages : Message_Vectors.Vector;
      Enums    : Enum_Vectors.Vector;
      Bounds   : Compiler.Bounds.Analysis;
      Errors   : in out League.String_Vectors.Universal_String_Vector)
   is
      Package_Name : constant Universal_String :=
        Compiler.File_Descriptors.Package_Name (File);
      Types        : String_Vector;
      Overloadable : String_Vector;
      Type_Names   : Compiler.Context.String_Sets.Set;
      Reported     : Compiler.Context.String_Sets.Set;

      procedure Report (Name : Universal_String; Text : Wide_Wide_String);

      procedure Report (Name : Universal_String; Text : Wide_Wide_String) is
      begin
         if not Reported.Contains (Name.To_Lowercase) then
            Reported.Insert (Name.To_Lowercase);
            Errors.Append (Package_Name & ": " & Name & Text);
         end if;
      end Report;

   begin
      for Item of Messages loop
         declare
            Message : constant Message_Descriptor := Item.Descriptor;
            Ctx     : constant Compiler.SPARK_Fields.Context :=
              Compiler.SPARK_Messages.Make_Context
                (Message, Item.Prefix, Package_Name, Is_Proto_3 (File));
            Names   : Compiler.Context.String_Sets.Set;
         begin
            for Next of Compiler.SPARK_Fields.Items (Message, Ctx, Bounds) loop
               Compiler.SPARK_Fields.Check_Supported
                 (Next, Ctx, Bounds, Errors);

               declare
                  List : constant String_Vector :=
                    Compiler.SPARK_Fields.Component_Names (Next, Ctx);
                  Name : constant Universal_String :=
                    Ctx.Message & "."
                    & (if Next.Is_Oneof then Next.Name
                       else Next.Fields.First_Element.Name.Value);
               begin
                  for C in 1 .. List.Length loop
                     if Names.Contains (List (C).To_Lowercase) then
                        Errors.Append
                          (Name & ": its Ada component " & List (C)
                           & " clashes with another field: add "
                           & "type:ignore to one of them");
                     else
                        Names.Insert (List (C).To_Lowercase);
                     end if;
                  end loop;
               end;
            end loop;
         end;
      end loop;

      Declared_Names (File, Messages, Enums, Bounds, Types, Overloadable);

      --  Types and constants can't share a name with anything else, while
      --  subprograms and enumeration literals can be overloaded
      for J in 1 .. Types.Length loop
         if Type_Names.Contains (Types (J).To_Lowercase) then
            Report (Types (J), " would be declared twice");
         else
            Type_Names.Insert (Types (J).To_Lowercase);
         end if;
      end loop;

      for Name of Compiler.SPARK_Messages.Subprogram_Names loop
         if Type_Names.Contains (+Name.all) then
            Errors.Append
              (Package_Name
               & ": a message can't be named like a generated subprogram ("
               & (+Name.all) & ")");
            Reported.Include (+Name.all);
         end if;
      end loop;

      for J in 1 .. Overloadable.Length loop
         if Type_Names.Contains (Overloadable (J).To_Lowercase) then
            Report
              (Overloadable (J),
               " would name a type and a subprogram or literal");
         end if;
      end loop;
   end Check_Supported;

   -------------
   -- Clauses --
   -------------

   function Clauses
     (File     : File_Descriptor;
      Messages : Message_Vectors.Vector;
      Bounds   : Compiler.Bounds.Analysis) return Node
   is
      Own    : constant Universal_String :=
        Compiler.File_Descriptors.Package_Name (File);
      Imported : Compiler.Context.String_Sets.Set;
      Result : Node := F.New_With (F.New_Selected_Name (+"Interfaces"));
   begin
      if Messages.Is_Empty then
         return Result;
      end if;

      for Item of Messages loop
         for K in 1 .. Item.Descriptor.Field.Length loop
            declare
               Field : constant
                 Google.Protobuf.Descriptor.Field_Descriptor_Proto :=
                   Item.Descriptor.Field (K);
               Owner : constant Universal_String :=
                 Compiler.SPARK_Fields.Type_Package (Field);
            begin
               if not Owner.Is_Empty
                 and then Owner /= Own
                 and then not Compiler.Bounds.Field
                   (Bounds,
                    Full_Name (Item.Prefix, Item.Descriptor.Name.Value)
                    & "." & Field.Name.Value).Ignored
               then
                  Imported.Include (Owner);
               end if;
            end;
         end loop;
      end loop;

      Result := F.New_List
        (Result,
         F.New_List
           ((F.New_With (F.New_Selected_Name (+"PB_SPARK")),
             F.New_With (F.New_Selected_Name (+"PB_SPARK.Wire")))));

      for Name of Imported loop
         Result := F.New_List (Result, F.New_With (F.New_Selected_Name (Name)));
      end loop;

      return F.New_List
        (Result,
         F.New_List
           (F.New_Use
              (F.New_Selected_Name (+"PB_SPARK.Index"), Use_Type => True),
            F.New_Use
              (F.New_Selected_Name (+"PB_SPARK.Status_Kind"),
               Use_Type => True)));
   end Clauses;

   --------------------
   -- Declared_Names --
   --------------------

   procedure Declared_Names
     (File         : File_Descriptor;
      Messages     : Message_Vectors.Vector;
      Enums        : Enum_Vectors.Vector;
      Bounds       : Compiler.Bounds.Analysis;
      Types        : out String_Vector;
      Overloadable : out String_Vector)
   is
      Package_Name : constant Universal_String :=
        Compiler.File_Descriptors.Package_Name (File);
   begin
      Types.Clear;
      Overloadable.Clear;

      for Item of Messages loop
         Compiler.SPARK_Messages.Declared_Names
           (Item.Descriptor,
            Item.Prefix,
            Compiler.SPARK_Messages.Make_Context
              (Item.Descriptor, Item.Prefix, Package_Name, Is_Proto_3 (File)),
            Bounds,
            Types,
            Overloadable);
      end loop;

      for Enum of Enums loop
         Compiler.SPARK_Enums.Declared_Names
           (Enum.Descriptor, Enum.Prefix, Types, Overloadable);
      end loop;

      for Name of Compiler.SPARK_Messages.Subprogram_Names loop
         Overloadable.Append (+Name.all);
      end loop;
   end Declared_Names;

   -------------
   -- Collect --
   -------------

   procedure Collect
     (File     : File_Descriptor;
      Bounds   : Compiler.Bounds.Analysis;
      Messages : out Message_Vectors.Vector;
      Enums    : out Enum_Vectors.Vector)
   is
      All_Messages : Message_Vectors.Vector;
      Done         : Compiler.Context.String_Sets.Set;
      Skipped      : Compiler.Context.String_Sets.Set;

      procedure Add (Prefix : Universal_String; Item : Message_Descriptor);
      procedure Place (Item : Message_Item);

      ---------
      -- Add --
      ---------

      procedure Add (Prefix : Universal_String; Item : Message_Descriptor) is
         Key : constant Universal_String := Prefix & "." & Item.Name.Value;
      begin
         --  A map entry gets a type if a map field uses it. Groups are only
         --  reachable through fields that are reported or ignored.
         if Item.Options.Is_Set
           and then Item.Options.Value.Map_Entry.Is_Set
           and then Item.Options.Value.Map_Entry.Value
           and then not Compiler.Bounds.Is_Sized (Bounds, Key)
         then
            Skipped.Include (Key);
         else
            All_Messages.Append ((Item, Prefix));
         end if;

         for J in 1 .. Item.Field.Length loop
            if Item.Field (J).PB_Type.Value =
              Google.Protobuf.Descriptor.TYPE_GROUP
            then
               Skipped.Include (Item.Field (J).Type_Name.Value);
            end if;
         end loop;

         for J in 1 .. Item.Enum_Type.Length loop
            Enums.Append ((Item.Enum_Type (J), Key));
         end loop;

         for J in 1 .. Item.Nested_Type.Length loop
            Add (Key, Item.Nested_Type (J));
         end loop;
      end Add;

      -----------
      -- Place --
      -----------

      procedure Place (Item : Message_Item) is
         Key : constant Universal_String :=
           Item.Prefix & "." & Item.Descriptor.Name.Value;
      begin
         if Done.Contains (Key) or Skipped.Contains (Key) then
            return;
         end if;

         Done.Insert (Key);

         --  Cycles are rejected before this, so this always ends
         for J in 1 .. Item.Descriptor.Field.Length loop
            declare
               Field : constant
                 Google.Protobuf.Descriptor.Field_Descriptor_Proto :=
                   Item.Descriptor.Field (J);
            begin
               if Field.Type_Name.Is_Set then
                  for Other of All_Messages loop
                     if Other.Prefix & "." & Other.Descriptor.Name.Value
                       = Field.Type_Name.Value
                     then
                        Place (Other);
                     end if;
                  end loop;
               end if;
            end;
         end loop;

         Messages.Append (Item);
      end Place;

      Prefix : constant Universal_String :=
        Compiler.File_Descriptors.Get_Prefix (File);
   begin
      Messages.Clear;
      Enums.Clear;

      for J in 1 .. File.Enum_Type.Length loop
         Enums.Append ((File.Enum_Type (J), Prefix));
      end loop;

      for J in 1 .. File.Message_Type.Length loop
         Add (Prefix, File.Message_Type (J));
      end loop;

      for Item of All_Messages loop
         Place (Item);
      end loop;
   end Collect;

   --------------
   -- Generate --
   --------------

   procedure Generate
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request;
      Bounds  : Compiler.Bounds.Analysis;
      Result  : in out Google.Protobuf.Compiler.Plugin.Code_Generator_Response;
      Errors  : in out League.String_Vectors.Universal_String_Vector)
   is
      Found : constant Natural := Errors.Length;
   begin
      Compiler.SPARK_Fields.Register (Request);

      for J in 1 .. Request.File_To_Generate.Length loop
         declare
            File     : constant File_Descriptor := Compiler.Context.Get_File
              (Request, Request.File_To_Generate.Element (J));
            Messages : Message_Vectors.Vector;
            Enums    : Enum_Vectors.Vector;
         begin
            Collect (File, Bounds, Messages, Enums);
            Check_Supported (File, Messages, Enums, Bounds, Errors);
         end;
      end loop;

      if Errors.Length /= Found then
         return;
      end if;

      for J in 1 .. Request.File_To_Generate.Length loop
         declare
            File     : constant File_Descriptor := Compiler.Context.Get_File
              (Request, Request.File_To_Generate.Element (J));
            Base     : constant Universal_String :=
              Compiler.File_Descriptors.File_Name (File);
            Name     : constant Universal_String :=
              Compiler.File_Descriptors.Package_Name (File);
            Messages : Message_Vectors.Vector;
            Enums    : Enum_Vectors.Vector;
            Spec     : String_Vector;
            Impl     : String_Vector;
            Context  : Node;
            Item     : Google.Protobuf.Compiler.Plugin.File;
         begin
            Collect (File, Bounds, Messages, Enums);

            declare
               Types        : String_Vector;
               Overloadable : String_Vector;
            begin
               Declared_Names
                 (File, Messages, Enums, Bounds, Types, Overloadable);
               Types.Append (Overloadable);
               Compiler.SPARK_Fields.Set_Package_Names (Types);
            end;

            Context := Clauses (File, Messages, Bounds);

            Add_Lines (Spec, Context, Indent => False);
            Spec.Append ("package " & Name & " is");
            Spec.Append (+"");
            Add_Lines (Spec, SPARK_Pragma);

            for Enum of Enums loop
               Add_Lines
                 (Spec,
                  Compiler.SPARK_Enums.Public_Spec
                    (Enum.Descriptor, Enum.Prefix));
            end loop;

            for Message of Messages loop
               Add_Lines
                 (Spec,
                  Compiler.SPARK_Messages.Public_Spec
                    (Message.Descriptor, Message.Prefix, Name,
                     Is_Proto_3 (File), Bounds));
            end loop;

            Spec.Append ("end " & Name & ";");

            Item.Name := (True, Base & ".ads");
            Item.Content := (True, Spec.Join (LF));
            Result.File.Append (Item);

            if not Messages.Is_Empty or not Enums.Is_Empty then
               Add_Lines (Impl, Context, Indent => False);
               Impl.Append ("package body " & Name & " is");
               Impl.Append (+"");
               Add_Lines (Impl, SPARK_Pragma);

               for Enum of Enums loop
                  Add_Lines
                    (Impl,
                     Compiler.SPARK_Enums.Subprograms
                       (Enum.Descriptor, Enum.Prefix));
               end loop;

               for Message of Messages loop
                  for Next of Compiler.SPARK_Messages.Subprograms
                    (Message.Descriptor, Message.Prefix, Name,
                     Is_Proto_3 (File), Bounds)
                  loop
                     Add_Lines (Impl, Next);
                  end loop;
               end loop;

               Impl.Append ("end " & Name & ";");

               Item.Name := (True, Base & ".adb");
               Item.Content := (True, Impl.Join (LF));
               Result.File.Append (Item);
            end if;
         end;
      end loop;
   end Generate;

end Compiler.SPARK_Files;

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

with Ada_Pretty;

with League.Strings;

with Google.Protobuf.Descriptor;

with Compiler.Context;
with Compiler.File_Descriptors;
with Compiler.SPARK_Fields;
with Compiler.SPARK_Messages;

package body Compiler.SPARK_Files is

   use type League.Strings.Universal_String;

   subtype Universal_String is League.Strings.Universal_String;
   subtype String_Vector is League.String_Vectors.Universal_String_Vector;
   subtype File_Descriptor is
     Google.Protobuf.Descriptor.File_Descriptor_Proto;
   subtype Node is Ada_Pretty.Node_Access;

   F : Ada_Pretty.Factory renames Compiler.Context.Factory;

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   LF : constant Wide_Wide_Character := Ada.Characters.Wide_Wide_Latin_1.LF;

   function SPARK_Pragma return Node is
     (F.New_Pragma (F.New_Name (+"SPARK_Mode"), F.New_Name (+"On")));

   function Clauses (Runtime_Units : Wide_Wide_String) return Node;
   --  Return with clauses of a generated unit

   procedure Check_Supported
     (File   : File_Descriptor;
      Bounds : Compiler.Bounds.Analysis;
      Errors : in out League.String_Vectors.Universal_String_Vector);

   procedure Add_Lines
     (Text   : in out String_Vector;
      Item   : Node;
      Indent : Boolean := True);
   --  Render a declaration and append it to Text, followed by an empty line

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
     (File   : File_Descriptor;
      Bounds : Compiler.Bounds.Analysis;
      Errors : in out League.String_Vectors.Universal_String_Vector)
   is
      Prefix : constant Universal_String :=
        Compiler.File_Descriptors.Get_Prefix (File);
      Is_Proto_3 : constant Boolean :=
        File.Syntax.Is_Set and then File.Syntax.Value = +"proto3";
   begin
      for J in 1 .. File.Enum_Type.Length loop
         Errors.Append
           (Prefix & "." & File.Enum_Type (J).Name.Value
            & ": enums are not supported by the SPARK back end yet");
      end loop;

      for J in 1 .. File.Message_Type.Length loop
         declare
            Message : constant Google.Protobuf.Descriptor.Descriptor_Proto :=
              File.Message_Type (J);
            Full    : constant Universal_String :=
              Universal_String'(Prefix & "." & Message.Name.Value).Tail_From
                (2);
         begin
            if Message.Nested_Type.Length > 0
              or else Message.Enum_Type.Length > 0
            then
               Errors.Append
                 (Full & ": nested types are not supported by the SPARK "
                  & "back end yet");
            end if;

            for K in 1 .. Message.Field.Length loop
               declare
                  Name : constant Universal_String :=
                    Full & "." & Message.Field (K).Name.Value;
               begin
                  if not Compiler.Bounds.Field (Bounds, Name).Ignored then
                     Compiler.SPARK_Fields.Check_Supported
                       (Message.Field (K), Name, Is_Proto_3, Errors);
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Check_Supported;

   -------------
   -- Clauses --
   -------------

   function Clauses (Runtime_Units : Wide_Wide_String) return Node is
     (F.New_List
        ((F.New_With (F.New_Selected_Name (+"Interfaces")),
          F.New_With (F.New_Selected_Name (+Runtime_Units)),
          F.New_With (F.New_Selected_Name (+"PB_SPARK.Wire")),
          F.New_Use
            (F.New_Selected_Name (+"PB_SPARK.Index"), Use_Type => True),
          F.New_Use
            (F.New_Selected_Name (+"PB_SPARK.Status_Kind"),
             Use_Type => True))));

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
      for J in 1 .. Request.File_To_Generate.Length loop
         Check_Supported
           (Compiler.Context.Get_File
              (Request, Request.File_To_Generate.Element (J)),
            Bounds,
            Errors);
      end loop;

      if Errors.Length /= Found then
         return;
      end if;

      for J in 1 .. Request.File_To_Generate.Length loop
         declare
            File   : constant File_Descriptor := Compiler.Context.Get_File
              (Request, Request.File_To_Generate.Element (J));
            Base   : constant Universal_String :=
              Compiler.File_Descriptors.File_Name (File);
            Prefix : constant Universal_String :=
              Compiler.File_Descriptors.Get_Prefix (File);
            Name   : constant Universal_String :=
              Compiler.File_Descriptors.Package_Name (File);
            Spec   : String_Vector;
            Impl   : String_Vector;
            Item   : Google.Protobuf.Compiler.Plugin.File;
         begin
            Add_Lines (Spec, Clauses ("PB_SPARK"), Indent => False);
            Spec.Append ("package " & Name & " is");
            Spec.Append (+"");
            Add_Lines (Spec, SPARK_Pragma);

            for K in 1 .. File.Message_Type.Length loop
               Add_Lines
                 (Spec,
                  Compiler.SPARK_Messages.Public_Spec
                    (File.Message_Type (K), Prefix, Bounds));
            end loop;

            Spec.Append ("end " & Name & ";");

            Item.Name := (True, Base & ".ads");
            Item.Content := (True, Spec.Join (LF));
            Result.File.Append (Item);

            if File.Message_Type.Length > 0 then
               Add_Lines (Impl, Clauses ("PB_SPARK"), Indent => False);
               Impl.Append ("package body " & Name & " is");
               Impl.Append (+"");
               Add_Lines (Impl, SPARK_Pragma);

               for K in 1 .. File.Message_Type.Length loop
                  for Next of Compiler.SPARK_Messages.Subprograms
                    (File.Message_Type (K), Prefix, Bounds)
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

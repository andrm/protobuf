--  MIT License
--
--  Copyright (c) 2026 protobuf contributors
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

--  Plugin parameters and nanopb-style generator options.
--
--  The plugin parameter is the comma-separated text given to protoc with
--  --ada_opt:
--
--    runtime=spark,options=my.options,options_path=proto
--
--  An options file holds lines of the form
--
--    pattern key:value [key:value ...]
--
--  Text after "#" or "//" at the start of a token is a comment. A pattern
--  is matched against the field's full name, its name without the package,
--  and the name of its .proto file. "*" and "?" are wildcards. When several
--  lines match a field, later lines override earlier ones.

with Ada.Containers.Vectors;

with League.String_Vectors;
with League.Strings;

package Compiler.Options is

   type Runtime_Kind is (League_Runtime, SPARK_Runtime);

   type Parameters is record
      Runtime        : Runtime_Kind := League_Runtime;
      Option_Files   : League.String_Vectors.Universal_String_Vector;
      --  Values of "options=", in order. "%s" stands for the name of the
      --  .proto file without its extension.
      Search_Paths   : League.String_Vectors.Universal_String_Vector;
      --  Values of "options_path=", in order
      Ignore_Unknown : Boolean := False;
      --  Set by "ignore_unknown_options"
   end record;

   procedure Parse_Parameter
     (Text   : League.Strings.Universal_String;
      Result : out Parameters;
      Errors : in out League.String_Vectors.Universal_String_Vector);
   --  Parse the plugin parameter. Only a misspelled runtime is reported
   --  unless runtime=spark is selected, because the plugin has always ignored
   --  its parameter otherwise.

   type Optional_Positive (Is_Set : Boolean := False) is record
      case Is_Set is
         when True =>
            Value : Positive;
         when False =>
            null;
      end case;
   end record;

   type Field_Allocation is (Default_Allocation, Static_Allocation, Ignore);

   type Unknown_Enum_Policy is (Reject, First);

   type Field_Options is record
      Max_Length       : Optional_Positive;
      Max_Size         : Optional_Positive;
      Max_Count        : Optional_Positive;
      Allocation       : Field_Allocation := Default_Allocation;
      On_Unknown_Enum  : Unknown_Enum_Policy := Reject;
   end record;

   type Rule_Set is private;
   --  Options read from option files, remembered per .proto file

   procedure Add_Lines
     (Self           : in out Rule_Set;
      Proto_File     : League.Strings.Universal_String;
      Origin         : League.Strings.Universal_String;
      Lines          : League.String_Vectors.Universal_String_Vector;
      Ignore_Unknown : Boolean;
      Errors         : in out League.String_Vectors.Universal_String_Vector);
   --  Parse Lines as an options file named Origin that applies to Proto_File.
   --  Text from the same Origin is parsed only once, so a shared file reports
   --  each problem once.

   procedure Load_For_Proto
     (Self       : in out Rule_Set;
      Proto_File : League.Strings.Universal_String;
      Params     : Parameters;
      Errors     : in out League.String_Vectors.Universal_String_Vector);
   --  Read the options files for Proto_File. With no "options=" parameter the
   --  optional file "%s.options" is used. A file named without "%s" must
   --  exist, because it can only be there on purpose.

   function Field
     (Self       : in out Rule_Set;
      Proto_File : League.Strings.Universal_String;
      Full_Name  : League.Strings.Universal_String;
      Short_Name : League.Strings.Universal_String) return Field_Options;
   --  Return the options of a field. Full_Name includes the package, as in
   --  my.pkg.Message.field, and Short_Name does not, as in Message.field.

   procedure Report_Unused
     (Self     : Rule_Set;
      Warnings : in out League.String_Vectors.Universal_String_Vector);
   --  Append a warning for each rule that no call to Field has matched

   function Matches (Pattern, Text : Wide_Wide_String) return Boolean;
   --  Return True if Text matches Pattern, where "*" stands for any sequence
   --  of characters (including ".") and "?" for exactly one character.

private

   type Rule is record
      Pattern      : League.Strings.Universal_String;
      Line         : Positive;
      Used         : Boolean := False;
      Values       : Field_Options;
      Has_Size     : Boolean := False;
      Has_Count    : Boolean := False;
      Has_Type     : Boolean := False;
      Has_Enum     : Boolean := False;
   end record;

   package Rule_Vectors is new Ada.Containers.Vectors (Positive, Rule);

   type Options_File is record
      Path  : League.Strings.Universal_String;
      Rules : Rule_Vectors.Vector;
   end record;

   package File_Vectors is new Ada.Containers.Vectors
     (Positive, Options_File);

   type Scope is record
      Proto_File : League.Strings.Universal_String;
      File       : Positive;
   end record;

   package Scope_Vectors is new Ada.Containers.Vectors (Positive, Scope);

   type Rule_Set is record
      Files  : File_Vectors.Vector;
      Scopes : Scope_Vectors.Vector;
   end record;

end Compiler.Options;

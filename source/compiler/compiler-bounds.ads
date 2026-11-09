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

--  Schema checks and worst-case message sizes for the SPARK back end.

with Ada.Containers.Hashed_Maps;

with League.String_Vectors;
with League.Strings;
with League.Strings.Hash;

with Google.Protobuf.Compiler.Plugin;

with Compiler.Options;

package Compiler.Bounds is

   Max_Message_Size : constant := 2 ** 30;
   --  The largest maximum encoded size accepted for a message

   type Field_Bounds is record
      Ignored         : Boolean := False;
      Capacity        : Natural := 0;
      --  Capacity in bytes of a string or bytes field or element
      Count           : Natural := 0;
      --  Maximum number of elements of a repeated field
      On_Unknown_Enum : Compiler.Options.Unknown_Enum_Policy :=
        Compiler.Options.Reject;
   end record;

   type Analysis is private;

   procedure Analyze
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request;
      Rules   : in out Compiler.Options.Rule_Set;
      Result  : out Analysis;
      Errors  : in out League.String_Vectors.Universal_String_Vector);
   --  Check the messages of the files to generate, and all messages they
   --  use, and calculate their maximum encoded sizes. Every problem found is
   --  appended to Errors, and sizes are calculated only if there are none.

   function Field
     (Self      : Analysis;
      Full_Name : League.Strings.Universal_String) return Field_Bounds;
   --  Return bounds of a field named like my.pkg.Message.field

   function Max_Encoded_Size
     (Self      : Analysis;
      Type_Name : League.Strings.Universal_String) return Natural;
   --  Return the maximum encoded size of a message checked by Analyze, whose
   --  name is written the way descriptors do, as in .my.pkg.Message

private

   package Field_Maps is new Ada.Containers.Hashed_Maps
     (League.Strings.Universal_String,
      Field_Bounds,
      League.Strings.Hash,
      League.Strings."=");

   package Size_Maps is new Ada.Containers.Hashed_Maps
     (League.Strings.Universal_String,
      Natural,
      League.Strings.Hash,
      League.Strings."=");

   type Analysis is record
      Fields : Field_Maps.Map;
      Sizes  : Size_Maps.Map;
   end record;

end Compiler.Bounds;

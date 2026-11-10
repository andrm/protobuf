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

--  Code generation for one field of a message in SPARK output.
--
--  A field with presence has a Has_<Name> component next to its value. That
--  is the case for proto3 "optional" fields, for message fields, and for
--  proto2 optional and required fields. Encoding writes a required field even
--  if Has_<Name> is False; decoding sets Has_<Name> so that Decode can report
--  a missing required field.

with Ada_Pretty;

with League.String_Vectors;
with League.Strings;

with Google.Protobuf.Compiler.Plugin;
with Google.Protobuf.Descriptor;

with Compiler.Bounds;

package Compiler.SPARK_Fields is

   type Context is record
      Package_Name : League.Strings.Universal_String;
      --  The Ada package being generated
      Message      : League.Strings.Universal_String;
      --  Full name of the message of the field, like my.pkg.Message
      Is_Proto_3   : Boolean := True;
   end record;

   procedure Register
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request);
   --  Remember every message in Request, for Needs_Check

   function Needs_Check
     (Type_Name : League.Strings.Universal_String;
      Bounds    : Compiler.Bounds.Analysis) return Boolean;
   --  Return True if a message, written as .my.pkg.Message, has required
   --  fields of its own or in a message field

   procedure Check_Supported
     (Item      : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Full_Name : League.Strings.Universal_String;
      Errors    : in out League.String_Vectors.Universal_String_Vector);
   --  Report a field that this back end can't generate code for

   function Component_Names
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return League.String_Vectors.Universal_String_Vector;
   --  Return names of the record components of the field

   function Type_Package
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return League.Strings.Universal_String;
   --  Return the Ada package of the type of an enum or message field

   function Component
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access;
   --  Return the record components of a field

   function Clear
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access;
   --  Return statements that reset the components in record V

   function Parameters
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access;
   --  Return formal parameters of the field for an encoding part

   function Actuals
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx  : Context) return Ada_Pretty.Node_Access;
   --  Return the actual parameters for Parameters: components of record V

   function Encode
     (Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return statements that append the field to Buffer

   function Merge
     (Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return statements that read the field from Buffer into the components
   --  in record V

   function Initialized_Term
     (Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis)
      return League.Strings.Universal_String;
   --  Return a condition on V that holds when the field doesn't make the
   --  message incomplete, or an empty string if it never does

end Compiler.SPARK_Fields;

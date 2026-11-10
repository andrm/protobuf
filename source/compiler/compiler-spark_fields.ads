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

with Ada_Pretty;

with League.String_Vectors;
with League.Strings;

with Google.Protobuf.Descriptor;

package Compiler.SPARK_Fields is

   procedure Check_Supported
     (Item       : Google.Protobuf.Descriptor.Field_Descriptor_Proto;
      Full_Name  : League.Strings.Universal_String;
      Is_Proto_3 : Boolean;
      Errors     : in out League.String_Vectors.Universal_String_Vector);
   --  Report a field that this back end can't generate code for

   function Component
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access;
   --  Return the record component of a field

   function Clear
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access;
   --  Return a statement that resets the component in record V

   function Parameter
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access;
   --  Return a formal parameter of the field for an encoding part

   function Actual
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access;
   --  Return the actual parameter for Parameter: the component in record V

   function Encode
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access;
   --  Return a statement that appends the field to Buffer

   function Merge
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Ada_Pretty.Node_Access;
   --  Return statements that read the field from Buffer into the component
   --  in record V

end Compiler.SPARK_Fields;

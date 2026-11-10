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

--  Code generation for one message in SPARK output.

with Ada.Containers.Vectors;

with Ada_Pretty;

with League.String_Vectors;
with League.Strings;

with Google.Protobuf.Descriptor;

with Compiler.Bounds;
with Compiler.SPARK_Fields;

package Compiler.SPARK_Messages is

   use type Ada_Pretty.Node_Access;

   package Node_Vectors is new Ada.Containers.Vectors
     (Positive, Ada_Pretty.Node_Access);
   --  Declarations that are rendered one by one, because rendering a large
   --  document at once overflows the stack of the pretty printer

   Subprogram_Names : constant array (1 .. 6) of
     access constant Wide_Wide_String :=
       (new Wide_Wide_String'("clear"),
        new Wide_Wide_String'("append"),
        new Wide_Wide_String'("encode"),
        new Wide_Wide_String'("decode"),
        new Wide_Wide_String'("merge"),
        new Wide_Wide_String'("is_initialized"));
   --  Names of subprograms declared for every message, in lower case

   function Make_Context
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Package_Name : League.Strings.Universal_String;
      Is_Proto_3   : Boolean) return Compiler.SPARK_Fields.Context;
   --  Return the context of the fields of a message. Prefix is the type name
   --  prefix of the message, like .my.pkg

   procedure Declared_Names
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Ctx          : Compiler.SPARK_Fields.Context;
      Bounds       : Compiler.Bounds.Analysis;
      Types        : in out League.String_Vectors.Universal_String_Vector;
      Overloadable : in out League.String_Vectors.Universal_String_Vector);
   --  Append the names that the code of a message declares in its package:
   --  names of types and constants, and names that can be overloaded, other
   --  than Subprogram_Names

   function Public_Spec
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Package_Name : League.Strings.Universal_String;
      Is_Proto_3   : Boolean;
      Bounds       : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return the type of a message and its subprograms. Prefix is the type
   --  name prefix of the message, like .my.pkg

   function Subprograms
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Package_Name : League.Strings.Universal_String;
      Is_Proto_3   : Boolean;
      Bounds       : Compiler.Bounds.Analysis) return Node_Vectors.Vector;
   --  Return the subprogram bodies of a message

end Compiler.SPARK_Messages;

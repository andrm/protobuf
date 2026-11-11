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

--  Code generation for the fields of a message in SPARK output.
--
--  The fields of a message are handled as items: an item is a field, or a
--  oneof with all its fields.
--
--  A field with presence has a Has_<Name> component next to its value. That
--  is the case for proto3 "optional" fields, for message fields, and for
--  proto2 optional and required fields. Encoding writes a required field even
--  if Has_<Name> is False; decoding sets Has_<Name> so that Decode can report
--  a missing required field.
--
--  A string or bytes field has a record type with a Length and the Data. A
--  repeated field has an array type, and a <Name>_Count component that says
--  how many of its elements are used. A oneof is a variant record, whose
--  discriminant tells which field is set.
--
--  Fields of map entries have no presence and are always written, as other
--  protobuf implementations do.

with Ada.Containers.Vectors;

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
      Type_Name    : League.Strings.Universal_String;
      --  The Ada type of the message, which prefixes the types of its fields
      Is_Proto_3   : Boolean := True;
      Is_Map_Entry : Boolean := False;
   end record;

   procedure Register
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request);
   --  Remember every message in Request, for Needs_Check

   procedure Set_Package_Names
     (Names : League.String_Vectors.Universal_String_Vector);
   --  Remember the names declared by the package being generated. Such a name
   --  hides a package of the same name, so names of other packages that
   --  start with it are written as expanded names from Standard.

   function Needs_Check
     (Type_Name : League.Strings.Universal_String;
      Bounds    : Compiler.Bounds.Analysis) return Boolean;
   --  Return True if a message, written as .my.pkg.Message, has required
   --  fields of its own or in a message field

   function Type_Package
     (Item : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return League.Strings.Universal_String;
   --  Return the Ada package of the type of an enum or message field

   package Field_Vectors is new Ada.Containers.Vectors
     (Positive,
      Google.Protobuf.Descriptor.Field_Descriptor_Proto,
      Google.Protobuf.Descriptor."=");

   type Item is record
      Is_Oneof : Boolean := False;
      Name     : League.Strings.Universal_String;
      --  Ada name of a oneof
      Fields   : Field_Vectors.Vector;
      --  The field, or the fields of the oneof that are not ignored
   end record;

   package Item_Vectors is new Ada.Containers.Vectors (Positive, Item);

   function Items
     (Message : Google.Protobuf.Descriptor.Descriptor_Proto;
      Ctx     : Context;
      Bounds  : Compiler.Bounds.Analysis) return Item_Vectors.Vector;
   --  Return the items of a message for the fields that are not ignored

   procedure Check_Supported
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis;
      Errors : in out League.String_Vectors.Universal_String_Vector);
   --  Report an item that this back end can't generate code for

   function Component_Names
     (Self : Item;
      Ctx  : Context) return League.String_Vectors.Universal_String_Vector;
   --  Return names of the record components of the item

   procedure Declared_Names
     (Self         : Item;
      Ctx          : Context;
      Types        : in out League.String_Vectors.Universal_String_Vector;
      Overloadable : in out League.String_Vectors.Universal_String_Vector);
   --  Append names that the item declares in the package: the names of types,
   --  and names of enumeration literals, which can be overloaded

   function Types
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return the types that the components of the item need, or null

   function Component
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return the record components of the item

   function Default_Value
     (Type_Name : League.Strings.Universal_String;
      Ctx       : Context;
      Bounds    : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return the initial value of a message, written as .my.pkg.Message, as
   --  an aggregate in package Ctx.Package_Name. Every value is written out,
   --  including those of nested messages, because a box or the name of
   --  another constant would make a constant of it need elaboration code.

   function Max_Size
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Natural;
   --  Return the maximum encoded size of the item

   function Parameters
     (Self : Item;
      Ctx  : Context) return Ada_Pretty.Node_Access;
   --  Return formal parameters of the item for an encoding part

   function Actuals
     (Self : Item;
      Ctx  : Context) return Ada_Pretty.Node_Access;
   --  Return the actual parameters for Parameters: components of record V

   function Precondition
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis)
      return League.Strings.Universal_String;
   --  Return what an encoding part needs to know of its parameters for the
   --  item, or an empty string

   function Encode
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return statements that append the item to Buffer

   function Choices
     (Self : Item) return League.String_Vectors.Universal_String_Vector;
   --  Return the field numbers of the item

   function Merge
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access;
   --  Return case paths, by field number, that read a field of the item
   --  from Buffer into the components in record V

   function Initialized_Term
     (Self   : Item;
      Ctx    : Context;
      Bounds : Compiler.Bounds.Analysis)
      return League.Strings.Universal_String;
   --  Return a condition on V that holds when the item doesn't make the
   --  message incomplete, or an empty string if it never does

end Compiler.SPARK_Fields;

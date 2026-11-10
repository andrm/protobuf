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

with Ada.Containers.Vectors;

with Google.Protobuf.Descriptor;

with Compiler.Context;
with Compiler.Field_Descriptors;

package body Compiler.Bounds is

   use type League.Strings.Universal_String;
   use type Compiler.Options.Field_Allocation;
   use all type Google.Protobuf.Descriptor.Label;
   use all type Google.Protobuf.Descriptor.PB_Type;

   subtype Universal_String is League.Strings.Universal_String;
   subtype String_Vector is League.String_Vectors.Universal_String_Vector;
   subtype Field_Descriptor is
     Google.Protobuf.Descriptor.Field_Descriptor_Proto;
   subtype Message_Descriptor is Google.Protobuf.Descriptor.Descriptor_Proto;

   subtype Size is Long_Long_Integer;
   --  Sizes stop growing at Over_Limit, so they can't overflow this type

   Over_Limit : constant Size := Max_Message_Size + 1;

   type Visit_State is (Unvisited, In_Progress, Done);

   type Message_Info is record
      Full_Name  : Universal_String;  --  Like my.pkg.Message
      Is_Proto_3 : Boolean := False;
      State      : Visit_State := Unvisited;
      Descriptor : Message_Descriptor;
   end record;

   package Message_Maps is new Ada.Containers.Hashed_Maps
     (Universal_String,
      Message_Info,
      League.Strings.Hash,
      League.Strings."=");

   type Path_Item is record
      Message : Universal_String;  --  Type name of the message
      Field   : Universal_String;  --  Full name of the field that is followed
   end record;

   package Path_Vectors is new Ada.Containers.Vectors (Positive, Path_Item);

   function Clamp (Value : Size) return Size is (Size'Min (Value, Over_Limit));

   function Dotted
     (Prefix : Universal_String;
      Name   : Universal_String) return Universal_String;
   --  Return Prefix.Name, or just Name if Prefix is empty

   function Is_Packed
     (Item       : Field_Descriptor;
      Is_Proto_3 : Boolean) return Boolean;

   function Is_Repeated (Item : Field_Descriptor) return Boolean is
     (Item.Label.Is_Set and then Item.Label.Value = LABEL_REPEATED);

   function Is_Type
     (Item : Field_Descriptor;
      Kind : Google.Protobuf.Descriptor.PB_Type) return Boolean is
     (Item.PB_Type.Is_Set and then Item.PB_Type.Value = Kind);

   function Tag_Size (Item : Field_Descriptor) return Size;

   function To_Bounds
     (Item    : Field_Descriptor;
      Options : Compiler.Options.Field_Options) return Field_Bounds;

   function Varint_Size (Value : Size) return Size;

   -------------
   -- Analyze --
   -------------

   procedure Analyze
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request;
      Rules   : in out Compiler.Options.Rule_Set;
      Result  : out Analysis;
      Errors  : in out League.String_Vectors.Universal_String_Vector)
   is
      Messages     : Message_Maps.Map;
      Roots        : String_Vector;
      Group_Types  : Compiler.Context.String_Sets.Set;
      Path         : Path_Vectors.Vector;
      Errors_Found : constant Natural := Errors.Length;

      procedure Collect_Message
        (Descriptor : Message_Descriptor;
         Full       : Universal_String;
         Short      : Universal_String;
         File_Name  : Universal_String;
         Is_Proto_3 : Boolean;
         Generate   : Boolean);
      --  Remember a message, its nested messages and the bounds of their
      --  fields. Options are looked up for every field, even in messages that
      --  are not used, so only stale patterns are reported as unused.

      function Field_Size
        (Item       : Field_Descriptor;
         Bounds     : Field_Bounds;
         Is_Proto_3 : Boolean;
         Value      : out Size;
         Too_Big    : in out Boolean) return Size;
      --  Return maximum encoded size of a field that is not ignored, and the
      --  maximum size of one of its values

      procedure Message_Size
        (Name    : Universal_String;
         Value   : out Size;
         Too_Big : out Boolean);
      --  Calculate maximum encoded size of a message. Set Too_Big if the size
      --  exceeds the limit, which is reported only for the innermost message.

      procedure Report_Cycle
        (Field : Universal_String;
         Next  : Universal_String);

      procedure Validate
        (Item   : Field_Descriptor;
         Full   : Universal_String;
         Bounds : Field_Bounds);

      procedure Visit (Name : Universal_String);
      --  Check a message and every message it uses

      ---------------------
      -- Collect_Message --
      ---------------------

      procedure Collect_Message
        (Descriptor : Message_Descriptor;
         Full       : Universal_String;
         Short      : Universal_String;
         File_Name  : Universal_String;
         Is_Proto_3 : Boolean;
         Generate   : Boolean)
      is
         Type_Name : constant Universal_String := "." & Full;

         Is_Map_Entry : constant Boolean :=
           Descriptor.Options.Is_Set
           and then Descriptor.Options.Value.Map_Entry.Is_Set
           and then Descriptor.Options.Value.Map_Entry.Value;
      begin
         Messages.Insert
           (Type_Name,
            (Full_Name  => Full,
             Is_Proto_3 => Is_Proto_3,
             State      => Unvisited,
             Descriptor => Descriptor));

         if Generate and not Is_Map_Entry then
            Roots.Append (Type_Name);
         end if;

         for J in 1 .. Descriptor.Field.Length loop
            declare
               Item : constant Field_Descriptor := Descriptor.Field (J);
               Name : constant Universal_String := Item.Name.Value;
               Long : constant Universal_String := Dotted (Full, Name);
            begin
               Result.Fields.Insert
                 (Long,
                  To_Bounds
                    (Item,
                     Compiler.Options.Field
                       (Rules, File_Name, Long, Dotted (Short, Name))));

               if Is_Type (Item, TYPE_GROUP) and Item.Type_Name.Is_Set then
                  Group_Types.Include (Item.Type_Name.Value);
               end if;
            end;
         end loop;

         for J in 1 .. Descriptor.Nested_Type.Length loop
            declare
               Nested : constant Message_Descriptor :=
                 Descriptor.Nested_Type (J);
            begin
               Collect_Message
                 (Nested,
                  Dotted (Full, Nested.Name.Value),
                  Dotted (Short, Nested.Name.Value),
                  File_Name,
                  Is_Proto_3,
                  Generate);
            end;
         end loop;
      end Collect_Message;

      ----------------
      -- Field_Size --
      ----------------

      function Field_Size
        (Item       : Field_Descriptor;
         Bounds     : Field_Bounds;
         Is_Proto_3 : Boolean;
         Value      : out Size;
         Too_Big    : in out Boolean) return Size
      is
         Tag : constant Size := Tag_Size (Item);
      begin
         case Item.PB_Type.Value is
            when TYPE_BOOL =>
               Value := 1;
            when TYPE_FLOAT | TYPE_FIXED32 | TYPE_SFIXED32 =>
               Value := 4;
            when TYPE_DOUBLE | TYPE_FIXED64 | TYPE_SFIXED64 =>
               Value := 8;
            when TYPE_UINT32 | TYPE_SINT32 =>
               Value := 5;
            when TYPE_INT32 | TYPE_INT64 | TYPE_UINT64 | TYPE_SINT64
               | TYPE_ENUM =>
               --  Negative int32 and enum values are sign-extended to 64 bits
               Value := 10;
            when TYPE_STRING | TYPE_BYTES =>
               Value := Size (Bounds.Capacity)
                 + Varint_Size (Size (Bounds.Capacity));
            when TYPE_MESSAGE | TYPE_GROUP =>
               declare
                  Nested : Size;
                  Big    : Boolean;
               begin
                  Message_Size (Item.Type_Name.Value, Nested, Big);
                  Too_Big := Too_Big or Big;
                  Value := Nested + Varint_Size (Nested);
               end;
         end case;

         if Is_Packed (Item, Is_Proto_3) then
            declare
               Payload : constant Size := Clamp (Size (Bounds.Count) * Value);
            begin
               return Clamp (Tag + Varint_Size (Payload) + Payload);
            end;
         elsif Is_Repeated (Item) then
            return Clamp (Size (Bounds.Count) * (Tag + Value));
         else
            return Clamp (Tag + Value);
         end if;
      end Field_Size;

      ------------------
      -- Message_Size --
      ------------------

      procedure Message_Size
        (Name    : Universal_String;
         Value   : out Size;
         Too_Big : out Boolean)
      is
         Info : constant Message_Info := Messages (Name);
         Oneof : array (0 .. Info.Descriptor.Oneof_Decl.Length) of Size :=
           (others => 0);
      begin
         Too_Big := False;

         if Result.Sizes.Contains (Name) then
            Value := Size (Result.Sizes (Name));
            Too_Big := Value = Over_Limit;
            return;
         end if;

         Value := 0;

         for J in 1 .. Info.Descriptor.Field.Length loop
            declare
               Item   : constant Field_Descriptor := Info.Descriptor.Field (J);
               Bounds : constant Field_Bounds :=
                 Result.Fields (Dotted (Info.Full_Name, Item.Name.Value));
            begin
               if not Bounds.Ignored then
                  declare
                     Element : Size;
                     Current : constant Size := Field_Size
                       (Item, Bounds, Info.Is_Proto_3, Element, Too_Big);
                     Target  : Field_Bounds renames Result.Fields.Reference
                       (Dotted (Info.Full_Name, Item.Name.Value));
                  begin
                     Target.Max_Size := Natural (Current);
                     Target.Value_Size := Natural (Clamp (Element));
                     Target.Is_Packed := Is_Packed (Item, Info.Is_Proto_3);

                     if Compiler.Field_Descriptors.Is_One_Of (Item) then
                        declare
                           Index : constant Natural :=
                             Natural (Item.Oneof_Index.Value);
                        begin
                           Oneof (Index) := Size'Max (Oneof (Index), Current);
                        end;
                     else
                        Value := Clamp (Value + Current);
                     end if;
                  end;
               end if;
            end;
         end loop;

         for Item of Oneof loop
            Value := Clamp (Value + Item);
         end loop;

         if Value = Over_Limit and not Too_Big then
            Errors.Append
              (Info.Full_Name & ": maximum encoded size exceeds the limit of"
               & Natural'Wide_Wide_Image (Max_Message_Size) & " bytes");
         end if;

         Too_Big := Value = Over_Limit;
         Result.Sizes.Insert (Name, Natural (Value));
      end Message_Size;

      ------------------
      -- Report_Cycle --
      ------------------

      procedure Report_Cycle
        (Field : Universal_String;
         Next  : Universal_String)
      is
         Text  : Universal_String;
         First : Positive := Path.Last_Index + 1;
      begin
         for J in reverse 1 .. Path.Last_Index loop
            if Path (J).Message = Next then
               First := J;
            end if;
         end loop;

         for J in First .. Path.Last_Index loop
            Text.Append (Path (J).Field & " -> ");
         end loop;

         Errors.Append
           ("recursive messages are not supported: " & Text & Field & " -> "
            & Messages (Next).Full_Name
            & ": add type:ignore to one of these fields");
      end Report_Cycle;

      --------------
      -- Validate --
      --------------

      procedure Validate
        (Item   : Field_Descriptor;
         Full   : Universal_String;
         Bounds : Field_Bounds) is
      begin
         if Bounds.Ignored then
            if Item.Label.Is_Set and then Item.Label.Value = LABEL_REQUIRED
            then
               Errors.Append (Full & ": a required field can't be ignored");
            end if;

            return;
         end if;

         if Is_Type (Item, TYPE_GROUP) then
            Errors.Append
              (Full & ": groups are not supported: add type:ignore");
         elsif Is_Type (Item, TYPE_STRING) and Bounds.Capacity = 0 then
            Errors.Append
              (Full & ": string field needs max_length, or max_size of at "
               & "least 2");
         elsif Is_Type (Item, TYPE_BYTES) and Bounds.Capacity = 0 then
            Errors.Append (Full & ": bytes field needs max_size");
         end if;

         if Is_Repeated (Item) and Bounds.Count = 0 then
            Errors.Append (Full & ": repeated field needs max_count");
         end if;
      end Validate;

      -----------
      -- Visit --
      -----------

      procedure Visit (Name : Universal_String) is
         Info : constant Message_Info := Messages (Name);
      begin
         Messages.Reference (Name).State := In_Progress;

         for J in 1 .. Info.Descriptor.Field.Length loop
            declare
               Item   : constant Field_Descriptor := Info.Descriptor.Field (J);
               Full   : constant Universal_String :=
                 Dotted (Info.Full_Name, Item.Name.Value);
               Bounds : constant Field_Bounds := Result.Fields (Full);
            begin
               Validate (Item, Full, Bounds);

               if not Bounds.Ignored and Is_Type (Item, TYPE_MESSAGE) then
                  declare
                     Next : constant Universal_String := Item.Type_Name.Value;
                  begin
                     if not Messages.Contains (Next) then
                        Errors.Append
                          (Full & ": unknown message type " & Next);
                     else
                        case Messages (Next).State is
                           when Unvisited =>
                              Path.Append (Path_Item'(Name, Full));
                              Visit (Next);
                              Path.Delete_Last;
                           when In_Progress =>
                              Report_Cycle (Full, Next);
                           when Done =>
                              null;
                        end case;
                     end if;
                  end;
               end if;
            end;
         end loop;

         Messages.Reference (Name).State := Done;
      end Visit;

   begin
      Result := (others => <>);

      for J in 1 .. Request.Proto_File.Length loop
         declare
            File : constant Google.Protobuf.Descriptor.File_Descriptor_Proto :=
              Request.Proto_File (J);
            Package_Name : constant Universal_String :=
              (if File.PB_Package.Is_Set then File.PB_Package.Value
               else League.Strings.Empty_Universal_String);
            Is_Proto_3   : constant Boolean :=
              File.Syntax.Is_Set
              and then File.Syntax.Value =
                League.Strings.To_Universal_String ("proto3");
            Generate     : Boolean := False;
         begin
            for K in 1 .. Request.File_To_Generate.Length loop
               Generate := Generate
                 or Request.File_To_Generate (K) = File.Name.Value;
            end loop;

            for K in 1 .. File.Message_Type.Length loop
               declare
                  Item : constant Message_Descriptor := File.Message_Type (K);
               begin
                  Collect_Message
                    (Item,
                     Dotted (Package_Name, Item.Name.Value),
                     Item.Name.Value,
                     File.Name.Value,
                     Is_Proto_3,
                     Generate);
               end;
            end loop;
         end;
      end loop;

      for J in 1 .. Roots.Length loop
         if not Group_Types.Contains (Roots (J))
           and then Messages (Roots (J)).State = Unvisited
         then
            Visit (Roots (J));
         end if;
      end loop;

      if Errors.Length = Errors_Found then
         for J in 1 .. Roots.Length loop
            if not Group_Types.Contains (Roots (J)) then
               declare
                  Value   : Size;
                  Too_Big : Boolean;
               begin
                  Message_Size (Roots (J), Value, Too_Big);
               end;
            end if;
         end loop;
      end if;
   end Analyze;

   ------------
   -- Dotted --
   ------------

   function Dotted
     (Prefix : Universal_String;
      Name   : Universal_String) return Universal_String is
   begin
      if Prefix.Is_Empty then
         return Name;
      else
         return Prefix & "." & Name;
      end if;
   end Dotted;

   -----------
   -- Field --
   -----------

   function Field
     (Self      : Analysis;
      Full_Name : League.Strings.Universal_String) return Field_Bounds is
   begin
      return Self.Fields (Full_Name);
   end Field;

   --------------
   -- Is_Sized --
   --------------

   function Is_Sized
     (Self      : Analysis;
      Type_Name : League.Strings.Universal_String) return Boolean is
   begin
      return Self.Sizes.Contains (Type_Name);
   end Is_Sized;

   ---------------
   -- Is_Packed --
   ---------------

   function Is_Packed
     (Item       : Field_Descriptor;
      Is_Proto_3 : Boolean) return Boolean is
   begin
      if not Is_Repeated (Item)
        or else Item.PB_Type.Value in
          TYPE_STRING | TYPE_BYTES | TYPE_MESSAGE | TYPE_GROUP
      then
         return False;
      elsif Item.Options.Is_Set and then Item.Options.Value.Packed.Is_Set then
         return Item.Options.Value.Packed.Value;
      else
         return Is_Proto_3;
      end if;
   end Is_Packed;

   ----------------------
   -- Max_Encoded_Size --
   ----------------------

   function Max_Encoded_Size
     (Self      : Analysis;
      Type_Name : League.Strings.Universal_String) return Natural is
   begin
      return Self.Sizes (Type_Name);
   end Max_Encoded_Size;

   --------------
   -- Tag_Size --
   --------------

   function Tag_Size (Item : Field_Descriptor) return Size is
     (Varint_Size (Size (Item.Number.Value) * 8));

   ---------------
   -- To_Bounds --
   ---------------

   function To_Bounds
     (Item    : Field_Descriptor;
      Options : Compiler.Options.Field_Options) return Field_Bounds
   is
      Result : Field_Bounds;
   begin
      Result.Ignored := Options.Allocation = Compiler.Options.Ignore;
      Result.On_Unknown_Enum := Options.On_Unknown_Enum;

      if Is_Repeated (Item) and Options.Max_Count.Is_Set then
         Result.Count := Options.Max_Count.Value;
      end if;

      if Is_Type (Item, TYPE_STRING) then
         if Options.Max_Length.Is_Set then
            Result.Capacity := Options.Max_Length.Value;
         elsif Options.Max_Size.Is_Set then
            Result.Capacity := Options.Max_Size.Value - 1;
         end if;
      elsif Is_Type (Item, TYPE_BYTES) and Options.Max_Size.Is_Set then
         Result.Capacity := Options.Max_Size.Value;
      end if;

      return Result;
   end To_Bounds;

   -----------------
   -- Varint_Size --
   -----------------

   function Varint_Size (Value : Size) return Size is
      Rest   : Size := Value / 128;
      Result : Size := 1;
   begin
      while Rest > 0 loop
         Rest := Rest / 128;
         Result := Result + 1;
      end loop;

      return Result;
   end Varint_Size;

end Compiler.Bounds;

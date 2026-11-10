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

with League.String_Vectors;

with Compiler.Context;
with Compiler.SPARK_Fields;

package body Compiler.SPARK_Messages is

   use type League.Strings.Universal_String;

   subtype Universal_String is League.Strings.Universal_String;
   subtype Message_Descriptor is Google.Protobuf.Descriptor.Descriptor_Proto;
   subtype Node is Ada_Pretty.Node_Access;

   F : Ada_Pretty.Factory renames Compiler.Context.Factory;

   Fields_In_Part : constant := 16;
   --  Encoding and merging are split in parts of this many fields, because
   --  proving a subprogram gets much slower as it handles more fields.
   --  Encoding parts get the fields as parameters, and merging parts get the
   --  whole message, which measured fastest for each.

   Valid_Buffer : constant Wide_Wide_String :=
     "PB_SPARK.Valid_Buffer (Buffer)";

   Valid_Reader : constant Wide_Wide_String :=
     "PB_SPARK.Wire.Valid_Reader (Buffer, Limit, Pos)";

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   function N (Text : Universal_String) return Node is (F.New_Name (Text));

   function N (Text : Wide_Wide_String) return Node is (N (+Text));

   function Image (Value : Natural) return Universal_String;

   function Contract (Pre : Node; Post : Node := null) return Node;
   --  Return aspects for a subprogram declaration

   function In_Out_Parameter
     (Name : Wide_Wide_String;
      Tipe : Wide_Wide_String;
      Is_In : Boolean := True;
      Is_Out : Boolean := True) return Node is
     (F.New_Parameter
        (Name            => N (Name),
         Type_Definition => F.New_Selected_Name (+Tipe),
         Is_In           => Is_In,
         Is_Out          => Is_Out));

   function In_Parameter (Name, Tipe : Wide_Wide_String) return Node is
     (F.New_Parameter
        (Name            => N (Name),
         Type_Definition => F.New_Selected_Name (+Tipe)));

   function Out_Parameter (Name, Tipe : Wide_Wide_String) return Node is
     (In_Out_Parameter (Name, Tipe, Is_In => False));

   function Specification
     (Name       : Universal_String;
      Parameters : Node) return Node is
     (F.New_Subprogram_Specification
        (Name => N (Name), Parameters => Parameters));

   function Spec_Name (Self : Message_Descriptor; Prefix : Universal_String)
     return Universal_String;
   --  Return the name of the Ada type of a message

   function Key (Self : Message_Descriptor; Prefix : Universal_String)
     return Universal_String is (Prefix & "." & Self.Name.Value);

   function Fields_Of
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis) return Natural;
   --  Return the number of fields that aren't ignored

   function Nth_Field
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Index  : Positive)
      return Google.Protobuf.Descriptor.Field_Descriptor_Proto;
   --  Return a field by its position among fields that aren't ignored

   function Field_Max
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Index  : Positive) return Natural;
   --  Return maximum encoded size of a field that isn't ignored

   function Full_Field_Name
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Universal_String;

   function Parts (Count : Natural) return Natural is
     ((Count + Fields_In_Part - 1) / Fields_In_Part);

   function Part_First (Part : Positive) return Positive is
     ((Part - 1) * Fields_In_Part + 1);

   function Part_Last (Part : Positive; Count : Natural) return Positive is
     (Natural'Min (Part * Fields_In_Part, Count));

   function Part_Parameters
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Part_Actuals
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Part_Size
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Natural;

   function Encode_Parameters (Tipe : Universal_String) return Node;
   function Merge_Parameters (Tipe : Universal_String) return Node;

   function Encode_Part
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Merge_Part
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Part_Choice
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Skip_Call return Node is
     (F.New_Statement
        (F.New_Apply
           (F.New_Selected_Name (+"PB_SPARK.Wire.Skip_Field"),
            F.New_List
              ((F.New_Argument_Association (N ("Buffer")),
                F.New_Argument_Association (N ("Limit")),
                F.New_Argument_Association (N ("Field")),
                F.New_Argument_Association (N ("Wire")),
                F.New_Argument_Association (N ("Pos")),
                F.New_Argument_Association (N ("Status")))))));

   function Warnings
     (State   : Wide_Wide_String;
      Pattern : Wide_Wide_String;
      Reason  : Wide_Wide_String := "") return Node is
     (F.New_Pragma
        (N ("Warnings"),
         N ("GNATprove, " & (+State) & ", """ & (+Pattern) & """"
            & (if Reason = "" then +""
               else ", Reason => """ & (+Reason) & """"))));
   --  Return a pragma that turns a proof warning off or back on

   function Return_Unless_OK return Node is
     (F.New_If
        (Condition => F.New_List
           (N ("Status"),
            F.New_Infix (+"/=", F.New_Selected_Name (+"PB_SPARK.OK"))),
         Then_Path => F.New_Return));

   --------------
   -- Contract --
   --------------

   function Contract (Pre : Node; Post : Node := null) return Node is
      Result : Node := F.New_Argument_Association (Pre, N ("Pre"));
   begin
      if Post /= null then
         Result := F.New_List
           (Result, F.New_Argument_Association (Post, N ("Post")));
      end if;

      return Result;
   end Contract;

   -----------------------
   -- Encode_Parameters --
   -----------------------

   function Encode_Parameters (Tipe : Universal_String) return Node is
     (F.New_List
        ((F.New_Parameter
            (Name            => N ("V"),
             Type_Definition => N (Tipe)),
          In_Out_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
          Out_Parameter ("Last", "PB_SPARK.Index"))));

   -----------------
   -- Encode_Part --
   -----------------

   function Encode_Part
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Count  : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Name   : constant Universal_String :=
        Spec_Name (Self, Prefix) & "_Encode_Part_" & Image (Part);
      Size   : constant Universal_String :=
        Image (Part_Size (Self, Prefix, Bounds, Part));
      Spec   : constant Node := Specification
        (Name,
         F.New_List
           ((Part_Parameters (Self, Prefix, Bounds, Part),
             In_Out_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
             In_Out_Parameter ("Last", "PB_SPARK.Index"))));
      Total  : Natural := 0;
      Lines  : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Count) loop
         Total := Total + Field_Max (Self, Prefix, Bounds, J);
         Lines := F.New_List
           (Lines,
            F.New_List
              (Compiler.SPARK_Fields.Encode
                 (Nth_Field (Self, Prefix, Bounds, J)),
               F.New_Pragma
                 (N ("Assert"),
                  N ("Last in Start .. Start + " & Image (Total)))));
      end loop;

      return F.New_List
        (F.New_Subprogram_Declaration
           (Specification => Spec,
            Aspects       => Contract
              (N (+Valid_Buffer & " and then Last <= Buffer'Last - " & Size),
               N ("Last in Last'Old .. Last'Old + " & Size))),
         F.New_Subprogram_Body
           (Specification => Spec,
            Declarations  => F.New_Variable
              (Name            => N ("Start"),
               Type_Definition => F.New_Selected_Name (+"PB_SPARK.Index"),
               Initialization  => N ("Last"),
               Is_Constant     => True,
               Aspects         => N ("Ghost")),
            Statements    => Lines));
   end Encode_Part;

   ---------------
   -- Field_Max --
   ---------------

   function Field_Max
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Index  : Positive) return Natural is
     (Compiler.Bounds.Field
        (Bounds,
         Full_Field_Name
           (Self, Prefix, Nth_Field (Self, Prefix, Bounds, Index))).Max_Size);

   ---------------
   -- Fields_Of --
   ---------------

   function Fields_Of
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis) return Natural
   is
      Result : Natural := 0;
   begin
      for J in 1 .. Self.Field.Length loop
         if not Compiler.Bounds.Field
           (Bounds, Full_Field_Name (Self, Prefix, Self.Field (J))).Ignored
         then
            Result := Result + 1;
         end if;
      end loop;

      return Result;
   end Fields_Of;

   ---------------------
   -- Full_Field_Name --
   ---------------------

   function Full_Field_Name
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Item   : Google.Protobuf.Descriptor.Field_Descriptor_Proto)
      return Universal_String
   is
      Name : constant Universal_String :=
        Key (Self, Prefix) & "." & Item.Name.Value;
   begin
      return Name.Tail_From (2);  --  Without the leading dot
   end Full_Field_Name;

   -----------
   -- Image --
   -----------

   function Image (Value : Natural) return Universal_String is
      Text : constant Wide_Wide_String := Natural'Wide_Wide_Image (Value);
   begin
      return +Text (Text'First + 1 .. Text'Last);
   end Image;

   ----------------------
   -- Merge_Parameters --
   ----------------------

   function Merge_Parameters (Tipe : Universal_String) return Node is
     (F.New_List
        ((In_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
          In_Parameter ("Limit", "PB_SPARK.Index"),
          In_Out_Parameter ("Pos", "PB_SPARK.Index"),
          F.New_Parameter
            (Name            => N ("V"),
             Type_Definition => N (Tipe),
             Is_In           => True,
             Is_Out          => True),
          Out_Parameter ("Status", "PB_SPARK.Status_Kind"))));

   ----------------
   -- Merge_Part --
   ----------------

   function Merge_Part
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Count : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Name  : constant Universal_String :=
        Spec_Name (Self, Prefix) & "_Merge_Part_" & Image (Part);
      Spec  : constant Node := Specification
        (Name,
         F.New_List
           ((In_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
             In_Parameter ("Limit", "PB_SPARK.Index"),
             In_Parameter ("Field", "Interfaces.Unsigned_32"),
             In_Parameter ("Wire", "PB_SPARK.Wire.Wire_Type"),
             In_Out_Parameter ("Pos", "PB_SPARK.Index"),
             F.New_Parameter
               (Name            => N ("V"),
                Type_Definition => N (Spec_Name (Self, Prefix)),
                Is_In           => True,
                Is_Out          => True),
             Out_Parameter ("Status", "PB_SPARK.Status_Kind"))));
      Paths : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Count) loop
         declare
            Item : constant Google.Protobuf.Descriptor.Field_Descriptor_Proto
              := Nth_Field (Self, Prefix, Bounds, J);
         begin
            Paths := F.New_List
              (Paths,
               F.New_Case_Path
                 (Choice => N (Image (Natural (Item.Number.Value))),
                  List   => Compiler.SPARK_Fields.Merge (Item)));
         end;
      end loop;

      Paths := F.New_List
        (Paths, F.New_Case_Path (Choice => N ("others"), List => Skip_Call));

      return F.New_List
        (F.New_Subprogram_Declaration
           (Specification => Spec,
            Aspects       => Contract
              (N (Valid_Reader), N ("Pos in Pos'Old .. Limit + 1"))),
         F.New_Subprogram_Body
           (Specification => Spec,
            Statements    => F.New_Case (N ("Field"), Paths)));
   end Merge_Part;

   ---------------
   -- Nth_Field --
   ---------------

   function Nth_Field
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Index  : Positive)
      return Google.Protobuf.Descriptor.Field_Descriptor_Proto
   is
      Seen : Natural := 0;
   begin
      for J in 1 .. Self.Field.Length loop
         if not Compiler.Bounds.Field
           (Bounds, Full_Field_Name (Self, Prefix, Self.Field (J))).Ignored
         then
            Seen := Seen + 1;

            if Seen = Index then
               return Self.Field (J);
            end if;
         end if;
      end loop;

      raise Program_Error;
   end Nth_Field;

   ------------------
   -- Part_Actuals --
   ------------------

   function Part_Actuals
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Count  : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Result : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Count) loop
         Result := F.New_List
           (Result,
            Compiler.SPARK_Fields.Actual
              (Nth_Field (Self, Prefix, Bounds, J)));
      end loop;

      return Result;
   end Part_Actuals;

   -----------------
   -- Part_Choice --
   -----------------

   function Part_Choice
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Count  : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Result : League.String_Vectors.Universal_String_Vector;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Count) loop
         Result.Append
           (Image
              (Natural (Nth_Field (Self, Prefix, Bounds, J).Number.Value)));
      end loop;

      return N (Result.Join (" | "));
   end Part_Choice;

   ---------------------
   -- Part_Parameters --
   ---------------------

   function Part_Parameters
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Count  : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Result : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Count) loop
         Result := F.New_List
           (Result,
            Compiler.SPARK_Fields.Parameter
              (Nth_Field (Self, Prefix, Bounds, J)));
      end loop;

      return Result;
   end Part_Parameters;

   ---------------
   -- Part_Size --
   ---------------

   function Part_Size
     (Self   : Message_Descriptor;
      Prefix : Universal_String;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Natural
   is
      Count  : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Result : Natural := 0;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Count) loop
         Result := Result + Field_Max (Self, Prefix, Bounds, J);
      end loop;

      return Result;
   end Part_Size;

   -----------------
   -- Public_Spec --
   -----------------

   function Public_Spec
     (Self   : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix : League.Strings.Universal_String;
      Bounds : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Tipe  : constant Universal_String := Spec_Name (Self, Prefix);
      Max   : constant Universal_String := Tipe & "_Max_Encoded_Size";
      Count : constant Natural := Fields_Of (Self, Prefix, Bounds);
      Items : Node;
      Result : Node;
   begin
      for J in 1 .. Count loop
         Items := F.New_List
           (Items,
            Compiler.SPARK_Fields.Component
              (Nth_Field (Self, Prefix, Bounds, J)));
      end loop;

      Result := F.New_List
        ((F.New_Type
            (Name       => N (Tipe),
             Definition => F.New_Record (Components => Items)),
          F.New_Statement
            (N (Max & " : constant :="
                & Natural'Wide_Wide_Image
                    (Compiler.Bounds.Max_Encoded_Size
                       (Bounds, Key (Self, Prefix))))),
          F.New_Subprogram_Declaration
            (Specification => Specification
               (+"Clear", Out_Parameter ("V", Tipe.To_Wide_Wide_String)))));

      if Count = 0 then
         Result := F.New_List
           (Result,
            Warnings
              ("Off", "*is not modified, could be IN*",
               "All messages have the same subprograms"));
      end if;

      Result := F.New_List
        (Result,
         F.New_List
           ((F.New_Subprogram_Declaration
               (Specification => Specification
                  (+"Encode", Encode_Parameters (Tipe)),
                Aspects       => Contract
                  (N (+Valid_Buffer & " and then Buffer'Last >= " & Max),
                   N ("Last <= " & Max))),
             F.New_Subprogram_Declaration
               (Specification => Specification
                  (+"Decode",
                   F.New_List
                     ((In_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
                       Out_Parameter ("V", Tipe.To_Wide_Wide_String),
                       Out_Parameter ("Status", "PB_SPARK.Status_Kind")))),
                Aspects       => Contract (N (Valid_Buffer))),
             F.New_Subprogram_Declaration
               (Specification => Specification
                  (+"Merge", Merge_Parameters (Tipe)),
                Aspects       => Contract
                  (N (Valid_Reader), N ("Pos in Pos'Old .. Limit + 1"))))));

      if Count = 0 then
         Result := F.New_List
           (Result, Warnings ("On", "*is not modified, could be IN*"));
      end if;

      return Result;
   end Public_Spec;

   ---------------
   -- Spec_Name --
   ---------------

   function Spec_Name (Self : Message_Descriptor; Prefix : Universal_String)
     return Universal_String is
     (Compiler.Context.Named_Types (Key (Self, Prefix)).Ada_Type.Type_Name);

   -----------------
   -- Subprograms --
   -----------------

   function Subprograms
     (Self   : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix : League.Strings.Universal_String;
      Bounds : Compiler.Bounds.Analysis) return Node_Vectors.Vector
   is
      Tipe  : constant Universal_String := Spec_Name (Self, Prefix);
      Count : constant Natural := Fields_Of (Self, Prefix, Bounds);

      Result      : Node_Vectors.Vector;
      Clear_Lines : Node;
      Encode_Calls : Node := F.New_Assignment (N ("Last"), N ("0"));
      Merge_Paths  : Node;
      Total        : Natural := 0;
   begin
      for Part in 1 .. Parts (Count) loop
         Result.Append (Encode_Part (Self, Prefix, Bounds, Part));
         Result.Append (Merge_Part (Self, Prefix, Bounds, Part));

         Total := Total + Part_Size (Self, Prefix, Bounds, Part);

         Encode_Calls := F.New_List
           (Encode_Calls,
            F.New_List
              (F.New_Statement
                 (F.New_Apply
                    (N (Tipe & "_Encode_Part_" & Image (Part)),
                     F.New_List
                       ((Part_Actuals (Self, Prefix, Bounds, Part),
                         F.New_Argument_Association (N ("Buffer")),
                         F.New_Argument_Association (N ("Last")))))),
               F.New_Pragma
                 (N ("Assert"), N ("Last <= " & Image (Total)))));

         Merge_Paths := F.New_List
           (Merge_Paths,
            F.New_Case_Path
              (Choice => Part_Choice (Self, Prefix, Bounds, Part),
               List   => F.New_Statement
                 (F.New_Apply
                    (N (Tipe & "_Merge_Part_" & Image (Part)),
                     F.New_List
                       ((F.New_Argument_Association (N ("Buffer")),
                         F.New_Argument_Association (N ("Limit")),
                         F.New_Argument_Association (N ("Field")),
                         F.New_Argument_Association (N ("Wire")),
                         F.New_Argument_Association (N ("Pos")),
                         F.New_Argument_Association (N ("V")),
                         F.New_Argument_Association (N ("Status"))))))));
      end loop;

      for J in 1 .. Count loop
         Clear_Lines := F.New_List
           (Clear_Lines,
            Compiler.SPARK_Fields.Clear (Nth_Field (Self, Prefix, Bounds, J)));
      end loop;

      if Count = 0 then
         Clear_Lines := F.New_Assignment (N ("V"), N ("(null record)"));
      end if;

      Merge_Paths := F.New_List
        (Merge_Paths,
         F.New_Case_Path (Choice => N ("others"), List => Skip_Call));

      declare
         Loop_Body : constant Node := F.New_List
           ((F.New_Pragma
               (N ("Loop_Invariant"), N ("Pos in Pos'Loop_Entry .. Limit")),
             F.New_Pragma
               (N ("Loop_Invariant"),
                F.New_List
                  (N ("Status"),
                   F.New_Infix (+"=", F.New_Selected_Name (+"PB_SPARK.OK")))),
             F.New_Pragma
               (N ("Loop_Variant"),
                F.New_Argument_Association (N ("Pos"), N ("Increases"))),
             F.New_Statement
               (F.New_Apply
                  (F.New_Selected_Name (+"PB_SPARK.Wire.Get_Key"),
                   F.New_List
                     ((F.New_Argument_Association (N ("Buffer")),
                       F.New_Argument_Association (N ("Limit")),
                       F.New_Argument_Association (N ("Pos")),
                       F.New_Argument_Association (N ("Field")),
                       F.New_Argument_Association (N ("Wire")),
                       F.New_Argument_Association (N ("Status")))))),
             Return_Unless_OK,
             F.New_Statement
               (F.New_Apply
                  (N (Tipe & "_Merge_Field"),
                   F.New_List
                     ((F.New_Argument_Association (N ("Buffer")),
                       F.New_Argument_Association (N ("Limit")),
                       F.New_Argument_Association (N ("Field")),
                       F.New_Argument_Association (N ("Wire")),
                       F.New_Argument_Association (N ("Pos")),
                       F.New_Argument_Association (N ("V")),
                       F.New_Argument_Association (N ("Status")))))),
             Return_Unless_OK));

         --  This is apart from the loop in Merge because proving that loop
         --  would otherwise take most of the time for a large message
         Dispatch : constant Node := Specification
           (Tipe & "_Merge_Field",
            F.New_List
              ((In_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
                In_Parameter ("Limit", "PB_SPARK.Index"),
                In_Parameter ("Field", "Interfaces.Unsigned_32"),
                In_Parameter ("Wire", "PB_SPARK.Wire.Wire_Type"),
                In_Out_Parameter ("Pos", "PB_SPARK.Index"),
                F.New_Parameter
                  (Name            => N ("V"),
                   Type_Definition => N (Tipe),
                   Is_In           => True,
                   Is_Out          => True),
                Out_Parameter ("Status", "PB_SPARK.Status_Kind"))));
         Dispatch_Declaration : Node := F.New_Subprogram_Declaration
           (Specification => Dispatch,
            Aspects       => Contract
              (N (Valid_Reader), N ("Pos in Pos'Old .. Limit + 1")));
      begin
         if Count = 0 then
            Dispatch_Declaration := F.New_List
              ((Warnings
                  ("Off", "*is not modified, could be IN*",
                   "All messages have the same subprograms"),
                Dispatch_Declaration,
                Warnings ("On", "*is not modified, could be IN*")));
         end if;

         Result.Append
           (F.New_List
              (Dispatch_Declaration,
               F.New_Subprogram_Body
                 (Specification => Dispatch,
                  Statements    => F.New_Case (N ("Field"), Merge_Paths))));

         Result.Append
           (F.New_Subprogram_Body
               (Specification => Specification
                  (+"Clear", Out_Parameter ("V", Tipe.To_Wide_Wide_String)),
                Statements    => Clear_Lines));

         Result.Append
           (F.New_Subprogram_Body
               (Specification => Specification
                  (+"Encode", Encode_Parameters (Tipe)),
                Statements    => Encode_Calls));

         Result.Append
           (F.New_Subprogram_Body
               (Specification => Specification
                  (+"Decode",
                   F.New_List
                     ((In_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
                       Out_Parameter ("V", Tipe.To_Wide_Wide_String),
                       Out_Parameter ("Status", "PB_SPARK.Status_Kind")))),
                Declarations  => F.New_Variable
                  (Name            => N ("Pos"),
                   Type_Definition => F.New_Selected_Name (+"PB_SPARK.Index"),
                   Initialization  => N ("1")),
                Statements    => F.New_List
                  ((F.New_Statement
                      (F.New_Apply
                         (N ("Clear"),
                          F.New_Argument_Association (N ("V")))),
                    Warnings
                      ("Off", "*is set by*but not used after the call",
                       "Decode reads the whole buffer"),
                    F.New_Statement
                      (F.New_Apply
                         (N ("Merge"),
                          F.New_List
                            ((F.New_Argument_Association (N ("Buffer")),
                              F.New_Argument_Association (N ("Buffer'Last")),
                              F.New_Argument_Association (N ("Pos")),
                              F.New_Argument_Association (N ("V")),
                              F.New_Argument_Association (N ("Status")))))),
                    Warnings
                      ("On", "*is set by*but not used after the call")))));

         Result.Append
           (F.New_Subprogram_Body
               (Specification => Specification
                  (+"Merge", Merge_Parameters (Tipe)),
                Declarations  => F.New_List
                  (F.New_Variable
                     (Name            => N ("Field"),
                      Type_Definition => F.New_Selected_Name
                        (+"Interfaces.Unsigned_32")),
                   F.New_Variable
                     (Name            => N ("Wire"),
                      Type_Definition => F.New_Selected_Name
                        (+"PB_SPARK.Wire.Wire_Type"))),
                Statements    => F.New_List
                  (F.New_Assignment
                     (N ("Status"), F.New_Selected_Name (+"PB_SPARK.OK")),
                   F.New_Loop
                     (Condition  => F.New_List
                        (N ("Pos"), F.New_Infix (+"<=", N ("Limit"))),
                      Statements => Loop_Body))));

         return Result;
      end;
   end Subprograms;

end Compiler.SPARK_Messages;

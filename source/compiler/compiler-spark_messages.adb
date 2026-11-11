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

   subtype Item_List is Compiler.SPARK_Fields.Item_Vectors.Vector;

   function Parts (Count : Natural) return Natural is
     ((Count + Fields_In_Part - 1) / Fields_In_Part);

   function Part_First (Part : Positive) return Positive is
     ((Part - 1) * Fields_In_Part + 1);

   function Part_Last (Part : Positive; Count : Natural) return Positive is
     (Natural'Min (Part * Fields_In_Part, Count));

   function Part_Parameters
     (Items : Item_List;
      Ctx   : Compiler.SPARK_Fields.Context;
      Part  : Positive) return Node;

   function Part_Actuals
     (Items : Item_List;
      Ctx   : Compiler.SPARK_Fields.Context;
      Part  : Positive) return Node;

   function Part_Size
     (Items  : Item_List;
      Ctx    : Compiler.SPARK_Fields.Context;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Natural;

   function Encode_Parameters (Tipe : Universal_String) return Node;
   function Append_Parameters (Tipe : Universal_String) return Node;
   function Decode_Parameters (Tipe : Universal_String) return Node;

   function Make_Context
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Package_Name : League.Strings.Universal_String;
      Is_Proto_3   : Boolean) return Compiler.SPARK_Fields.Context is
     ((Package_Name => Package_Name,
       Message      => Key (Self, Prefix).Tail_From (2),
       Type_Name    => Spec_Name (Self, Prefix),
       Is_Proto_3   => Is_Proto_3,
       Is_Map_Entry => Self.Options.Is_Set
         and then Self.Options.Value.Map_Entry.Is_Set
         and then Self.Options.Value.Map_Entry.Value));

   function Merge_Parameters (Tipe : Universal_String) return Node;

   function Encode_Part
     (Items  : Item_List;
      Ctx    : Compiler.SPARK_Fields.Context;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Merge_Part
     (Items  : Item_List;
      Ctx    : Compiler.SPARK_Fields.Context;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node;

   function Part_Choice
     (Items : Item_List;
      Part  : Positive) return Node;

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

   function Conjunction (Terms : League.String_Vectors.Universal_String_Vector)
     return Node;
   --  Return Valid_Buffer and each of Terms joined with "and then", so that
   --  it can be split in lines. The call comes first because a name there
   --  would pad the other terms to its length.

   function Append_Cut (Tipe : Universal_String; Total : Natural)
     return League.String_Vectors.Universal_String_Vector;
   --  Return what Append knows after its parts have written Total bytes

   function Return_Unless_OK return Node is
     (F.New_If
        (Condition => F.New_List
           (N ("Status"),
            F.New_Infix (+"/=", F.New_Selected_Name (+"PB_SPARK.OK"))),
         Then_Path => F.New_Return));

   ----------------
   -- Append_Cut --
   ----------------

   function Append_Cut (Tipe : Universal_String; Total : Natural)
     return League.String_Vectors.Universal_String_Vector
   is
      Result : League.String_Vectors.Universal_String_Vector;
   begin
      Result.Append
        ("Start <= Buffer'Last - " & Tipe & "_Max_Encoded_Size");
      Result.Append ("Last in Start .. Start + " & Image (Total));
      return Result;
   end Append_Cut;

   -----------------
   -- Conjunction --
   -----------------

   function Conjunction (Terms : League.String_Vectors.Universal_String_Vector)
     return Node
   is
      Result : Node := F.New_Apply
        (F.New_Selected_Name (+"PB_SPARK.Valid_Buffer"),
         F.New_Argument_Association (N ("Buffer")));
   begin
      for J in 1 .. Terms.Length loop
         Result := F.New_List
           (Result, F.New_Infix (+"and then", N (Terms (J))));
      end loop;

      return Result;
   end Conjunction;

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

   --------------------
   -- Declared_Names --
   --------------------

   procedure Declared_Names
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Ctx          : Compiler.SPARK_Fields.Context;
      Bounds       : Compiler.Bounds.Analysis;
      Types        : in out League.String_Vectors.Universal_String_Vector;
      Overloadable : in out League.String_Vectors.Universal_String_Vector)
   is
      pragma Unreferenced (Prefix);
      Items : constant Item_List :=
        Compiler.SPARK_Fields.Items (Self, Ctx, Bounds);
   begin
      Types.Append (Ctx.Type_Name);
      Types.Append (Ctx.Type_Name & "_Max_Encoded_Size");
      Types.Append (Ctx.Type_Name & "_Default");
      Overloadable.Append (Ctx.Type_Name & "_Merge_Field");

      for Part in 1 .. Parts (Natural (Items.Length)) loop
         Overloadable.Append (Ctx.Type_Name & "_Encode_Part_" & Image (Part));
         Overloadable.Append (Ctx.Type_Name & "_Merge_Part_" & Image (Part));
      end loop;

      for Item of Items loop
         Compiler.SPARK_Fields.Declared_Names
           (Item, Ctx, Types, Overloadable);
      end loop;
   end Declared_Names;

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

   -----------------------
   -- Append_Parameters --
   -----------------------

   function Append_Parameters (Tipe : Universal_String) return Node is
     (F.New_List
        ((F.New_Parameter
            (Name            => N ("V"),
             Type_Definition => N (Tipe)),
          In_Out_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
          In_Out_Parameter ("Last", "PB_SPARK.Index"))));

   -----------------------
   -- Decode_Parameters --
   -----------------------

   function Decode_Parameters (Tipe : Universal_String) return Node is
     (F.New_List
        ((In_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
          Out_Parameter ("V", Tipe.To_Wide_Wide_String),
          Out_Parameter ("Status", "PB_SPARK.Status_Kind"))));

   -----------------
   -- Encode_Part --
   -----------------

   function Encode_Part
     (Items  : Item_List;
      Ctx    : Compiler.SPARK_Fields.Context;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Name   : constant Universal_String :=
        Ctx.Type_Name & "_Encode_Part_" & Image (Part);
      Size   : constant Universal_String :=
        Image (Part_Size (Items, Ctx, Bounds, Part));
      Spec   : constant Node := Specification
        (Name,
         F.New_List
           ((Part_Parameters (Items, Ctx, Part),
             In_Out_Parameter ("Buffer", "PB_SPARK.Byte_Array"),
             In_Out_Parameter ("Last", "PB_SPARK.Index"))));
      First  : constant Positive := Part_First (Part);
      Last   : constant Positive := Part_Last (Part, Natural (Items.Length));
      Terms  : array (First .. Last) of Universal_String;
      Pre    : Universal_String :=
        +Valid_Buffer & " and then Last <= Buffer'Last - " & Size;
      Total  : Natural := 0;
      Lines  : Node;
   begin
      for J in First .. Last loop
         Terms (J) :=
           Compiler.SPARK_Fields.Precondition (Items (J), Ctx, Bounds);

         if not Terms (J).Is_Empty then
            Pre := Pre & " and then " & Terms (J);
         end if;
      end loop;

      for J in First .. Last loop
         Total := Total
           + Compiler.SPARK_Fields.Max_Size (Items (J), Ctx, Bounds);

         declare
            Cut : League.String_Vectors.Universal_String_Vector;
         begin
            Cut.Append ("Start <= Buffer'Last - " & Size);
            Cut.Append ("Last in Start .. Start + " & Image (Total));

            --  The cut keeps the proof of each field from growing with the
            --  fields before it, so it must repeat what the fields after it
            --  need
            for K in J + 1 .. Last loop
               if not Terms (K).Is_Empty then
                  Cut.Append (Terms (K));
               end if;
            end loop;

            Lines := F.New_List
              (Lines,
               F.New_List
                 (Compiler.SPARK_Fields.Encode (Items (J), Ctx, Bounds),
                  F.New_Pragma (N ("Assert_And_Cut"), Conjunction (Cut))));
         end;
      end loop;

      return F.New_List
        (F.New_Subprogram_Declaration
           (Specification => Spec,
            Aspects       => Contract
              (N (Pre), N ("Last in Last'Old .. Last'Old + " & Size))),
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
     (Items  : Item_List;
      Ctx    : Compiler.SPARK_Fields.Context;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Node
   is
      Name  : constant Universal_String :=
        Ctx.Type_Name & "_Merge_Part_" & Image (Part);
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
                Type_Definition => N (Ctx.Type_Name),
                Is_In           => True,
                Is_Out          => True),
             Out_Parameter ("Status", "PB_SPARK.Status_Kind"))));
      Paths : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Natural (Items.Length))
      loop
         Paths := F.New_List
           (Paths, Compiler.SPARK_Fields.Merge (Items (J), Ctx, Bounds));
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

   ------------------
   -- Part_Actuals --
   ------------------

   function Part_Actuals
     (Items : Item_List;
      Ctx   : Compiler.SPARK_Fields.Context;
      Part  : Positive) return Node
   is
      Result : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Natural (Items.Length))
      loop
         Result := F.New_List
           (Result, Compiler.SPARK_Fields.Actuals (Items (J), Ctx));
      end loop;

      return Result;
   end Part_Actuals;

   -----------------
   -- Part_Choice --
   -----------------

   function Part_Choice
     (Items : Item_List;
      Part  : Positive) return Node
   is
      Result : League.String_Vectors.Universal_String_Vector;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Natural (Items.Length))
      loop
         Result.Append (Compiler.SPARK_Fields.Choices (Items (J)));
      end loop;

      return N (Result.Join (" | "));
   end Part_Choice;

   ---------------------
   -- Part_Parameters --
   ---------------------

   function Part_Parameters
     (Items : Item_List;
      Ctx   : Compiler.SPARK_Fields.Context;
      Part  : Positive) return Node
   is
      Result : Node;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Natural (Items.Length))
      loop
         Result := F.New_List
           (Result, Compiler.SPARK_Fields.Parameters (Items (J), Ctx));
      end loop;

      return Result;
   end Part_Parameters;

   ---------------
   -- Part_Size --
   ---------------

   function Part_Size
     (Items  : Item_List;
      Ctx    : Compiler.SPARK_Fields.Context;
      Bounds : Compiler.Bounds.Analysis;
      Part   : Positive) return Natural
   is
      Result : Natural := 0;
   begin
      for J in Part_First (Part) .. Part_Last (Part, Natural (Items.Length))
      loop
         Result := Result
           + Compiler.SPARK_Fields.Max_Size (Items (J), Ctx, Bounds);
      end loop;

      return Result;
   end Part_Size;

   -----------------
   -- Public_Spec --
   -----------------

   function Public_Spec
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Package_Name : League.Strings.Universal_String;
      Is_Proto_3   : Boolean;
      Bounds       : Compiler.Bounds.Analysis) return Ada_Pretty.Node_Access
   is
      Ctx    : constant Compiler.SPARK_Fields.Context :=
        Make_Context (Self, Prefix, Package_Name, Is_Proto_3);
      Tipe   : constant Universal_String := Ctx.Type_Name;
      Max    : constant Universal_String := Tipe & "_Max_Encoded_Size";
      Items  : constant Item_List :=
        Compiler.SPARK_Fields.Items (Self, Ctx, Bounds);
      Count  : constant Natural := Natural (Items.Length);
      Types  : Node;
      Parts  : Node;
      Terms  : League.String_Vectors.Universal_String_Vector;
      Result : Node;
   begin
      for Item of Items loop
         declare
            Term : constant Universal_String :=
              Compiler.SPARK_Fields.Initialized_Term (Item, Ctx, Bounds);
            Used : constant Node :=
              Compiler.SPARK_Fields.Types (Item, Ctx, Bounds);
         begin
            if Used /= null then
               Types := F.New_List (Types, Used);
            end if;

            Parts := F.New_List
              (Parts, Compiler.SPARK_Fields.Component (Item, Ctx, Bounds));

            if not Term.Is_Empty then
               Terms.Append (Term);
            end if;
         end;
      end loop;

      Result := F.New_List
        ((F.New_Type
            (Name       => N (Tipe),
             Definition => F.New_Record (Components => Parts)),
          F.New_Statement
            (N (Max & " : constant :="
                & Natural'Wide_Wide_Image
                    (Compiler.Bounds.Max_Encoded_Size
                       (Bounds, Key (Self, Prefix))))),
          F.New_Subprogram_Declaration
            (Specification => Specification
               (+"Clear", Out_Parameter ("V", Tipe.To_Wide_Wide_String)))));

      Result := F.New_List (Types, Result);

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
                  (+"Append", Append_Parameters (Tipe)),
                Aspects       => Contract
                  (N (+Valid_Buffer & " and then Last <= Buffer'Last - "
                      & Max),
                   N ("Last in Last'Old .. Last'Old + " & Max))),
             F.New_Subprogram_Declaration
               (Specification => Specification
                  (+"Encode", Encode_Parameters (Tipe)),
                Aspects       => Contract
                  (N (+Valid_Buffer & " and then Buffer'Last >= " & Max),
                   N ("Last <= " & Max))),
             F.New_Subprogram_Declaration
               (Specification => Specification
                  (+"Decode", Decode_Parameters (Tipe)),
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

      if not Terms.Is_Empty then
         Result := F.New_List
           (Result,
            F.New_Subprogram_Declaration
              (Specification => F.New_Subprogram_Specification
                 (Name       => N ("Is_Initialized"),
                  Parameters => F.New_Parameter
                    (Name => N ("V"), Type_Definition => N (Tipe)),
                  Result     => N ("Boolean")),
               Expression    => N (Terms.Join (" and then ")),
               Comment       => +"Return True if no required field is "
                 & "missing"));
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
     (Self         : Google.Protobuf.Descriptor.Descriptor_Proto;
      Prefix       : League.Strings.Universal_String;
      Package_Name : League.Strings.Universal_String;
      Is_Proto_3   : Boolean;
      Bounds       : Compiler.Bounds.Analysis) return Node_Vectors.Vector
   is
      Ctx   : constant Compiler.SPARK_Fields.Context :=
        Make_Context (Self, Prefix, Package_Name, Is_Proto_3);
      Tipe  : constant Universal_String := Ctx.Type_Name;
      Items : constant Item_List :=
        Compiler.SPARK_Fields.Items (Self, Ctx, Bounds);
      Count : constant Natural := Natural (Items.Length);
      Needs : constant Boolean :=
        Compiler.SPARK_Fields.Needs_Check (Key (Self, Prefix), Bounds);

      Result       : Node_Vectors.Vector;
      Clear_Lines  : Node;
      Default      : Node;
      Append_Calls : Node;
      Merge_Paths  : Node;
      Total        : Natural := 0;
   begin
      for Part in 1 .. Parts (Count) loop
         Result.Append (Encode_Part (Items, Ctx, Bounds, Part));
         Result.Append (Merge_Part (Items, Ctx, Bounds, Part));

         Total := Total + Part_Size (Items, Ctx, Bounds, Part);

         Append_Calls := F.New_List
           (Append_Calls,
            F.New_List
              (F.New_Statement
                 (F.New_Apply
                    (N (Tipe & "_Encode_Part_" & Image (Part)),
                     F.New_List
                       ((Part_Actuals (Items, Ctx, Part),
                         F.New_Argument_Association (N ("Buffer")),
                         F.New_Argument_Association (N ("Last")))))),
               F.New_Pragma
                 (N ("Assert_And_Cut"),
                  Conjunction (Append_Cut (Tipe, Total)))));

         Merge_Paths := F.New_List
           (Merge_Paths,
            F.New_Case_Path
              (Choice => Part_Choice (Items, Part),
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

      --  Clear copies a constant: assigning the components one by one makes
      --  a large message too deep to prove, and an aggregate in Clear would
      --  be built on the stack
      if Count = 0 then
         Clear_Lines := F.New_Assignment (N ("V"), N ("(null record)"));
         Append_Calls := F.New_Statement;
      else
         Default := F.New_Variable
           (Name            => N (Tipe & "_Default"),
            Type_Definition => N (Tipe),
            Initialization  => Compiler.SPARK_Fields.Default_Value
              (Key (Self, Prefix), Ctx, Bounds),
            Is_Constant     => True);

         if Compiler.SPARK_Fields.Has_Box (Key (Self, Prefix), Ctx, Bounds)
         then
            Default := F.New_List
              ((F.New_Pragma
                  (N ("Warnings"),
                   N ("Off, ""component * is uninitialized"", Reason => "
                      & """Arrays of empty messages have nothing to "
                      & "initialize""")),
                Default,
                F.New_Pragma
                  (N ("Warnings"),
                   N ("On, ""component * is uninitialized"""))));
         end if;

         Clear_Lines := F.New_Assignment (N ("V"), N (Tipe & "_Default"));
      end if;

      Merge_Paths := F.New_List
        (Merge_Paths,
         F.New_Case_Path (Choice => N ("others"), List => Skip_Call));

      if Default /= null then
         Result.Append (Default);
      end if;

      Result.Append
        (F.New_Subprogram_Body
           (Specification => Specification
              (+"Clear", Out_Parameter ("V", Tipe.To_Wide_Wide_String)),
            Statements    => Clear_Lines));

      Result.Append
        (F.New_Subprogram_Body
           (Specification => Specification
              (+"Append", Append_Parameters (Tipe)),
            Declarations  =>
              (if Count = 0 then null
               else F.New_Variable
                 (Name            => N ("Start"),
                  Type_Definition => F.New_Selected_Name (+"PB_SPARK.Index"),
                  Initialization  => N ("Last"),
                  Is_Constant     => True,
                  Aspects         => N ("Ghost"))),
            Statements    => Append_Calls));

      Result.Append
        (F.New_Subprogram_Body
           (Specification => Specification
              (+"Encode", Encode_Parameters (Tipe)),
            Statements    => F.New_List
              (F.New_Assignment (N ("Last"), N ("0")),
               F.New_Statement
                 (F.New_Apply
                    (N ("Append"),
                     F.New_List
                       ((F.New_Argument_Association (N ("V")),
                         F.New_Argument_Association (N ("Buffer")),
                         F.New_Argument_Association (N ("Last")))))))));

      declare
         Decode_Lines : Node := F.New_List
           ((F.New_Statement
               (F.New_Apply
                  (N ("Clear"), F.New_Argument_Association (N ("V")))),
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
             Warnings ("On", "*is set by*but not used after the call")));
      begin
         if Needs then
            Decode_Lines := F.New_List
              (Decode_Lines,
               F.New_If
                 (Condition => N
                    ("Status = PB_SPARK.OK and then not Is_Initialized (V)"),
                  Then_Path => F.New_Assignment
                    (N ("Status"),
                     F.New_Selected_Name (+"PB_SPARK.Missing_Required"))));
         end if;

         Result.Append
           (F.New_Subprogram_Body
              (Specification => Specification
                 (+"Decode", Decode_Parameters (Tipe)),
               Declarations  => F.New_Variable
                 (Name            => N ("Pos"),
                  Type_Definition => F.New_Selected_Name (+"PB_SPARK.Index"),
                  Initialization  => N ("1")),
               Statements    => Decode_Lines));
      end;

      declare
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
         --  This is apart from the loop in Merge, because proving that loop
         --  would otherwise take most of the time for a large message

         Dispatch_Declaration : Node := F.New_Subprogram_Declaration
           (Specification => Dispatch,
            Aspects       => Contract
              (N (Valid_Reader), N ("Pos in Pos'Old .. Limit + 1")));

         Loop_Body : constant Node := F.New_List
           ((F.New_Pragma
               (N ("Loop_Invariant"), N ("Pos in Pos'Loop_Entry .. Limit")),
             F.New_Pragma
               (N ("Loop_Invariant"), N ("Status = PB_SPARK.OK")),
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
                    (Condition  => N ("Pos <= Limit"),
                     Statements => Loop_Body))));
      end;

      return Result;
   end Subprograms;

end Compiler.SPARK_Messages;

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

--  Expected sizes in this test are calculated by hand, as tag size plus
--  value size for each field.

with Ada.Command_Line;
with Ada.Wide_Wide_Text_IO;

with Interfaces;

with League.String_Vectors;
with League.Strings;

with Google.Protobuf.Compiler.Plugin;
with Google.Protobuf.Descriptor;

with Compiler.Bounds;
with Compiler.Options;

procedure Compiler_Bounds_Test is
   use type League.Strings.Universal_String;
   use type Compiler.Options.Unknown_Enum_Policy;
   use Google.Protobuf.Descriptor;
   use all type Google.Protobuf.Descriptor.PB_Type;
   use all type Google.Protobuf.Descriptor.Label;

   subtype Vector is League.String_Vectors.Universal_String_Vector;

   type Field_Array is array (Positive range <>) of Field_Descriptor_Proto;
   type Message_Array is array (Positive range <>) of Descriptor_Proto;
   type File_Array is array (Positive range <>) of File_Descriptor_Proto;

   No_Messages : constant Message_Array (1 .. 0) := (others => <>);

   Failures : Natural := 0;

   function "+" (Text : Wide_Wide_String)
     return League.Strings.Universal_String
       renames League.Strings.To_Universal_String;

   procedure Check (Condition : Boolean; Name : Wide_Wide_String);

   function F
     (Name   : Wide_Wide_String;
      Number : Positive;
      Kind   : PB_Type;
      Lab    : Label := LABEL_OPTIONAL;
      Tipe   : Wide_Wide_String := "";
      Oneof  : Integer := -1;
      Synth  : Boolean := False;
      Packed : Integer := -1) return Field_Descriptor_Proto;
   --  Make a field. Packed is 0 or 1 to set the option explicitly.

   function M
     (Name   : Wide_Wide_String;
      Fields : Field_Array;
      Nested : Message_Array := No_Messages;
      Oneofs : Natural := 0;
      Is_Map : Boolean := False) return Descriptor_Proto;

   function File
     (Name     : Wide_Wide_String;
      Messages : Message_Array;
      Proto_3  : Boolean := True;
      Pkg      : Wide_Wide_String := "p") return File_Descriptor_Proto;

   procedure Run
     (Files   : File_Array;
      Options : Wide_Wide_String;
      Result  : out Compiler.Bounds.Analysis;
      Errors  : out Vector;
      Imports : Natural := 0);
   --  Analyze files, the last Imports of which are only imported

   function Errors_Of
     (Messages : Message_Array;
      Options  : Wide_Wide_String := "") return Vector;

   function Has
     (Errors : Vector;
      Text   : Wide_Wide_String) return Boolean;

   procedure Check_Size
     (Name     : Wide_Wide_String;
      Fields   : Field_Array;
      Options  : Wide_Wide_String;
      Expected : Natural;
      Proto_3  : Boolean := True;
      Oneofs   : Natural := 0);
   --  Check the size of a message M with Fields in package p

   procedure Test_Scalars;
   procedure Test_Tags;
   procedure Test_Strings;
   procedure Test_Repeated;
   procedure Test_Messages;
   procedure Test_Limit;
   procedure Test_Errors;
   procedure Test_Cycles;
   procedure Test_Reachability;

   -----------
   -- Check --
   -----------

   procedure Check (Condition : Boolean; Name : Wide_Wide_String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Wide_Wide_Text_IO.Put_Line ("FAILED: " & Name);
      end if;
   end Check;

   ----------------
   -- Check_Size --
   ----------------

   procedure Check_Size
     (Name     : Wide_Wide_String;
      Fields   : Field_Array;
      Options  : Wide_Wide_String;
      Expected : Natural;
      Proto_3  : Boolean := True;
      Oneofs   : Natural := 0)
   is
      Result : Compiler.Bounds.Analysis;
      Errors : Vector;
      Size   : Natural := 0;
   begin
      Run
        ((1 => File
           ("a.proto",
            (1 => M ("M", Fields, Oneofs => Oneofs)),
            Proto_3 => Proto_3)),
         Options,
         Result,
         Errors);

      if not Errors.Is_Empty then
         Check (False, Name & ": " & Errors.Join (" ").To_Wide_Wide_String);
         return;
      end if;

      Size := Compiler.Bounds.Max_Encoded_Size (Result, +".p.M");
      Check
        (Size = Expected,
         Name & ": got" & Natural'Wide_Wide_Image (Size) & ", expected"
         & Natural'Wide_Wide_Image (Expected));
   end Check_Size;

   ---------------
   -- Errors_Of --
   ---------------

   function Errors_Of
     (Messages : Message_Array;
      Options  : Wide_Wide_String := "") return Vector
   is
      Result : Compiler.Bounds.Analysis;
      Errors : Vector;
   begin
      Run ((1 => File ("a.proto", Messages)), Options, Result, Errors);
      return Errors;
   end Errors_Of;

   -------
   -- F --
   -------

   function F
     (Name   : Wide_Wide_String;
      Number : Positive;
      Kind   : PB_Type;
      Lab    : Label := LABEL_OPTIONAL;
      Tipe   : Wide_Wide_String := "";
      Oneof  : Integer := -1;
      Synth  : Boolean := False;
      Packed : Integer := -1) return Field_Descriptor_Proto
   is
      Result : Field_Descriptor_Proto;
   begin
      Result.Name := (True, +Name);
      Result.Number := (True, Interfaces.Integer_32 (Number));
      Result.PB_Type := (True, Kind);
      Result.Label := (True, Lab);

      if Tipe /= "" then
         Result.Type_Name := (True, +Tipe);
      end if;

      if Oneof >= 0 then
         Result.Oneof_Index := (True, Interfaces.Integer_32 (Oneof));
      end if;

      if Synth then
         Result.Proto_3_Optional := (True, True);
      end if;

      if Packed >= 0 then
         declare
            Options : Field_Options;
         begin
            Options.Packed := (True, Packed = 1);
            Result.Options := (True, Options);
         end;
      end if;

      return Result;
   end F;

   ----------
   -- File --
   ----------

   function File
     (Name     : Wide_Wide_String;
      Messages : Message_Array;
      Proto_3  : Boolean := True;
      Pkg      : Wide_Wide_String := "p") return File_Descriptor_Proto
   is
      Result : File_Descriptor_Proto;
   begin
      Result.Name := (True, +Name);

      if Pkg /= "" then
         Result.PB_Package := (True, +Pkg);
      end if;

      if Proto_3 then
         Result.Syntax := (True, +"proto3");
      end if;

      for Item of Messages loop
         Result.Message_Type.Append (Item);
      end loop;

      return Result;
   end File;

   ---------
   -- Has --
   ---------

   function Has
     (Errors : Vector;
      Text   : Wide_Wide_String) return Boolean is
   begin
      for J in 1 .. Errors.Length loop
         if Errors (J).Index (+Text) > 0 then
            return True;
         end if;
      end loop;

      return False;
   end Has;

   -------
   -- M --
   -------

   function M
     (Name   : Wide_Wide_String;
      Fields : Field_Array;
      Nested : Message_Array := No_Messages;
      Oneofs : Natural := 0;
      Is_Map : Boolean := False) return Descriptor_Proto
   is
      Result : Descriptor_Proto;
   begin
      Result.Name := (True, +Name);

      for Item of Fields loop
         Result.Field.Append (Item);
      end loop;

      for Item of Nested loop
         Result.Nested_Type.Append (Item);
      end loop;

      for J in 1 .. Oneofs loop
         Result.Oneof_Decl.Append (Oneof_Descriptor_Proto'(others => <>));
      end loop;

      if Is_Map then
         declare
            Options : Message_Options;
         begin
            Options.Map_Entry := (True, True);
            Result.Options := (True, Options);
         end;
      end if;

      return Result;
   end M;

   ---------
   -- Run --
   ---------

   procedure Run
     (Files   : File_Array;
      Options : Wide_Wide_String;
      Result  : out Compiler.Bounds.Analysis;
      Errors  : out Vector;
      Imports : Natural := 0)
   is
      Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request;
      Rules   : Compiler.Options.Rule_Set;
      Lines   : constant Vector :=
        League.Strings.Universal_String'(+Options).Split ('|');
   begin
      Errors.Clear;

      for J in Files'Range loop
         Request.Proto_File.Append (Files (J));

         if J <= Files'Last - Imports then
            Request.File_To_Generate.Append (Files (J).Name.Value);
         end if;

         Compiler.Options.Add_Lines
           (Rules, Files (J).Name.Value, +"t", Lines, False, Errors);
      end loop;

      Compiler.Bounds.Analyze (Request, Rules, Result, Errors);
   end Run;

   -----------------
   -- Test_Cycles --
   -----------------

   procedure Test_Cycles is
      Result : Compiler.Bounds.Analysis;
      E      : Vector;
      Self_Ref : constant Message_Array :=
        (1 => M ("A", (1 => F ("next", 1, TYPE_MESSAGE, Tipe => ".p.A"))));
      Mutual : constant Message_Array :=
        (M ("Value", (1 => F ("list", 1, TYPE_MESSAGE, Tipe => ".p.List"))),
         M ("List",
            (1 => F ("values", 1, TYPE_MESSAGE, LABEL_REPEATED,
                     Tipe => ".p.Value"))));
      Tail : constant Message_Array :=
        (M ("Start", (1 => F ("a", 1, TYPE_MESSAGE, Tipe => ".p.A"))),
         M ("A", (1 => F ("b", 1, TYPE_MESSAGE, Tipe => ".p.B"))),
         M ("B", (1 => F ("a", 1, TYPE_MESSAGE, Tipe => ".p.A"))));
      Diamond : constant Message_Array :=
        (M ("Top",
            (F ("x", 1, TYPE_MESSAGE, Tipe => ".p.Shared"),
             F ("y", 2, TYPE_MESSAGE, Tipe => ".p.Shared"))),
         M ("Shared", (1 => F ("v", 1, TYPE_BOOL))));
   begin
      E := Errors_Of (Self_Ref);
      Check (E.Length = 1, "self reference is reported once");
      Check (Has (E, "p.A.next -> p.A:"), "self reference path");

      E := Errors_Of (Mutual, "List.values max_count:2");
      Check (E.Length = 1, "mutual recursion is reported once");
      Check (Has (E, "p.Value.list -> p.List.values -> p.Value:"),
             "mutual recursion path");

      E := Errors_Of (Tail);
      Check (E.Length = 1, "cycle after a tail");
      Check (Has (E, "p.A.b -> p.B.a -> p.A:"), "cycle path");
      Check (not Has (E, "p.Start.a"), "cycle path leaves out the tail");

      E := Errors_Of (Self_Ref, "A.next type:ignore");
      Check (E.Is_Empty, "ignoring a field breaks a cycle");

      E := Errors_Of (Mutual, "List.values type:ignore");
      Check (E.Is_Empty, "ignoring a field breaks a mutual cycle");

      E := Errors_Of (Diamond);
      Check (E.Is_Empty, "a shared message is not a cycle");

      Run ((1 => File ("a.proto", Diamond)), "", Result, E);
      Check
        (Compiler.Bounds.Max_Encoded_Size (Result, +".p.Top") = 8,
         "shared message size");  --  2 * (tag 1 + length 1 + 2)
   end Test_Cycles;

   -----------------
   -- Test_Errors --
   -----------------

   procedure Test_Errors is
      E : Vector;
   begin
      E := Errors_Of ((1 => M ("A", (1 => F ("s", 1, TYPE_STRING)))));
      Check (Has (E, "p.A.s: string field needs"), "unbounded string");

      E := Errors_Of ((1 => M ("A", (1 => F ("b", 1, TYPE_BYTES)))));
      Check (Has (E, "p.A.b: bytes field needs max_size"), "unbounded bytes");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("b", 1, TYPE_BYTES)))), "A.b max_length:3");
      Check (E.Length = 1, "max_length doesn't bound bytes");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("s", 1, TYPE_STRING)))), "A.s max_size:1");
      Check (E.Length = 1, "max_size:1 leaves no room in a string");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("r", 1, TYPE_BOOL, LABEL_REPEATED)))));
      Check (Has (E, "p.A.r: repeated field needs max_count"),
             "unbounded repeated");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("r", 1, TYPE_STRING, LABEL_REPEATED)))));
      Check (E.Length = 2, "repeated string needs both bounds");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("g", 1, TYPE_GROUP, Tipe => ".p.A.G")),
                  (1 => M ("G", (1 => F ("s", 1, TYPE_STRING)))))));
      Check (E.Length = 1, "only the group itself is reported");
      Check (Has (E, "p.A.g: groups are not supported"), "group");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("g", 1, TYPE_GROUP, Tipe => ".p.A.G")),
                  (1 => M ("G", (1 => F ("s", 1, TYPE_STRING)))))),
         "A.g type:ignore");
      Check (E.Is_Empty, "an ignored group needs no bounds");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("r", 1, TYPE_BOOL, LABEL_REQUIRED)))),
         "A.r type:ignore");
      Check (Has (E, "p.A.r: a required field can't be ignored"),
             "required field");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("s", 1, TYPE_STRING)))), "A.s type:ignore");
      Check (E.Is_Empty, "an ignored field needs no bounds");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("x", 1, TYPE_MESSAGE, Tipe => ".p.Nope")))));
      Check (Has (E, "unknown message type .p.Nope"), "unknown type");

      E := Errors_Of
        ((M ("A", (F ("s", 1, TYPE_STRING), F ("b", 2, TYPE_BYTES))),
          M ("B", (1 => F ("r", 1, TYPE_BOOL, LABEL_REPEATED)))));
      Check (E.Length = 3, "all errors are reported at once");

      E := Errors_Of
        ((1 => M ("A", (1 => F ("n", 1, TYPE_INT32)))),
         "* max_length:9 max_count:2");
      Check (E.Is_Empty, "options that don't apply are allowed");

      declare
         Result : Compiler.Bounds.Analysis;
         Fields : constant Field_Array :=
           (F ("s", 1, TYPE_STRING, LABEL_REPEATED),
            F ("t", 2, TYPE_STRING),
            F ("b", 3, TYPE_BYTES),
            F ("e", 4, TYPE_ENUM, Tipe => ".p.E"),
            F ("i", 5, TYPE_STRING),
            F ("n", 6, TYPE_INT32));
         B : Compiler.Bounds.Field_Bounds;
      begin
         Run
           ((1 => File ("a.proto", (1 => M ("A", Fields)))),
            "A.s max_length:4 max_count:7|A.t max_size:5|A.b max_size:6|"
            & "A.e on_unknown_enum:first|A.i type:ignore|"
            & "A.n max_length:3 max_count:3",
            Result,
            E);
         Check (E.Is_Empty, "field bounds have no errors");

         B := Compiler.Bounds.Field (Result, +"p.A.s");
         Check (B.Capacity = 4 and B.Count = 7, "string bounds");
         B := Compiler.Bounds.Field (Result, +"p.A.t");
         Check (B.Capacity = 4 and B.Count = 0, "max_size less one");
         B := Compiler.Bounds.Field (Result, +"p.A.b");
         Check (B.Capacity = 6, "bytes capacity");
         B := Compiler.Bounds.Field (Result, +"p.A.e");
         Check (B.On_Unknown_Enum = Compiler.Options.First, "enum policy");
         B := Compiler.Bounds.Field (Result, +"p.A.i");
         Check (B.Ignored, "ignored field");
         B := Compiler.Bounds.Field (Result, +"p.A.n");
         Check (B.Capacity = 0 and B.Count = 0, "inapplicable options");
         Check (B.Max_Size = 11, "field size is recorded");
         B := Compiler.Bounds.Field (Result, +"p.A.t");
         Check (B.Max_Size = 6, "string field size is recorded");
      end;
   end Test_Errors;

   ----------------
   -- Test_Limit --
   ----------------

   procedure Test_Limit is
      Bytes : constant Field_Array := (1 => F ("b", 1, TYPE_BYTES));
      E     : Vector;
   begin
      --  Tag 1 + length 5 + capacity reaches the limit exactly
      Check_Size
        ("at the limit", Bytes, "M.b max_size:1073741818", 2 ** 30);

      E := Errors_Of ((1 => M ("M", Bytes)), "M.b max_size:1073741819");
      Check (E.Length = 1, "over the limit");
      Check (Has (E, "p.M: maximum encoded size exceeds"), "limit message");

      E := Errors_Of
        ((M ("Outer", (1 => F ("m", 1, TYPE_MESSAGE, Tipe => ".p.M"))),
          M ("M", Bytes)),
         "M.b max_size:2147483647");
      Check (E.Length = 1, "limit is reported for the innermost message");
      Check (Has (E, "p.M: maximum"), "innermost message is named");

      E := Errors_Of
        ((1 => M ("M",
                  (F ("a", 1, TYPE_BYTES),
                   F ("b", 2, TYPE_BYTES),
                   F ("c", 3, TYPE_DOUBLE, LABEL_REPEATED)))),
         "M.a max_size:2147483647|M.b max_size:2147483647|"
         & "M.c max_count:2147483647");
      Check (E.Length = 1, "very large bounds don't overflow");
   end Test_Limit;

   -------------------
   -- Test_Messages --
   -------------------

   procedure Test_Messages is
      Result : Compiler.Bounds.Analysis;
      E      : Vector;
   begin
      --  Oneof takes the largest variant: 1+1+20 = 22, then bool 2
      Check_Size
        ("oneof",
         (F ("a", 1, TYPE_INT32, Oneof => 0),
          F ("b", 2, TYPE_STRING, Oneof => 0),
          F ("c", 3, TYPE_BOOL)),
         "M.b max_length:20",
         24,
         Oneofs => 1);

      --  Without b the largest variant is 11, then bool 2
      Check_Size
        ("ignored oneof variant",
         (F ("a", 1, TYPE_INT32, Oneof => 0),
          F ("b", 2, TYPE_STRING, Oneof => 0),
          F ("c", 3, TYPE_BOOL)),
         "M.b type:ignore",
         13,
         Oneofs => 1);

      Check_Size
        ("two oneofs",
         (F ("a", 1, TYPE_INT32, Oneof => 0),
          F ("b", 2, TYPE_BOOL, Oneof => 0),
          F ("c", 3, TYPE_FIXED32, Oneof => 1),
          F ("d", 4, TYPE_FIXED64, Oneof => 1)),
         "",
         20,  --  11 + 9
         Oneofs => 2);

      --  Proto3 "optional" uses a synthetic oneof, and fields add up
      Check_Size
        ("proto3 optional",
         (F ("a", 1, TYPE_INT32, Oneof => 0, Synth => True),
          F ("b", 2, TYPE_INT32, Oneof => 1, Synth => True)),
         "",
         22,
         Oneofs => 2);

      Check_Size ("ignored field", (1 => F ("a", 1, TYPE_INT32)),
                  "M.a type:ignore", 0);
      Check_Size ("empty message", (1 .. 0 => <>), "", 0);

      Run
        ((1 => File
           ("a.proto",
            (M ("Outer",
                (F ("one", 1, TYPE_MESSAGE, Tipe => ".p.Inner"),
                 F ("many", 2, TYPE_MESSAGE, LABEL_REPEATED,
                   Tipe => ".p.Inner"))),
             M ("Inner", (1 => F ("v", 1, TYPE_INT32)))))),
         "Outer.many max_count:3",
         Result,
         E);
      Check (E.Is_Empty, "nested messages have no errors");
      Check (Compiler.Bounds.Max_Encoded_Size (Result, +".p.Inner") = 11,
             "inner size");
      Check (Compiler.Bounds.Max_Encoded_Size (Result, +".p.Outer") = 52,
             "outer size");  --  13 + 3 * 13

      --  Map entry: key 1+1+8 = 10, value 11, so 21. Each entry takes
      --  1 + 1 + 21 = 23 and there are 2 of them.
      Run
        ((1 => File
           ("a.proto",
            (1 => M
              ("M",
               (1 => F ("m", 1, TYPE_MESSAGE, LABEL_REPEATED,
                        Tipe => ".p.M.MEntry")),
               (1 => M
                 ("MEntry",
                  (F ("key", 1, TYPE_STRING),
                   F ("value", 2, TYPE_INT32)),
                  Is_Map => True)))))),
         "M.m max_count:2|M.MEntry.key max_length:8",
         Result,
         E);
      Check (E.Is_Empty, "map has no errors");
      Check (Compiler.Bounds.Max_Encoded_Size (Result, +".p.M") = 46,
             "map size");

      --  No package
      Run
        ((1 => File
           ("a.proto",
            (1 => M ("M", (1 => F ("s", 1, TYPE_STRING)))),
            Pkg => "")),
         "M.s max_length:3",
         Result,
         E);
      Check (E.Is_Empty, "no package has no errors");
      Check (Compiler.Bounds.Max_Encoded_Size (Result, +".M") = 5,
             "no package size");

      --  Nested type names use the short and the full form
      Run
        ((1 => File
           ("a.proto",
            (1 => M
              ("M",
               (1 => F ("n", 1, TYPE_MESSAGE, Tipe => ".p.M.N")),
               (1 => M ("N", (1 => F ("s", 1, TYPE_STRING)))))))),
         "p.M.N.s max_length:3",
         Result,
         E);
      Check (E.Is_Empty, "options by full name");
      Check (Compiler.Bounds.Max_Encoded_Size (Result, +".p.M.N") = 5,
             "nested size");
   end Test_Messages;

   -----------------------
   -- Test_Reachability --
   -----------------------

   procedure Test_Reachability is
      Result : Compiler.Bounds.Analysis;
      E, W   : Vector;
      Used   : constant File_Descriptor_Proto := File
        ("lib.proto",
         (M ("Used", (1 => F ("n", 1, TYPE_INT32))),
          M ("Unused", (1 => F ("s", 1, TYPE_STRING)))));
      Unbounded : constant File_Descriptor_Proto := File
        ("lib.proto", (1 => M ("Used", (1 => F ("s", 1, TYPE_STRING)))));
      Main : constant File_Descriptor_Proto := File
        ("a.proto",
         (1 => M ("A", (1 => F ("u", 1, TYPE_MESSAGE, Tipe => ".p.Used")))));
   begin
      Run ((Main, Used), "", Result, E, Imports => 1);
      Check (E.Is_Empty, "unused imported messages need no bounds");
      Check (Compiler.Bounds.Max_Encoded_Size (Result, +".p.A") = 13,
             "size through an import");

      Run ((Main, Unbounded), "", Result, E, Imports => 1);
      Check (Has (E, "p.Used.s: string field needs"),
             "used imported messages need bounds");

      E := Errors_Of
        ((1 => M
           ("A",
            (1 => F ("m", 1, TYPE_MESSAGE, LABEL_REPEATED,
                     Tipe => ".p.A.MEntry")),
            (1 => M
              ("MEntry",
               (F ("key", 1, TYPE_STRING), F ("value", 2, TYPE_STRING)),
               Is_Map => True)))),
         "A.m type:ignore");
      Check (E.Is_Empty, "ignored map needs no entry bounds");

      declare
         Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request;
         Rules   : Compiler.Options.Rule_Set;
         Lines   : constant Vector :=
           League.Strings.Universal_String'
             (+"Unused.s max_length:3|Stale.x max_count:1").Split ('|');
      begin
         E.Clear;
         Request.Proto_File.Append (Main);
         Request.Proto_File.Append (Used);
         Request.File_To_Generate.Append (Main.Name.Value);
         Compiler.Options.Add_Lines
           (Rules, Used.Name.Value, +"t", Lines, False, E);
         Compiler.Bounds.Analyze (Request, Rules, Result, E);
         Compiler.Options.Report_Unused (Rules, W);
         Check (W.Length = 1 and then W (1).Index (+"Stale.x") > 0,
                "only stale patterns are unused");
      end;
   end Test_Reachability;

   -------------------
   -- Test_Repeated --
   -------------------

   procedure Test_Repeated is
      Numbers : constant Field_Array :=
        (1 => F ("r", 1, TYPE_INT32, LABEL_REPEATED));
   begin
      Check_Size ("packed by default in proto3", Numbers,
                  "M.r max_count:4", 42);  --  1 + 1 + 4 * 10
      Check_Size ("two byte length", Numbers,
                  "M.r max_count:13", 133);  --  1 + 2 + 130
      Check_Size ("unpacked by default in proto2", Numbers,
                  "M.r max_count:4", 44, Proto_3 => False);  --  4 * 11
      Check_Size
        ("packed explicitly in proto2",
         (1 => F ("r", 1, TYPE_INT32, LABEL_REPEATED, Packed => 1)),
         "M.r max_count:4", 42, Proto_3 => False);
      Check_Size
        ("not packed explicitly in proto3",
         (1 => F ("r", 1, TYPE_INT32, LABEL_REPEATED, Packed => 0)),
         "M.r max_count:4", 44);
      Check_Size
        ("packed fixed32",
         (1 => F ("r", 1, TYPE_FIXED32, LABEL_REPEATED)),
         "M.r max_count:100", 403);  --  1 + 2 + 400
      Check_Size
        ("packed enum",
         (1 => F ("r", 1, TYPE_ENUM, LABEL_REPEATED, Tipe => ".p.E")),
         "M.r max_count:2", 22);  --  1 + 1 + 20
      Check_Size
        ("repeated string is never packed",
         (1 => F ("r", 1, TYPE_STRING, LABEL_REPEATED)),
         "M.r max_count:3 max_length:10", 36);  --  3 * (1 + 1 + 10)
      Check_Size
        ("repeated bytes is never packed",
         (1 => F ("r", 1, TYPE_BYTES, LABEL_REPEATED)),
         "M.r max_count:2 max_size:5", 14);  --  2 * (1 + 1 + 5)
   end Test_Repeated;

   ------------------
   -- Test_Scalars --
   ------------------

   procedure Test_Scalars is
   begin
      Check_Size ("int32", (1 => F ("f", 1, TYPE_INT32)), "", 11);
      Check_Size ("int64", (1 => F ("f", 1, TYPE_INT64)), "", 11);
      Check_Size ("uint64", (1 => F ("f", 1, TYPE_UINT64)), "", 11);
      Check_Size ("sint64", (1 => F ("f", 1, TYPE_SINT64)), "", 11);
      Check_Size ("enum", (1 => F ("f", 1, TYPE_ENUM, Tipe => ".p.E")),
                  "", 11);
      Check_Size ("uint32", (1 => F ("f", 1, TYPE_UINT32)), "", 6);
      Check_Size ("sint32", (1 => F ("f", 1, TYPE_SINT32)), "", 6);
      Check_Size ("bool", (1 => F ("f", 1, TYPE_BOOL)), "", 2);
      Check_Size ("fixed32", (1 => F ("f", 1, TYPE_FIXED32)), "", 5);
      Check_Size ("sfixed32", (1 => F ("f", 1, TYPE_SFIXED32)), "", 5);
      Check_Size ("float", (1 => F ("f", 1, TYPE_FLOAT)), "", 5);
      Check_Size ("fixed64", (1 => F ("f", 1, TYPE_FIXED64)), "", 9);
      Check_Size ("sfixed64", (1 => F ("f", 1, TYPE_SFIXED64)), "", 9);
      Check_Size ("double", (1 => F ("f", 1, TYPE_DOUBLE)), "", 9);
      Check_Size
        ("fields add up",
         (F ("a", 1, TYPE_INT32),
          F ("b", 2, TYPE_SINT32),
          F ("c", 3, TYPE_BOOL)),
         "",
         19);
   end Test_Scalars;

   ------------------
   -- Test_Strings --
   ------------------

   procedure Test_Strings is
      Text : constant Field_Array := (1 => F ("s", 1, TYPE_STRING));
      Data : constant Field_Array := (1 => F ("b", 1, TYPE_BYTES));
   begin
      Check_Size ("one byte length", Text, "M.s max_length:127", 129);
      Check_Size ("two byte length", Text, "M.s max_length:128", 131);
      Check_Size ("string max_size", Text, "M.s max_size:128", 129);
      Check_Size ("bytes one byte", Data, "M.b max_size:127", 129);
      Check_Size ("bytes two bytes", Data, "M.b max_size:16383", 16386);
      Check_Size ("bytes three bytes", Data, "M.b max_size:16384", 16388);
   end Test_Strings;

   ---------------
   -- Test_Tags --
   ---------------

   procedure Test_Tags is
   begin
      Check_Size ("tag 15", (1 => F ("f", 15, TYPE_BOOL)), "", 2);
      Check_Size ("tag 16", (1 => F ("f", 16, TYPE_BOOL)), "", 3);
      Check_Size ("tag 2047", (1 => F ("f", 2047, TYPE_BOOL)), "", 3);
      Check_Size ("tag 2048", (1 => F ("f", 2048, TYPE_BOOL)), "", 4);
      Check_Size ("tag 262143", (1 => F ("f", 262143, TYPE_BOOL)), "", 4);
      Check_Size ("tag 262144", (1 => F ("f", 262144, TYPE_BOOL)), "", 5);
      Check_Size
        ("tag 33554431", (1 => F ("f", 33554431, TYPE_BOOL)), "", 5);
      Check_Size
        ("tag 33554432", (1 => F ("f", 33554432, TYPE_BOOL)), "", 6);
      Check_Size
        ("tag 536870911", (1 => F ("f", 536870911, TYPE_BOOL)), "", 6);
   end Test_Tags;

begin
   Test_Scalars;
   Test_Tags;
   Test_Strings;
   Test_Repeated;
   Test_Messages;
   Test_Limit;
   Test_Errors;
   Test_Cycles;
   Test_Reachability;

   if Failures = 0 then
      Ada.Wide_Wide_Text_IO.Put_Line ("compiler bounds tests OK");
   else
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Compiler_Bounds_Test;

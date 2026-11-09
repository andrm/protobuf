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

--  Usage: compiler_options_test <fixtures directory>

with Ada.Command_Line;
with Ada.Wide_Wide_Text_IO;

with League.String_Vectors;
with League.Strings;

with Compiler.Options;

procedure Compiler_Options_Test is
   use Compiler.Options;
   use type League.Strings.Universal_String;

   subtype Vector is League.String_Vectors.Universal_String_Vector;

   Failures : Natural := 0;

   function "+" (Text : Wide_Wide_String)
     return League.Strings.Universal_String
       renames League.Strings.To_Universal_String;

   function Fixtures return League.Strings.Universal_String is
     (League.Strings.From_UTF_8_String (Ada.Command_Line.Argument (1)));

   Proto : constant League.Strings.Universal_String := +"a.proto";

   procedure Check (Condition : Boolean; Name : Wide_Wide_String);

   procedure Check (Condition : Boolean; Name : Wide_Wide_String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Wide_Wide_Text_IO.Put_Line ("FAILED: " & Name);
      end if;
   end Check;

   function Lines (Text : Wide_Wide_String) return Vector is
     (League.Strings.Universal_String'(+Text).Split ('|'));
   --  Build lines of an options file from one "|"-separated string

   function Get
     (Self : in out Rule_Set;
      Name : Wide_Wide_String) return Field_Options is
     (Field (Self, Proto, "my.pkg." & (+Name), +Name));

   function Errors_Of
     (Text           : Wide_Wide_String;
      Ignore_Unknown : Boolean := False) return Natural;
   --  Return number of errors found when parsing an options text

   function Errors_Of
     (Text           : Wide_Wide_String;
      Ignore_Unknown : Boolean := False) return Natural
   is
      Self   : Rule_Set;
      Errors : Vector;
   begin
      Add_Lines (Self, Proto, +"t", Lines (Text), Ignore_Unknown, Errors);
      return Errors.Length;
   end Errors_Of;

   procedure Test_Matches;
   procedure Test_Parameter;
   procedure Test_Rules;
   procedure Test_Scope_And_Unused;
   procedure Test_Files;

   ------------------
   -- Test_Matches --
   ------------------

   procedure Test_Matches is
   begin
      Check (Matches ("a.b", "a.b"), "exact");
      Check (not Matches ("a.b", "a.c"), "different");
      Check (not Matches ("a", "ab"), "pattern too short");
      Check (not Matches ("ab", "a"), "text too short");
      Check (Matches ("*", ""), "star matches empty");
      Check (Matches ("*", "a.b.c"), "star crosses dots");
      Check (Matches ("*.name", "M.Sub.name"), "suffix");
      Check (not Matches ("*.name", "M.names"), "suffix mismatch");
      Check (Matches ("M.*", "M.x"), "prefix");
      Check (Matches ("a?c", "abc"), "question mark");
      Check (not Matches ("a?c", "ac"), "question mark needs a character");
      Check (Matches ("a*b*c", "axbxbxc"), "backtracking");
      Check (not Matches ("a*b*c", "axbxbx"), "backtracking fails");
      Check (Matches ("**a", "bba"), "double star");
   end Test_Matches;

   --------------------
   -- Test_Parameter --
   --------------------

   procedure Test_Parameter is
      P : Parameters;
      E : Vector;
   begin
      Parse_Parameter (+"", P, E);
      Check (P.Runtime = League_Runtime and E.Is_Empty, "empty parameter");

      Parse_Parameter
        (+"runtime=spark,options=a.opt,options=%s.opt,options_path=d"
         & ",ignore_unknown_options",
         P,
         E);
      Check (P.Runtime = SPARK_Runtime, "spark runtime");
      Check (P.Option_Files.Length = 2, "two option files");
      Check (P.Option_Files (2) = +"%s.opt", "option file order");
      Check (P.Search_Paths (1) = +"d", "search path");
      Check (P.Ignore_Unknown, "ignore unknown");
      Check (E.Is_Empty, "valid parameter has no errors");

      Parse_Parameter (+"whatever,foo=bar", P, E);
      Check (P.Runtime = League_Runtime and E.Is_Empty,
             "unknown parameters stay ignored without spark");

      Parse_Parameter (+"runtime=spark,foo=bar,options=", P, E);
      Check (E.Length = 2, "unknown parameters are errors with spark");
      E.Clear;

      Parse_Parameter (+"runtime=spakr", P, E);
      Check (E.Length = 1, "misspelled runtime is always an error");
      E.Clear;

      Parse_Parameter (+"runtime=league", P, E);
      Check (P.Runtime = League_Runtime and E.Is_Empty, "league runtime");
   end Test_Parameter;

   ----------------
   -- Test_Rules --
   ----------------

   procedure Test_Rules is
      Self : Rule_Set;
      E    : Vector;
      F    : Field_Options;
   begin
      Add_Lines
        (Self,
         Proto,
         +"t",
         Lines
           ("# comment|// comment||   |"
            & "*.name max_length:32|"
            & "M.name max_length:8  # trailing|"
            & "M.other" & Wide_Wide_Character'Val (9) & "max_count:5 "
            & "type:ignore on_unknown_enum:first|"
            & "M.crlf max_size:4" & Wide_Wide_Character'Val (13) & "|"
            & "M.reset type:ignore|"
            & "M.reset type:static|"
            & "M.both max_length:4|"
            & "M.both max_size:9|"
            & "M.ft type:FT_IGNORE|"
            & "pkg/x.proto max_count:1"),
         False,
         E);
      Check (E.Is_Empty, "valid options have no errors");

      F := Get (Self, "M.name");
      Check (F.Max_Length.Is_Set and then F.Max_Length.Value = 8,
             "later line wins");

      F := Get (Self, "Other.name");
      Check (F.Max_Length.Is_Set and then F.Max_Length.Value = 32,
             "wildcard applies");
      Check (F.Allocation = Default_Allocation, "default allocation");
      Check (F.On_Unknown_Enum = Reject, "enums reject by default");

      F := Get (Self, "M.other");
      Check (F.Max_Count.Is_Set and then F.Max_Count.Value = 5, "tab, count");
      Check (F.Allocation = Ignore, "several options on a line");
      Check (F.On_Unknown_Enum = First, "enum policy");

      F := Get (Self, "M.crlf");
      Check (F.Max_Size.Is_Set and then F.Max_Size.Value = 4, "CR stripped");

      F := Get (Self, "M.reset");
      Check (F.Allocation = Static_Allocation, "later type wins");

      F := Get (Self, "M.both");
      Check (F.Max_Size.Is_Set and not F.Max_Length.Is_Set,
             "max_size replaces earlier max_length");

      F := Get (Self, "M.ft");
      Check (F.Allocation = Ignore, "nanopb type names");

      F := Field (Self, +"pkg/x.proto", +"p.M.f", +"M.f");
      Check (not F.Max_Count.Is_Set, "rules apply only to their proto file");

      Check (Errors_Of ("M.a max_count:0") = 1, "zero");
      Check (Errors_Of ("M.a max_count:-1") = 1, "negative");
      Check (Errors_Of ("M.a max_count:abc") = 1, "not a number");
      Check (Errors_Of ("M.a max_count:") = 1, "empty value");
      Check (Errors_Of ("M.a max_count:99999999999") = 1, "too large");
      Check (Errors_Of ("M.a max_count:2147483647") = 0, "largest value");
      Check (Errors_Of ("M.a") = 1, "no options");
      Check (Errors_Of ("M.a nocolon") = 1, "no colon");
      Check (Errors_Of ("M.a type:bogus") = 1, "bad type");
      Check (Errors_Of ("M.a on_unknown_enum:bogus") = 1, "bad enum policy");
      Check (Errors_Of ("M.[ab] max_count:1") = 1, "character class");
      Check (Errors_Of ("M.a max_length:1 max_size:2") = 1, "both on a line");
      Check (Errors_Of ("M.a long_names:true") = 1, "unknown key");
      Check (Errors_Of ("M.a long_names:true", True) = 0, "ignored key");
      Check (Errors_Of ("M.a type:FT_CALLBACK", True) = 1, "callback");
      Check (Errors_Of ("M.a type:pointer", True) = 1, "pointer");
      Check (Errors_Of ("M.a max_count:0|M.b max_size:x") = 2,
             "all errors are reported");
   end Test_Rules;

   ---------------------------
   -- Test_Scope_And_Unused --
   ---------------------------

   procedure Test_Scope_And_Unused is
      Self : Rule_Set;
      E, W : Vector;
      F    : Field_Options;
   begin
      Add_Lines
        (Self,
         +"one.proto",
         +"shared",
         Lines ("M.bad max_count:0|M.used max_count:1|M.stale max_count:2"),
         False,
         E);
      Check (E.Length = 1, "problem found in shared file");

      Add_Lines
        (Self,
         +"two.proto",
         +"shared",
         Lines ("M.bad max_count:0|M.used max_count:1|M.stale max_count:2"),
         False,
         E);
      Check (E.Length = 1, "shared file reports each problem once");

      F := Field (Self, +"two.proto", +"M.used", +"M.used");
      Check (F.Max_Count.Is_Set, "shared rule applies to second proto");

      Report_Unused (Self, W);
      Check (W.Length = 1, "one unused rule");
      Check (W.Length = 1 and then W (1).Index ("M.stale") > 0,
             "warning names the pattern");
      Check (W.Length = 1 and then W (1).Starts_With ("shared:3:"),
             "warning names file and line");
   end Test_Scope_And_Unused;

   ----------------
   -- Test_Files --
   ----------------

   procedure Test_Files is
      Dir : constant League.Strings.Universal_String := Fixtures;
   begin
      declare
         Self : Rule_Set;
         P    : Parameters;
         E    : Vector;
         F    : Field_Options;
      begin
         P.Search_Paths.Append (Dir);
         Load_For_Proto (Self, +"telemetry.proto", P, E);
         F := Field (Self, +"telemetry.proto", +"M.name", +"Message.name");
         Check (E.Is_Empty, "default file loads");
         Check (F.Max_Length.Is_Set and then F.Max_Length.Value = 16,
                "default file applies");

         Load_For_Proto (Self, +"sub/nested.proto", P, E);
         F := Field (Self, +"sub/nested.proto", +"N.name", +"Nested.name");
         Check (F.Max_Length.Is_Set and then F.Max_Length.Value = 8,
                "proto in subdirectory");

         Load_For_Proto (Self, +"google/protobuf/none.proto", P, E);
         Check (E.Is_Empty, "missing default file is fine");
      end;

      declare
         Self : Rule_Set;
         P    : Parameters;
         E    : Vector;
      begin
         P.Search_Paths.Append (Dir);
         P.Option_Files.Append (+"nothing.options");
         Load_For_Proto (Self, Proto, P, E);
         Check (E.Length = 1, "missing named file is an error");
      end;

      declare
         Self : Rule_Set;
         P    : Parameters;
         E    : Vector;
      begin
         P.Search_Paths.Append (Dir);
         P.Option_Files.Append (+"%s.absent");
         Load_For_Proto (Self, Proto, P, E);
         Check (E.Is_Empty, "missing %s file is fine");
      end;

      declare
         Self : Rule_Set;
         P    : Parameters;
         E    : Vector;
         F    : Field_Options;
      begin
         P.Search_Paths.Append (Dir);
         P.Search_Paths.Append (Dir & "/second");
         P.Option_Files.Append (+"shared.options");
         Load_For_Proto (Self, Proto, P, E);
         F := Field (Self, Proto, +"Shared.name", +"Shared.name");
         Check (F.Max_Length.Is_Set and then F.Max_Length.Value = 1,
                "first search path wins");
      end;

      declare
         Self : Rule_Set;
         P    : Parameters;
         E    : Vector;
         F    : Field_Options;
      begin
         P.Option_Files.Append (Dir & "/shared.options");
         P.Option_Files.Append (Dir & "/second/shared.options");
         Load_For_Proto (Self, Proto, P, E);
         F := Field (Self, Proto, +"Shared.name", +"Shared.name");
         Check (E.Is_Empty, "paths given in the options parameter");
         Check (F.Max_Length.Is_Set and then F.Max_Length.Value = 2,
                "later option file wins");
         F := Field (Self, Proto, +"Only.here", +"Only.here");
         Check (F.Max_Count.Is_Set, "rules from both files apply");
      end;
   end Test_Files;

begin
   Test_Matches;
   Test_Parameter;
   Test_Rules;
   Test_Scope_And_Unused;
   Test_Files;

   if Failures = 0 then
      Ada.Wide_Wide_Text_IO.Put_Line ("compiler options tests OK");
   else
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Compiler_Options_Test;

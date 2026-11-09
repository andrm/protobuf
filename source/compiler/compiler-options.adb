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

with Ada.Characters.Wide_Wide_Latin_1;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Wide_Wide_Fixed;
with Ada.Text_IO;

package body Compiler.Options is

   use type League.Strings.Universal_String;

   package Latin renames Ada.Characters.Wide_Wide_Latin_1;

   subtype Universal_String is League.Strings.Universal_String;
   subtype String_Vector is League.String_Vectors.Universal_String_Vector;

   function "+" (Text : Wide_Wide_String) return Universal_String
     renames League.Strings.To_Universal_String;

   procedure Add_Scope
     (Self       : in out Rule_Set;
      Proto_File : Universal_String;
      File       : Positive);

   function Expand
     (Pattern : Wide_Wide_String;
      Base    : Wide_Wide_String) return Universal_String;
   --  Replace each "%s" in Pattern with Base

   function File_Index
     (Self : Rule_Set;
      Path : Universal_String) return Natural;
   --  Return the index of the options file Path, or 0 if it wasn't parsed

   function Image (Value : Natural) return Wide_Wide_String;

   function Join_Path
     (Directory : Universal_String;
      Name      : Universal_String) return Universal_String;

   procedure Parse_Line
     (Line           : Wide_Wide_String;
      Number         : Positive;
      Origin         : Universal_String;
      Ignore_Unknown : Boolean;
      Rules          : in out Rule_Vectors.Vector;
      Errors         : in out String_Vector);

   procedure Parse_Positive
     (Text    : Wide_Wide_String;
      Value   : out Natural;
      Success : out Boolean);

   procedure Read_File
     (Path    : Universal_String;
      Lines   : out String_Vector;
      Success : out Boolean;
      Errors  : in out String_Vector);

   function Strip_Extension (Name : Wide_Wide_String) return Wide_Wide_String;

   ---------------
   -- Add_Lines --
   ---------------

   procedure Add_Lines
     (Self           : in out Rule_Set;
      Proto_File     : League.Strings.Universal_String;
      Origin         : League.Strings.Universal_String;
      Lines          : League.String_Vectors.Universal_String_Vector;
      Ignore_Unknown : Boolean;
      Errors         : in out League.String_Vectors.Universal_String_Vector)
   is
      Index : constant Natural := File_Index (Self, Origin);
   begin
      if Index > 0 then
         Add_Scope (Self, Proto_File, Index);
         return;
      end if;

      declare
         File : Options_File;
      begin
         File.Path := Origin;

         for J in 1 .. Lines.Length loop
            Parse_Line
              (Lines (J).To_Wide_Wide_String,
               J,
               Origin,
               Ignore_Unknown,
               File.Rules,
               Errors);
         end loop;

         Self.Files.Append (File);
         Add_Scope (Self, Proto_File, Self.Files.Last_Index);
      end;
   end Add_Lines;

   ---------------
   -- Add_Scope --
   ---------------

   procedure Add_Scope
     (Self       : in out Rule_Set;
      Proto_File : Universal_String;
      File       : Positive) is
   begin
      Self.Scopes.Append (Scope'(Proto_File, File));
   end Add_Scope;

   ------------
   -- Expand --
   ------------

   function Expand
     (Pattern : Wide_Wide_String;
      Base    : Wide_Wide_String) return Universal_String
   is
      Result : Universal_String;
      J      : Integer := Pattern'First;
   begin
      while J <= Pattern'Last loop
         if J < Pattern'Last
           and then Pattern (J .. J + 1) = "%s"
         then
            Result.Append (Base);
            J := J + 2;
         else
            Result.Append (Pattern (J));
            J := J + 1;
         end if;
      end loop;

      return Result;
   end Expand;

   -----------
   -- Field --
   -----------

   function Field
     (Self       : in out Rule_Set;
      Proto_File : League.Strings.Universal_String;
      Full_Name  : League.Strings.Universal_String;
      Short_Name : League.Strings.Universal_String) return Field_Options
   is
      Full   : constant Wide_Wide_String := Full_Name.To_Wide_Wide_String;
      Short  : constant Wide_Wide_String := Short_Name.To_Wide_Wide_String;
      File   : constant Wide_Wide_String := Proto_File.To_Wide_Wide_String;
      Result : Field_Options;
   begin
      for Item of Self.Scopes loop
         if Item.Proto_File = Proto_File then
            for R of Self.Files (Item.File).Rules loop
               declare
                  Pattern : constant Wide_Wide_String :=
                    R.Pattern.To_Wide_Wide_String;
               begin
                  if Matches (Pattern, Full)
                    or else Matches (Pattern, Short)
                    or else Matches (Pattern, File)
                  then
                     R.Used := True;

                     if R.Has_Size then
                        Result.Max_Length := R.Values.Max_Length;
                        Result.Max_Size := R.Values.Max_Size;
                     end if;

                     if R.Has_Count then
                        Result.Max_Count := R.Values.Max_Count;
                     end if;

                     if R.Has_Type then
                        Result.Allocation := R.Values.Allocation;
                     end if;

                     if R.Has_Enum then
                        Result.On_Unknown_Enum := R.Values.On_Unknown_Enum;
                     end if;
                  end if;
               end;
            end loop;
         end if;
      end loop;

      return Result;
   end Field;

   ----------------
   -- File_Index --
   ----------------

   function File_Index
     (Self : Rule_Set;
      Path : Universal_String) return Natural is
   begin
      for J in 1 .. Self.Files.Last_Index loop
         if Self.Files (J).Path = Path then
            return J;
         end if;
      end loop;

      return 0;
   end File_Index;

   -----------
   -- Image --
   -----------

   function Image (Value : Natural) return Wide_Wide_String is
      Text : constant Wide_Wide_String := Natural'Wide_Wide_Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   ---------------
   -- Join_Path --
   ---------------

   function Join_Path
     (Directory : Universal_String;
      Name      : Universal_String) return Universal_String is
   begin
      if Name.Starts_With ("/") or else Directory = +"." then
         return Name;
      elsif Directory.Ends_With ("/") then
         return Directory & Name;
      else
         return Directory & "/" & Name;
      end if;
   end Join_Path;

   --------------------
   -- Load_For_Proto --
   --------------------

   procedure Load_For_Proto
     (Self       : in out Rule_Set;
      Proto_File : League.Strings.Universal_String;
      Params     : Parameters;
      Errors     : in out League.String_Vectors.Universal_String_Vector)
   is
      Base : constant Wide_Wide_String :=
        Strip_Extension (Proto_File.To_Wide_Wide_String);

      procedure Load_One (Pattern : Universal_String);

      --------------
      -- Load_One --
      --------------

      procedure Load_One (Pattern : Universal_String) is
         Name : constant Universal_String :=
           Expand (Pattern.To_Wide_Wide_String, Base);
         Required : constant Boolean :=
           not Params.Option_Files.Is_Empty
           and then Ada.Strings.Wide_Wide_Fixed.Index
             (Pattern.To_Wide_Wide_String, "%s") = 0;
         Paths : String_Vector := Params.Search_Paths;
      begin
         if Paths.Is_Empty then
            Paths.Append (+".");
         end if;

         for J in 1 .. Paths.Length loop
            declare
               Path : constant Universal_String :=
                 Join_Path (Paths (J), Name);
               Text : constant String := Path.To_UTF_8_String;
            begin
               if Ada.Directories.Exists (Text)
                 and then Ada.Directories."="
                   (Ada.Directories.Kind (Text),
                    Ada.Directories.Ordinary_File)
               then
                  declare
                     Lines   : String_Vector;
                     Success : Boolean;
                  begin
                     if File_Index (Self, Path) > 0 then
                        Success := True;  --  Already parsed, lines are unused
                     else
                        Read_File (Path, Lines, Success, Errors);
                     end if;

                     if Success then
                        Add_Lines
                          (Self,
                           Proto_File,
                           Path,
                           Lines,
                           Params.Ignore_Unknown,
                           Errors);
                     end if;
                  end;

                  return;
               end if;
            end;
         end loop;

         if Required then
            Errors.Append
              ("options file not found: " & Name & " (searched: "
               & Paths.Join (", ") & ")");
         end if;
      end Load_One;

   begin
      if Params.Option_Files.Is_Empty then
         Load_One (+"%s.options");
      else
         for J in 1 .. Params.Option_Files.Length loop
            Load_One (Params.Option_Files (J));
         end loop;
      end if;
   end Load_For_Proto;

   -------------
   -- Matches --
   -------------

   function Matches (Pattern, Text : Wide_Wide_String) return Boolean is
      P : Integer := Pattern'First;
      T : Integer := Text'First;
      Star_P : Integer := Pattern'First - 1;  --  Position of the last "*"
      Star_T : Integer := Text'First;         --  Where that "*" stops
   begin
      while T <= Text'Last loop
         if P <= Pattern'Last and then Pattern (P) = '*' then
            Star_P := P;
            Star_T := T;
            P := P + 1;
         elsif P <= Pattern'Last
           and then (Pattern (P) = '?' or else Pattern (P) = Text (T))
         then
            P := P + 1;
            T := T + 1;
         elsif Star_P >= Pattern'First then
            --  Let the last "*" take one more character and retry
            Star_T := Star_T + 1;
            T := Star_T;
            P := Star_P + 1;
         else
            return False;
         end if;
      end loop;

      while P <= Pattern'Last and then Pattern (P) = '*' loop
         P := P + 1;
      end loop;

      return P > Pattern'Last;
   end Matches;

   ----------------
   -- Parse_Line --
   ----------------

   procedure Parse_Line
     (Line           : Wide_Wide_String;
      Number         : Positive;
      Origin         : Universal_String;
      Ignore_Unknown : Boolean;
      Rules          : in out Rule_Vectors.Vector;
      Errors         : in out String_Vector)
   is
      First : Integer := Line'First;
      Last  : Integer := Line'First - 1;

      Item       : Rule;
      Bad        : Boolean := False;
      Recognized : Boolean := False;
      Tokens     : Natural := 0;
      Length_Set : Boolean := False;
      Size_Set   : Boolean := False;

      procedure Apply (Key, Value : Wide_Wide_String);

      procedure Error (Message : Universal_String);

      function Is_Blank (Char : Wide_Wide_Character) return Boolean is
        (Char = ' ' or else Char = Latin.HT or else Char = Latin.CR);

      function Next_Token return Boolean;
      --  Set First .. Last to the next token. Return False at the end of the
      --  line or at a comment.

      -----------
      -- Apply --
      -----------

      procedure Apply (Key, Value : Wide_Wide_String) is

         procedure Get_Positive (Result : out Optional_Positive);

         ------------------
         -- Get_Positive --
         ------------------

         procedure Get_Positive (Result : out Optional_Positive) is
            Number  : Natural;
            Success : Boolean;
         begin
            Parse_Positive (Value, Number, Success);

            if Success then
               Result := (True, Number);
            else
               Result := (Is_Set => False);
               Error
                 ("invalid value '" & (+Value) & "' for " & (+Key)
                  & ": expected a positive integer");
            end if;
         end Get_Positive;

      begin
         if Key = "max_length" then
            Recognized := True;
            Length_Set := True;
            Item.Has_Size := True;
            Get_Positive (Item.Values.Max_Length);
         elsif Key = "max_size" then
            Recognized := True;
            Size_Set := True;
            Item.Has_Size := True;
            Get_Positive (Item.Values.Max_Size);
         elsif Key = "max_count" then
            Recognized := True;
            Item.Has_Count := True;
            Get_Positive (Item.Values.Max_Count);
         elsif Key = "type" then
            Recognized := True;
            Item.Has_Type := True;

            if Value = "default" or else Value = "FT_DEFAULT" then
               Item.Values.Allocation := Default_Allocation;
            elsif Value = "static" or else Value = "FT_STATIC" then
               Item.Values.Allocation := Static_Allocation;
            elsif Value = "ignore" or else Value = "FT_IGNORE" then
               Item.Values.Allocation := Ignore;
            elsif Value = "callback" or else Value = "FT_CALLBACK"
              or else Value = "pointer" or else Value = "FT_POINTER"
            then
               Error
                 ("type:" & (+Value)
                  & " is not supported by the SPARK back end");
            else
               Error ("invalid value '" & (+Value) & "' for type");
            end if;
         elsif Key = "on_unknown_enum" then
            Recognized := True;
            Item.Has_Enum := True;

            if Value = "reject" then
               Item.Values.On_Unknown_Enum := Reject;
            elsif Value = "first" then
               Item.Values.On_Unknown_Enum := Compiler.Options.First;
            else
               Error ("invalid value '" & (+Value) & "' for on_unknown_enum");
            end if;
         elsif not Ignore_Unknown then
            Error ("unknown option '" & (+Key) & "'");
         end if;
      end Apply;

      -----------
      -- Error --
      -----------

      procedure Error (Message : Universal_String) is
      begin
         Bad := True;
         Errors.Append (Origin & ":" & Image (Number) & ": " & Message);
      end Error;

      ----------------
      -- Next_Token --
      ----------------

      function Next_Token return Boolean is
      begin
         First := Last + 1;

         while First <= Line'Last and then Is_Blank (Line (First)) loop
            First := First + 1;
         end loop;

         if First > Line'Last
           or else Line (First) = '#'
           or else (First < Line'Last
                    and then Line (First .. First + 1) = "//")
         then
            return False;
         end if;

         Last := First;

         while Last < Line'Last and then not Is_Blank (Line (Last + 1)) loop
            Last := Last + 1;
         end loop;

         return True;
      end Next_Token;

   begin
      while Next_Token loop
         Tokens := Tokens + 1;

         if Tokens = 1 then
            Item.Pattern := +Line (First .. Last);
            Item.Line := Number;

            if Ada.Strings.Wide_Wide_Fixed.Index
              (Line (First .. Last), "[") > 0
            then
               Error (+"character classes are not supported in patterns");
            end if;
         else
            declare
               Colon : constant Natural :=
                 Ada.Strings.Wide_Wide_Fixed.Index
                   (Line (First .. Last), ":");
            begin
               if Colon = 0 then
                  Error
                    ("expected key:value, found '"
                     & (+Line (First .. Last)) & "'");
               else
                  Apply
                    (Line (First .. Colon - 1), Line (Colon + 1 .. Last));
               end if;
            end;
         end if;
      end loop;

      if Tokens = 1 then
         Error ("expected key:value after pattern '" & Item.Pattern & "'");
      end if;

      if Length_Set and Size_Set then
         Error (+"max_length and max_size can't be used together");
      end if;

      if Recognized and not Bad then
         Rules.Append (Item);
      end if;
   end Parse_Line;

   ---------------------
   -- Parse_Parameter --
   ---------------------

   procedure Parse_Parameter
     (Text   : League.Strings.Universal_String;
      Result : out Parameters;
      Errors : in out League.String_Vectors.Universal_String_Vector)
   is
      Items   : constant String_Vector :=
        Text.Split (',', League.Strings.Skip_Empty);
      Unknown : String_Vector;
   begin
      Result := (others => <>);

      for J in 1 .. Items.Length loop
         declare
            Item  : constant Wide_Wide_String :=
              Items (J).To_Wide_Wide_String;
            Equal : constant Natural :=
              Ada.Strings.Wide_Wide_Fixed.Index (Item, "=");
            Key   : constant Wide_Wide_String :=
              (if Equal = 0 then Item else Item (Item'First .. Equal - 1));
            Value : constant Wide_Wide_String :=
              (if Equal = 0 then "" else Item (Equal + 1 .. Item'Last));
         begin
            if Key = "runtime" then
               if Value = "spark" then
                  Result.Runtime := SPARK_Runtime;
               elsif Value = "league" then
                  Result.Runtime := League_Runtime;
               else
                  Errors.Append
                    ("invalid value '" & (+Value) & "' for runtime: "
                     & "expected spark or league");
               end if;
            elsif Key = "options" and then Value /= "" then
               Result.Option_Files.Append (+Value);
            elsif Key = "options_path" and then Value /= "" then
               Result.Search_Paths.Append (+Value);
            elsif Key = "ignore_unknown_options" and then Equal = 0 then
               Result.Ignore_Unknown := True;
            else
               Unknown.Append (Items (J));
            end if;
         end;
      end loop;

      if Result.Runtime = SPARK_Runtime then
         for J in 1 .. Unknown.Length loop
            Errors.Append ("invalid plugin parameter: " & Unknown (J));
         end loop;
      end if;
   end Parse_Parameter;

   --------------------
   -- Parse_Positive --
   --------------------

   procedure Parse_Positive
     (Text    : Wide_Wide_String;
      Value   : out Natural;
      Success : out Boolean) is
   begin
      Value := 0;
      Success := False;

      if Text'Length = 0 then
         return;
      end if;

      for Char of Text loop
         if Char not in '0' .. '9' then
            return;
         end if;

         declare
            Digit : constant Natural :=
              Wide_Wide_Character'Pos (Char) - Wide_Wide_Character'Pos ('0');
         begin
            if Value > (Natural'Last - Digit) / 10 then
               return;
            end if;

            Value := Value * 10 + Digit;
         end;
      end loop;

      Success := Value > 0;
   end Parse_Positive;

   ---------------
   -- Read_File --
   ---------------

   procedure Read_File
     (Path    : Universal_String;
      Lines   : out String_Vector;
      Success : out Boolean;
      Errors  : in out String_Vector)
   is
      File : Ada.Text_IO.File_Type;
   begin
      Lines.Clear;
      Success := False;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path.To_UTF_8_String);

      while not Ada.Text_IO.End_Of_File (File) loop
         Lines.Append
           (League.Strings.From_UTF_8_String (Ada.Text_IO.Get_Line (File)));
      end loop;

      Ada.Text_IO.Close (File);
      Success := True;
   exception
      when Ada.IO_Exceptions.Name_Error
         | Ada.IO_Exceptions.Use_Error
         | Ada.IO_Exceptions.Device_Error
         | Ada.IO_Exceptions.Data_Error
         | Constraint_Error =>

         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         Errors.Append ("can't read options file: " & Path);
   end Read_File;

   -------------------
   -- Report_Unused --
   -------------------

   procedure Report_Unused
     (Self     : Rule_Set;
      Warnings : in out League.String_Vectors.Universal_String_Vector) is
   begin
      for File of Self.Files loop
         for Item of File.Rules loop
            if not Item.Used then
               Warnings.Append
                 (File.Path & ":" & Image (Item.Line) & ": pattern '"
                  & Item.Pattern & "' matched no field");
            end if;
         end loop;
      end loop;
   end Report_Unused;

   ---------------------
   -- Strip_Extension --
   ---------------------

   function Strip_Extension (Name : Wide_Wide_String) return Wide_Wide_String
   is
      Suffix : constant Wide_Wide_String := ".proto";
   begin
      if Name'Length > Suffix'Length
        and then Name (Name'Last - Suffix'Length + 1 .. Name'Last) = Suffix
      then
         return Name (Name'First .. Name'Last - Suffix'Length);
      end if;

      return Name;
   end Strip_Extension;

end Compiler.Options;

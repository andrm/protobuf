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

package body PB_SPARK.UTF8 with SPARK_Mode is

   use type Byte;

   function Is_Continuation (Item : Byte) return Boolean is
     (Item in 16#80# .. 16#BF#);

   --------------
   -- Is_Valid --
   --------------

   function Is_Valid (Data : Byte_Array; Length : Index) return Boolean is
      Pos : Index := 1;
   begin
      while Pos <= Length loop
         pragma Loop_Invariant (Pos in 1 .. Length);
         pragma Loop_Variant (Increases => Pos);

         declare
            Lead : constant Byte := Data (Pos);
            Size : constant Index :=
              (case Lead is
                  when 16#00# .. 16#7F# => 1,
                  when 16#C2# .. 16#DF# => 2,
                  when 16#E0# .. 16#EF# => 3,
                  when 16#F0# .. 16#F4# => 4,
                  when others => 0);
         begin
            if Size = 0 or else Length + 1 - Pos < Size then
               return False;
            end if;

            if Size >= 2 then
               declare
                  Second : constant Byte := Data (Pos + 1);
               begin
                  if not Is_Continuation (Second)
                    or else (Lead = 16#E0# and then Second < 16#A0#)
                    or else (Lead = 16#ED# and then Second > 16#9F#)
                    or else (Lead = 16#F0# and then Second < 16#90#)
                    or else (Lead = 16#F4# and then Second > 16#8F#)
                  then
                     return False;
                  end if;
               end;
            end if;

            if Size >= 3 and then not Is_Continuation (Data (Pos + 2)) then
               return False;
            end if;

            if Size = 4 and then not Is_Continuation (Data (Pos + 3)) then
               return False;
            end if;

            Pos := Pos + Size;
         end;
      end loop;

      return True;
   end Is_Valid;

end PB_SPARK.UTF8;

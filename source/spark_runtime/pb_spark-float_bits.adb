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

with Ada.Unchecked_Conversion;

package body PB_SPARK.Float_Bits with SPARK_Mode => Off is

   function Cast is new Ada.Unchecked_Conversion
     (Unsigned_32, IEEE_Float_32);

   function Cast is new Ada.Unchecked_Conversion
     (Unsigned_64, IEEE_Float_64);

   function Cast is new Ada.Unchecked_Conversion
     (IEEE_Float_32, Unsigned_32);

   function Cast is new Ada.Unchecked_Conversion
     (IEEE_Float_64, Unsigned_64);

   function To_Float_32 (Bits : Unsigned_32) return IEEE_Float_32 is
     (Cast (Bits));

   function To_Float_64 (Bits : Unsigned_64) return IEEE_Float_64 is
     (Cast (Bits));

   function To_Bits (Value : IEEE_Float_32) return Unsigned_32 is
     (Cast (Value));

   function To_Bits (Value : IEEE_Float_64) return Unsigned_64 is
     (Cast (Value));

end PB_SPARK.Float_Bits;

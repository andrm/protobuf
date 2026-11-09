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

--  Conversion between the bits of a float or double field and floating-point
--  values. Generated code stores only bits, so it never touches floating
--  point and keeps NaN and infinities intact.
--
--  SPARK doesn't allow converting bits to floating-point values, so the body
--  of this package is not proved. It is the only unit in this runtime with
--  that property, and only applications that call it depend on it.

with Interfaces; use Interfaces;

package PB_SPARK.Float_Bits with SPARK_Mode, Pure is

   function Is_Finite (Bits : Unsigned_32) return Boolean is
     ((Bits and 16#7F80_0000#) /= 16#7F80_0000#);

   function Is_Finite (Bits : Unsigned_64) return Boolean is
     ((Bits and 16#7FF0_0000_0000_0000#) /= 16#7FF0_0000_0000_0000#);

   function To_Float_32 (Bits : Unsigned_32) return IEEE_Float_32
     with Pre => Is_Finite (Bits);

   function To_Float_64 (Bits : Unsigned_64) return IEEE_Float_64
     with Pre => Is_Finite (Bits);

   function To_Bits (Value : IEEE_Float_32) return Unsigned_32;

   function To_Bits (Value : IEEE_Float_64) return Unsigned_64;

end PB_SPARK.Float_Bits;

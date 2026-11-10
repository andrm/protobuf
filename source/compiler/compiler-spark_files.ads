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

--  Code generation for one .proto file in SPARK output.

with League.String_Vectors;

with Google.Protobuf.Compiler.Plugin;

with Compiler.Bounds;

package Compiler.SPARK_Files is

   procedure Generate
     (Request : Google.Protobuf.Compiler.Plugin.Code_Generator_Request;
      Bounds  : Compiler.Bounds.Analysis;
      Result  : in out Google.Protobuf.Compiler.Plugin.Code_Generator_Response;
      Errors  : in out League.String_Vectors.Universal_String_Vector);
   --  Add the Ada sources for the files to generate to Result, or report why
   --  they can't be generated

end Compiler.SPARK_Files;

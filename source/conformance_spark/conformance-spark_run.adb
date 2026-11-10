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

--  Conformance testee for SPARK generated code. It speaks the protocol of
--  Google's conformance_test_runner on standard input and output: each
--  request and response is a ConformanceRequest or ConformanceResponse
--  message after its length as 4 little-endian bytes. Both messages are
--  handled by SPARK code generated from conformance.proto.
--
--  Only protobuf input and output are supported, so other requests are
--  answered as skipped. A message that doesn't fit the bounds of
--  conformance_spark.options is reported as a runtime error, and other
--  decoding failures as parse errors.
--
--  This is a host program: unlike the generated code, it uses the heap, the
--  secondary stack and GNAT.OS_Lib.

with GNAT.OS_Lib;
with Interfaces;

with PB_SPARK;

with Conformance.Conformance;
with Protobuf_Test_Messages.Proto_2.Test_Messages_Proto_2;
with Protobuf_Test_Messages.Proto_3.Test_Messages_Proto_3;

procedure Conformance.SPARK_Run is
   use type Interfaces.Unsigned_32;
   use type PB_SPARK.Index;
   use type PB_SPARK.Status_Kind;

   package C renames Standard.Conformance.Conformance;
   package P2 renames Protobuf_Test_Messages.Proto_2.Test_Messages_Proto_2;
   package P3 renames Protobuf_Test_Messages.Proto_3.Test_Messages_Proto_3;

   use type C.Conformance_Request_Payload_Kind;
   use type C.Wire_Format;

   Max_Input : constant := 2 ** 24;
   --  Requests up to this size are read. Larger ones are discarded.

   type Input_Access is access PB_SPARK.Byte_Array;
   type Output_Access is access PB_SPARK.Byte_Array;
   type Request_Access is access C.Conformance_Request;
   type Response_Access is access C.Conformance_Response;
   type Proto_2_Access is access P2.Test_All_Types_Proto_2;
   type Proto_3_Access is access P3.Test_All_Types_Proto_3;

   --  The messages are large, so they live on the heap, not the stack

   Input    : constant Input_Access := new PB_SPARK.Byte_Array (1 .. Max_Input);
   Output   : constant Output_Access :=
     new PB_SPARK.Byte_Array (1 .. C.Conformance_Response_Max_Encoded_Size);
   Request  : constant Request_Access := new C.Conformance_Request;
   Response : constant Response_Access := new C.Conformance_Response;
   Proto_2  : constant Proto_2_Access := new P2.Test_All_Types_Proto_2;
   Proto_3  : constant Proto_3_Access := new P3.Test_All_Types_Proto_3;

   function Read_Exactly
     (Buffer : in out PB_SPARK.Byte_Array) return Boolean;
   --  Read Buffer'Length bytes from standard input. Return False at end of
   --  input.

   procedure Write_All (Buffer : PB_SPARK.Byte_Array);
   --  Write Buffer to standard output

   function Image (Text : C.Conformance_Request_Message_Type_String)
     return String;

   procedure Set_Result
     (Kind : C.Conformance_Response_Result_Kind;
      Text : String);
   --  Answer with a string result of the given kind

   procedure Run_Test;
   --  Fill Response for Request

   ------------------
   -- Read_Exactly --
   ------------------

   function Read_Exactly
     (Buffer : in out PB_SPARK.Byte_Array) return Boolean
   is
      Done : PB_SPARK.Index := 0;
      Got  : Integer;
   begin
      while Done < Buffer'Length loop
         Got := GNAT.OS_Lib.Read
           (GNAT.OS_Lib.Standin,
            Buffer (Buffer'First + Done)'Address,
            Integer (Buffer'Length - Done));

         if Got <= 0 then
            return False;
         end if;

         Done := Done + PB_SPARK.Index (Got);
      end loop;

      return True;
   end Read_Exactly;

   ---------------
   -- Write_All --
   ---------------

   procedure Write_All (Buffer : PB_SPARK.Byte_Array) is
      Done : PB_SPARK.Index := 0;
      Put  : Integer;
   begin
      while Done < Buffer'Length loop
         Put := GNAT.OS_Lib.Write
           (GNAT.OS_Lib.Standout,
            Buffer (Buffer'First + Done)'Address,
            Integer (Buffer'Length - Done));

         if Put <= 0 then
            GNAT.OS_Lib.OS_Exit (1);
         end if;

         Done := Done + PB_SPARK.Index (Put);
      end loop;
   end Write_All;

   -----------
   -- Image --
   -----------

   function Image (Text : C.Conformance_Request_Message_Type_String)
     return String
   is
      Result : String (1 .. Natural (Text.Length));
   begin
      for J in Result'Range loop
         Result (J) := Character'Val (Text.Data (PB_SPARK.Index (J)));
      end loop;

      return Result;
   end Image;

   ----------------
   -- Set_Result --
   ----------------

   procedure Set_Result
     (Kind : C.Conformance_Response_Result_Kind;
      Text : String)
   is
      procedure Copy
        (Data   : out PB_SPARK.Byte_Array;
         Length : out PB_SPARK.Index);

      procedure Copy
        (Data   : out PB_SPARK.Byte_Array;
         Length : out PB_SPARK.Index) is
      begin
         Data := (others => 0);
         Length := PB_SPARK.Index'Min (Data'Length, Text'Length);

         for J in 1 .. Length loop
            Data (J) := Character'Pos (Text (Text'First + Natural (J) - 1));
         end loop;
      end Copy;

   begin
      case Kind is
         when C.Parse_Error_Kind =>
            Response.Result := (Result => C.Parse_Error_Kind, others => <>);
            Copy (Response.Result.Parse_Error.Data,
                  Response.Result.Parse_Error.Length);
         when C.Runtime_Error_Kind =>
            Response.Result := (Result => C.Runtime_Error_Kind, others => <>);
            Copy (Response.Result.Runtime_Error.Data,
                  Response.Result.Runtime_Error.Length);
         when C.Skipped_Kind =>
            Response.Result := (Result => C.Skipped_Kind, others => <>);
            Copy (Response.Result.Skipped.Data,
                  Response.Result.Skipped.Length);
         when others =>
            raise Program_Error;
      end case;
   end Set_Result;

   --------------
   -- Run_Test --
   --------------

   procedure Run_Test is
      Proto_2_Name : constant String :=
        "protobuf_test_messages.proto2.TestAllTypesProto2";
      Proto_3_Name : constant String :=
        "protobuf_test_messages.proto3.TestAllTypesProto3";

      Name   : constant String := Image (Request.Message_Type);
      Status : PB_SPARK.Status_Kind;
      Last   : PB_SPARK.Index;
   begin
      if Request.Payload.Payload /= C.Protobuf_Payload_Kind then
         Set_Result (C.Skipped_Kind, "Only protobuf input is supported");
         return;
      elsif Request.Requested_Output_Format /= C.PROTOBUF then
         Set_Result
           (C.Skipped_Kind,
            "Unsupported output format: "
            & C.Wire_Format'Image (Request.Requested_Output_Format));
         return;
      elsif Name /= Proto_2_Name and Name /= Proto_3_Name then
         Set_Result (C.Skipped_Kind, "Unsupported message type: " & Name);
         return;
      end if;

      declare
         Length : constant PB_SPARK.Index :=
           Request.Payload.Protobuf_Payload.Length;
      begin
         if Name = Proto_2_Name then
            P2.Decode
              (Request.Payload.Protobuf_Payload.Data (1 .. Length),
               Proto_2.all,
               Status);
         else
            P3.Decode
              (Request.Payload.Protobuf_Payload.Data (1 .. Length),
               Proto_3.all,
               Status);
         end if;
      end;

      if Status = PB_SPARK.Limit_Exceeded then
         Set_Result
           (C.Runtime_Error_Kind,
            "Limit_Exceeded: input exceeds conformance_spark.options");
         return;
      elsif Status /= PB_SPARK.OK then
         Set_Result (C.Parse_Error_Kind, PB_SPARK.Status_Kind'Image (Status));
         return;
      end if;

      --  Encode in place. The bound of protobuf_payload in the options file
      --  must be at least the maximum encoded size of the test messages,
      --  which the precondition of Encode checks.

      Response.Result := (Result => C.Protobuf_Payload_Kind, others => <>);

      if Name = Proto_2_Name then
         P2.Encode (Proto_2.all, Response.Result.Protobuf_Payload.Data, Last);
      else
         P3.Encode (Proto_3.all, Response.Result.Protobuf_Payload.Data, Last);
      end if;

      Response.Result.Protobuf_Payload.Length := Last;
   end Run_Test;

   Header : PB_SPARK.Byte_Array (1 .. 4);
   Size   : Interfaces.Unsigned_32;
   Status : PB_SPARK.Status_Kind;
   Last   : PB_SPARK.Index;
begin
   loop
      exit when not Read_Exactly (Header);

      Size := 0;

      for J in reverse Header'Range loop
         Size := Size * 256 + Interfaces.Unsigned_32 (Header (J));
      end loop;

      if Size > Max_Input then
         --  Discard the request
         while Size > 0 loop
            declare
               Part : constant PB_SPARK.Index :=
                 PB_SPARK.Index (Interfaces.Unsigned_32'Min (Size, Max_Input));
            begin
               exit when not Read_Exactly (Input (1 .. Part));
               Size := Size - Interfaces.Unsigned_32 (Part);
            end;
         end loop;

         Set_Result (C.Runtime_Error_Kind, "Request is too large");
      else
         exit when not Read_Exactly (Input (1 .. PB_SPARK.Index (Size)));
         C.Decode (Input (1 .. PB_SPARK.Index (Size)), Request.all, Status);

         if Status = PB_SPARK.OK then
            Run_Test;
         else
            Set_Result
              (C.Runtime_Error_Kind,
               "Can't decode ConformanceRequest: "
               & PB_SPARK.Status_Kind'Image (Status));
         end if;
      end if;

      C.Encode (Response.all, Output.all, Last);

      Size := Interfaces.Unsigned_32 (Last);

      for J in Header'Range loop
         Header (J) := PB_SPARK.Byte (Size mod 256);
         Size := Size / 256;
      end loop;

      Write_All (Header);
      Write_All (Output (1 .. Last));
   end loop;
end Conformance.SPARK_Run;

--  Check the defaults of proto2 strings, bytes and oneofs

with Ada.Text_IO;

with PB_SPARK;
with Two.Two;

procedure Check is
   use type PB_SPARK.Byte_Array;
   use type PB_SPARK.Index;
   use type Two.Two.Coll_2_Choice_Kind;

   V      : Two.Two.Coll_2;
   Buffer : PB_SPARK.Byte_Array (1 .. Two.Two.Coll_2_Max_Encoded_Size);
   Last   : PB_SPARK.Index;
   Failed : Boolean := False;

   procedure Expect (Condition : Boolean; Text : String) is
   begin
      if not Condition then
         Ada.Text_IO.Put_Line ("failed: " & Text);
         Failed := True;
      end if;
   end Expect;

begin
   Expect (not V.Has_Name, "Has_Name");
   Expect (V.Name.Length = 6, "Name.Length");
   Expect (V.Name.Data = (16#68#, 16#C3#, 16#A9#, 16#6C#, 16#6C#, 16#6F#),
           "Name.Data");
   Expect (V.Blob.Length = 5, "Blob.Length");
   Expect (V.Blob.Data = (97, 1, 255, 34, 92), "Blob.Data");
   Expect (V.Choice.Choice = Two.Two.Choice_Not_Set, "Choice");
   Expect (V.Nums_Count = 0, "Nums_Count");

   V.Name.Length := 0;
   Two.Two.Clear (V);
   Expect (V.Name.Length = 6, "Name.Length after Clear");

   --  Only the required string is written
   Two.Two.Encode (V, Buffer, Last);
   Expect (Last = 2 and then Buffer (1 .. 2) = (16#6A#, 0), "Encode");

   if Failed then
      raise Program_Error;
   end if;
end Check;

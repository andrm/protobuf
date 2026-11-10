--  Check that Merge doesn't keep stale data of unused elements, and that a
--  oneof can be set and encoded from Ada

with Ada.Text_IO;

with Interfaces;
with PB_SPARK;
with Coll;

procedure Check is
   use type Interfaces.Integer_32;
   use type PB_SPARK.Index;
   use type PB_SPARK.Status_Kind;
   use type Coll.Coll_Choice_Kind;

   --  items { id: 5 }
   Input  : constant PB_SPARK.Byte_Array := (16#32#, 2, 16#08#, 5);
   V      : Coll.Coll;
   W      : Coll.Coll;
   Buffer : PB_SPARK.Byte_Array (1 .. Coll.Coll_Max_Encoded_Size);
   Last   : PB_SPARK.Index;
   Pos    : PB_SPARK.Index := 1;
   Status : PB_SPARK.Status_Kind;
   Failed : Boolean := False;

   procedure Expect (Condition : Boolean; Text : String) is
   begin
      if not Condition then
         Ada.Text_IO.Put_Line ("failed: " & Text);
         Failed := True;
      end if;
   end Expect;

begin
   V.Items (1) := (Id => 9, Other => 9);
   V.Items_Count := 0;
   Coll.Merge (Input, Input'Last, Pos, V, Status);
   Expect (Status = PB_SPARK.OK and Pos = Input'Last + 1, "Merge");
   Expect (V.Items_Count = 1, "Items_Count");
   Expect (V.Items (1).Id = 5 and V.Items (1).Other = 0, "stale element");

   V.Choice := (Choice => Coll.M_Kind, M => (Id => 1, Other => 0));
   Coll.Encode (V, Buffer, Last);
   Coll.Decode (Buffer (1 .. Last), W, Status);
   Expect (Status = PB_SPARK.OK, "Decode");
   Expect (W.Choice.Choice = Coll.M_Kind and then W.Choice.M.Id = 1,
           "oneof round trip");

   if Failed then
      raise Program_Error;
   end if;
end Check;

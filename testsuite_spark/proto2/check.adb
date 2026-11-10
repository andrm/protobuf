--  Check proto2 default values and presence after decoding

with Ada.Command_Line;
with Ada.Text_IO;

with Interfaces;
with PB_SPARK;
with PB_SPARK.Float_Bits;
with Legacy.Legacy;

procedure Check is
   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.IEEE_Float_32;
   use type Interfaces.IEEE_Float_64;
   use type PB_SPARK.Status_Kind;
   use type Legacy.Legacy.Level;

   Empty : constant PB_SPARK.Byte_Array (1 .. 2) := (16#08#, 16#00#);
   V     : Legacy.Legacy.Settings;
   S     : PB_SPARK.Status_Kind;

   procedure Expect (Condition : Boolean; Name : String) is
   begin
      if not Condition then
         Ada.Text_IO.Put_Line ("FAILED: " & Name);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end Expect;
begin
   Legacy.Legacy.Decode (Empty, V, S);
   Expect (S = PB_SPARK.OK, "decodes");
   Expect (V.Has_Id and not V.Has_Retries, "presence");
   Expect (V.Retries = -3, "int default");
   Expect (V.Verbose, "bool default");
   Expect (PB_SPARK.Float_Bits.To_Float_64 (V.Ratio) = 1.5, "double default");
   Expect (V.Scale = 16#FF80_0000#, "float default");
   Expect (V.Level = Legacy.Legacy.HIGH, "enum default");
   Expect (V.Big = Interfaces.Unsigned_64'Last, "uint64 default");
   Expect (not V.Has_Child, "message absent");
   Expect (Legacy.Legacy.Is_Initialized (V), "initialized");
   V.Has_Child := True;
   Expect (not Legacy.Legacy.Is_Initialized (V), "nested required missing");
end Check;

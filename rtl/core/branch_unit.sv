// =============================================================================
// branch_unit.sv - decides whether a conditional branch is taken
//
// funct3 of the branch instruction selects the comparison:
//   000 beq   001 bne   100 blt   101 bge   110 bltu   111 bgeu
// =============================================================================
module branch_unit (
  input  logic [2:0]  funct3,
  input  logic [31:0] a,        // rs1 (after forwarding)
  input  logic [31:0] b,        // rs2 (after forwarding)
  output logic        taken
);

  always_comb begin
    unique case (funct3)
      3'b000:  taken = (a == b);
      3'b001:  taken = (a != b);
      3'b100:  taken = ($signed(a) <  $signed(b));
      3'b101:  taken = ($signed(a) >= $signed(b));
      3'b110:  taken = (a <  b);
      3'b111:  taken = (a >= b);
      default: taken = 1'b0;    // 010/011 are rejected as illegal by the decoder
    endcase
  end

endmodule

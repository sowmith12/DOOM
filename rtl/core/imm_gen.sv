// =============================================================================
// imm_gen.sv - builds the 32-bit immediate (constant) out of instruction bits
//
// RISC-V scatters the immediate bits around the instruction so that the
// register fields always stay in the same place. This block glues them back
// together and sign-extends (copies bit 31 of the instruction into the top).
//
//   I-type  addi/loads/jalr : imm[11:0]           = instr[31:20]
//   S-type  stores          : imm[11:5|4:0]       = instr[31:25|11:7]
//   B-type  branches        : imm[12|10:5|4:1|11] = instr[31|30:25|11:8|7], imm[0]=0
//   U-type  lui/auipc       : imm[31:12]          = instr[31:12], low 12 bits 0
//   J-type  jal             : imm[20|10:1|11|19:12] = instr[31|30:21|20|19:12], imm[0]=0
//   Z       csr*i           : 5-bit unsigned value in the rs1 field
// =============================================================================
module imm_gen
  import core_pkg::*;
(
  input  logic [31:0] instr,
  input  imm_type_t   imm_type,
  output logic [31:0] imm
);

  always_comb begin
    unique case (imm_type)
      IMM_I:   imm = {{20{instr[31]}}, instr[31:20]};
      IMM_S:   imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      IMM_B:   imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
      IMM_U:   imm = {instr[31:12], 12'b0};
      IMM_J:   imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
      IMM_Z:   imm = {27'b0, instr[19:15]};
      default: imm = 32'b0;
    endcase
  end

endmodule

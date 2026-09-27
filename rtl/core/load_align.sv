// =============================================================================
// load_align.sv - picks the requested byte/half out of a 32-bit memory word
// and sign- or zero-extends it (MEM stage). Also reports misalignment, which
// the EX stage checks before the load is sent to memory.
//
//   lb  : byte,  sign-extended      lbu : byte,  zero-extended
//   lh  : half,  sign-extended      lhu : half,  zero-extended
//   lw  : full word
// =============================================================================
module load_align
  import core_pkg::*;
(
  input  logic [2:0]  funct3,
  input  logic [1:0]  addr_lo,
  input  logic [31:0] rdata,       // the whole word from memory
  output logic [31:0] value,
  output logic        misaligned
);

  logic [7:0]  byte_sel;
  logic [15:0] half_sel;

  always_comb begin
    byte_sel = rdata[8*addr_lo +: 8];
    half_sel = addr_lo[1] ? rdata[31:16] : rdata[15:0];

    value      = rdata;
    misaligned = 1'b0;
    unique case (funct3)
      F3_B:  value = {{24{byte_sel[7]}},  byte_sel};
      F3_BU: value = {24'b0,              byte_sel};
      F3_H:  begin value = {{16{half_sel[15]}}, half_sel}; misaligned = addr_lo[0];         end
      F3_HU: begin value = {16'b0,              half_sel}; misaligned = addr_lo[0];         end
      F3_W:  begin value = rdata;                          misaligned = (addr_lo != 2'b00); end
      default: ;
    endcase
  end

endmodule

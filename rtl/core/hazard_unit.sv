// =============================================================================
// hazard_unit.sv - forwarding (bypassing) and load-use stall detection
//
// FORWARDING: an instruction in EX may need a register that an OLDER
// instruction (now in MEM or WB) has computed but not yet written back.
// Instead of waiting, we take the value straight from the pipeline register:
//
//     priority 1: EX/MEM.result   (the instruction just ahead of us)
//     priority 2: MEM/WB.wb_data  (two ahead)
//     otherwise : the value read from the register file in ID
//
//   The newest value must win, which is why EX/MEM is checked first.
//   Loads in EX/MEM have no data yet (it arrives in MEM), so they are skipped;
//   the load-use stall below guarantees we never actually need them.
//
// LOAD-USE STALL: if the instruction in ID needs the result of a LOAD that is
// in EX right now, the data will not exist until the end of MEM. We hold ID
// (and IF) for one cycle and send a bubble into EX. One cycle later the load
// is in WB and normal forwarding (priority 2) delivers the value.
//
//   cycle:     1     2     3     4
//   lw  x1    EX    MEM   WB
//   add x2,x1 ID    ID*   EX         (* = stalled, bubble goes into EX)
//
// 🔗 Armaan's lesson: track register usage explicitly (uses_rs1/uses_rs2)
//    instead of fragile guesses, so we never stall for a register that an
//    instruction does not really read.
// =============================================================================
module hazard_unit
  import core_pkg::*;
(
  // instruction in ID
  input  logic        id_valid,
  input  logic [4:0]  id_rs1,
  input  logic [4:0]  id_rs2,
  input  logic        id_uses_rs1,
  input  logic        id_uses_rs2,

  // instruction in EX
  input  logic        ex_valid,
  input  logic [4:0]  ex_rs1,
  input  logic [4:0]  ex_rs2,
  input  logic        ex_is_load,
  input  logic        ex_reg_write,
  input  logic [4:0]  ex_rd,

  // instruction in MEM
  input  logic        mem_valid,
  input  logic        mem_reg_write,
  input  logic        mem_is_load,
  input  logic [4:0]  mem_rd,

  // instruction in WB
  input  logic        wb_valid,
  input  logic        wb_reg_write,
  input  logic [4:0]  wb_rd,

  output logic [1:0]  fwd_a,          // 0 = register file, 1 = from MEM, 2 = from WB
  output logic [1:0]  fwd_b,
  output logic        load_use_stall
);

  localparam logic [1:0] FWD_NONE = 2'd0;
  localparam logic [1:0] FWD_MEM  = 2'd1;
  localparam logic [1:0] FWD_WB   = 2'd2;

  // (reg_write is already 0 whenever rd == x0, see decoder.sv)
  always_comb begin
    fwd_a = FWD_NONE;
    if      (mem_valid && mem_reg_write && !mem_is_load && mem_rd == ex_rs1) fwd_a = FWD_MEM;
    else if (wb_valid  && wb_reg_write  &&                 wb_rd  == ex_rs1) fwd_a = FWD_WB;

    fwd_b = FWD_NONE;
    if      (mem_valid && mem_reg_write && !mem_is_load && mem_rd == ex_rs2) fwd_b = FWD_MEM;
    else if (wb_valid  && wb_reg_write  &&                 wb_rd  == ex_rs2) fwd_b = FWD_WB;
  end

  assign load_use_stall = id_valid && ex_valid && ex_is_load && ex_reg_write &&
                          ((id_uses_rs1 && id_rs1 == ex_rd) ||
                           (id_uses_rs2 && id_rs2 == ex_rd));

endmodule

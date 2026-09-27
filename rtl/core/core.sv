// =============================================================================
// core.sv - 5-stage pipelined RV32IM CPU  (IF -> ID -> EX -> MEM -> WB)
//
// See first.md (repo root) and docs/datapath.png for the datapath and a full explanation.
//
// -----------------------------------------------------------------------------
// MEMORY PORT PROTOCOL (same for the instruction port and the data port)
// -----------------------------------------------------------------------------
//   Cycle N   : core drives req/addr(/we/wdata/wstrb). If hold = 0, the memory
//               ACCEPTS the request at the clock edge ending cycle N.
//   Cycle N+1 : memory drives rdata for that request, or busy = 1 if it needs
//               more time (cache miss). While ANY port is busy the whole
//               pipeline freezes (hold = 1), so the core keeps waiting.
//   hold = 1  : "the pipeline is not moving": do not accept a new request and
//               keep rdata stable.
//
//   Why this shape? FPGA block RAM needs the address one clock BEFORE the data
//   comes out. So we send the fetch address for the NEXT pc, and the data
//   address from the EX stage; the answers arrive in IF and MEM respectively.
//   A simple BRAM, a cache or a slow model all fit behind this contract.
//
// -----------------------------------------------------------------------------
// WHERE THINGS HAPPEN
// -----------------------------------------------------------------------------
//   IF  : pc register; instruction arrives from the instruction port
//   ID  : decode, read registers, detect load-use hazards
//   EX  : forwarding muxes, ALU, branch/jump decision, mul/div, CSRs,
//         ALL exceptions + mret + fence.i  -> the "commit point"
//         data-port request (load/store) is sent from here
//   MEM : load data arrives, is aligned/sign-extended
//   WB  : write the register file, report "retired" instruction
//
//   Branches/jumps are resolved in EX: a taken branch throws away the two
//   younger instructions in IF and ID (2-cycle penalty; prediction comes later).
//
//   Exceptions are taken in EX. Older instructions (in MEM/WB) cannot fault,
//   and younger ones have not touched anything yet, so traps are PRECISE.
// =============================================================================
module core
  import core_pkg::*;
#(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
)(
  input  logic        clk,
  input  logic        rst,             // synchronous, active high

  // ---- instruction port ----
  output logic        imem_req,
  output logic [31:0] imem_addr,
  output logic        imem_hold,
  input  logic [31:0] imem_rdata,
  input  logic        imem_busy,

  // ---- data port ----
  output logic        dmem_req,
  output logic        dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_wstrb,
  output logic        dmem_hold,
  input  logic [31:0] dmem_rdata,
  input  logic        dmem_busy,

  // ---- fence.i: ask the caches to sync (write back D$, invalidate I$) ----
  output logic        fencei_req,
  input  logic        fencei_busy,     // tie to 0 when there are no caches

  // ---- retire port: one pulse per completed instruction (trace/debug) ----
  output logic        retire_valid,
  output logic [31:0] retire_pc,
  output logic [31:0] retire_instr,
  output logic        retire_we,
  output logic [4:0]  retire_rd,
  output logic [31:0] retire_wdata
);

  // ===========================================================================
  // Pipeline registers
  // ===========================================================================
  logic [31:0] pc;          // address of the instruction in IF
  logic        if_valid;    // 0 only right after reset (no fetch issued yet)
  if_id_t      if_id;
  id_ex_t      id_ex;
  ex_mem_t     ex_mem;
  mem_wb_t     mem_wb;

  // ===========================================================================
  // Global control signals
  // ===========================================================================
  logic        div_busy;
  logic        global_stall;    // something is waiting: freeze everything
  logic        advance;         // = !global_stall: all pipeline registers move
  logic        load_use_stall;  // hold IF+ID one cycle, bubble into EX
  logic        redirect;        // EX changes the program flow
  logic [31:0] redirect_pc;
  logic        pc_update;       // pc register loads pc_next this edge
  logic [31:0] pc_next;

  assign global_stall = imem_busy | dmem_busy | div_busy | fencei_busy;
  assign advance      = !global_stall;
  assign pc_update    = advance && (redirect || !load_use_stall);

  // ===========================================================================
  // IF - instruction fetch
  // ===========================================================================
  always_comb begin
    if (redirect)       pc_next = redirect_pc;
    else if (!if_valid) pc_next = pc;            // first fetch after reset
    else                pc_next = pc + 32'd4;
  end

  assign imem_req  = 1'b1;
  assign imem_addr = pc_next;
  assign imem_hold = !pc_update;     // memory accepts exactly when pc moves

  // ===========================================================================
  // ID - decode + register read
  // ===========================================================================
  ctrl_t       id_ctrl;
  logic [31:0] rf_rdata1, rf_rdata2;
  logic        wb_we;

  decoder u_decoder (
    .instr (if_id.instr),
    .ctrl  (id_ctrl)
  );

  assign wb_we = mem_wb.valid && mem_wb.reg_write;

  regfile u_regfile (
    .clk    (clk),
    .raddr1 (id_ctrl.rs1),
    .raddr2 (id_ctrl.rs2),
    .rdata1 (rf_rdata1),
    .rdata2 (rf_rdata2),
    .we     (wb_we),
    .waddr  (mem_wb.rd),
    .wdata  (mem_wb.wb_data)
  );

  // ===========================================================================
  // Hazards / forwarding
  // ===========================================================================
  logic [1:0] fwd_a, fwd_b;

  hazard_unit u_hazard (
    .id_valid       (if_id.valid),
    .id_rs1         (id_ctrl.rs1),
    .id_rs2         (id_ctrl.rs2),
    .id_uses_rs1    (id_ctrl.uses_rs1),
    .id_uses_rs2    (id_ctrl.uses_rs2),
    .ex_valid       (id_ex.valid),
    .ex_rs1         (id_ex.ctrl.rs1),
    .ex_rs2         (id_ex.ctrl.rs2),
    .ex_is_load     (id_ex.ctrl.is_load),
    .ex_reg_write   (id_ex.ctrl.reg_write),
    .ex_rd          (id_ex.ctrl.rd),
    .mem_valid      (ex_mem.valid),
    .mem_reg_write  (ex_mem.reg_write),
    .mem_is_load    (ex_mem.is_load),
    .mem_rd         (ex_mem.rd),
    .wb_valid       (mem_wb.valid),
    .wb_reg_write   (mem_wb.reg_write),
    .wb_rd          (mem_wb.rd),
    .fwd_a          (fwd_a),
    .fwd_b          (fwd_b),
    .load_use_stall (load_use_stall)
  );

  // ===========================================================================
  // EX - execute
  // ===========================================================================
  ctrl_t       ex_ctrl;
  logic [31:0] rs1_fwd, rs2_fwd;       // operands after forwarding
  logic [31:0] alu_a, alu_b, alu_y;
  logic        branch_cond;
  logic        jump_taken;
  logic [31:0] jump_target;
  logic [31:0] pc_plus4;
  logic [31:0] muldiv_result;
  logic [31:0] csr_rdata;
  logic        csr_illegal;
  logic [31:0] mtvec, mepc;
  logic [31:0] st_wdata;
  logic [3:0]  st_wstrb;
  logic        st_misaligned, ld_misaligned;
  logic [31:0] ex_result;

  assign ex_ctrl  = id_ex.ctrl;
  assign pc_plus4 = id_ex.pc + 32'd4;

  // ---- forwarding muxes ----
  always_comb begin
    unique case (fwd_a)
      2'd1:    rs1_fwd = ex_mem.result;
      2'd2:    rs1_fwd = mem_wb.wb_data;
      default: rs1_fwd = id_ex.rs1_val;
    endcase
    unique case (fwd_b)
      2'd1:    rs2_fwd = ex_mem.result;
      2'd2:    rs2_fwd = mem_wb.wb_data;
      default: rs2_fwd = id_ex.rs2_val;
    endcase
  end

  // ---- ALU ----
  always_comb begin
    unique case (ex_ctrl.src_a)
      SRC_A_PC:   alu_a = id_ex.pc;
      SRC_A_ZERO: alu_a = 32'd0;
      default:    alu_a = rs1_fwd;
    endcase
    alu_b = ex_ctrl.src_b_imm ? ex_ctrl.imm : rs2_fwd;
  end

  alu u_alu (
    .op (ex_ctrl.alu_op),
    .a  (alu_a),
    .b  (alu_b),
    .y  (alu_y)
  );

  // ---- branches and jumps ----
  branch_unit u_branch (
    .funct3 (ex_ctrl.funct3),
    .a      (rs1_fwd),
    .b      (rs2_fwd),
    .taken  (branch_cond)
  );

  assign jump_taken  = ex_ctrl.is_jal || ex_ctrl.is_jalr || (ex_ctrl.is_branch && branch_cond);
  assign jump_target = ex_ctrl.is_jalr ? ((rs1_fwd + ex_ctrl.imm) & ~32'd1)
                                       : (id_ex.pc + ex_ctrl.imm);

  // ---- multiply / divide ----
  muldiv u_muldiv (
    .clk     (clk),
    .rst     (rst),
    .valid   (id_ex.valid && ex_ctrl.is_muldiv),
    .op      (ex_ctrl.funct3),
    .a       (rs1_fwd),
    .b       (rs2_fwd),
    .advance (advance),
    .result  (muldiv_result),
    .busy    (div_busy)
  );

  // ---- load/store address checks and store data ----
  store_align u_store_align (
    .funct3     (ex_ctrl.funct3),
    .addr_lo    (alu_y[1:0]),
    .data       (rs2_fwd),
    .wdata      (st_wdata),
    .wstrb      (st_wstrb),
    .misaligned (st_misaligned)
  );

  load_align u_load_check (         // only its `misaligned` output is used here
    .funct3     (ex_ctrl.funct3),
    .addr_lo    (alu_y[1:0]),
    .rdata      (32'd0),
    .value      (),
    .misaligned (ld_misaligned)
  );

  // ---- exceptions (all decided here, in EX) ----
  logic        ex_exc;
  logic [31:0] ex_cause, ex_tval;

  always_comb begin
    ex_exc   = 1'b0;
    ex_cause = 32'd0;
    ex_tval  = 32'd0;
    if (id_ex.valid) begin
      if (ex_ctrl.illegal || csr_illegal) begin
        ex_exc = 1'b1; ex_cause = EXC_ILLEGAL_INSTR;    ex_tval = id_ex.instr;
      end else if (ex_ctrl.is_ecall) begin
        ex_exc = 1'b1; ex_cause = EXC_ECALL_M;          ex_tval = 32'd0;
      end else if (ex_ctrl.is_ebreak) begin
        ex_exc = 1'b1; ex_cause = EXC_BREAKPOINT;       ex_tval = id_ex.pc;
      end else if (jump_taken && jump_target[1:0] != 2'b00) begin
        ex_exc = 1'b1; ex_cause = EXC_INSTR_MISALIGNED; ex_tval = jump_target;
      end else if (ex_ctrl.is_load && ld_misaligned) begin
        ex_exc = 1'b1; ex_cause = EXC_LOAD_MISALIGNED;  ex_tval = alu_y;
      end else if (ex_ctrl.is_store && st_misaligned) begin
        ex_exc = 1'b1; ex_cause = EXC_STORE_MISALIGNED; ex_tval = alu_y;
      end
    end
  end

  // ---- CSRs ----
  csr_file u_csr (
    .clk           (clk),
    .rst           (rst),
    .advance       (advance),
    .csr_access    (id_ex.valid && ex_ctrl.is_csr),
    .csr_addr      (id_ex.instr[31:20]),
    .csr_op        (ex_ctrl.funct3),
    .csr_src       (ex_ctrl.funct3[2] ? ex_ctrl.imm : rs1_fwd),
    .csr_rs1_field (ex_ctrl.rs1),
    .csr_rdata     (csr_rdata),
    .csr_illegal   (csr_illegal),
    .trap          (ex_exc),
    .trap_cause    (ex_cause),
    .trap_pc       (id_ex.pc),
    .trap_tval     (ex_tval),
    .mret          (id_ex.valid && ex_ctrl.is_mret && !ex_exc),
    // minstret counts an instruction when it passes EX without trapping: from
    // that point it WILL complete (MEM/WB cannot fault). Counting at WB instead
    // would make `csrr minstret` miss the 1-2 older instructions still in MEM/WB.
    .retire        (id_ex.valid && !ex_exc && advance),
    .mtvec         (mtvec),
    .mepc          (mepc)
  );

  // ---- change of program flow ----
  always_comb begin
    redirect    = 1'b0;
    redirect_pc = 32'd0;
    if (id_ex.valid) begin
      if (ex_exc) begin
        redirect = 1'b1; redirect_pc = mtvec;          // trap -> handler
      end else if (ex_ctrl.is_mret) begin
        redirect = 1'b1; redirect_pc = mepc;           // return from trap
      end else if (jump_taken) begin
        redirect = 1'b1; redirect_pc = jump_target;    // taken branch / jal / jalr
      end else if (ex_ctrl.is_fencei) begin
        redirect = 1'b1; redirect_pc = pc_plus4;       // refetch after cache sync
      end
    end
  end

  assign fencei_req = id_ex.valid && ex_ctrl.is_fencei && !ex_exc;

  // ---- EX result ----
  always_comb begin
    if (ex_ctrl.is_jal || ex_ctrl.is_jalr) ex_result = pc_plus4;
    else if (ex_ctrl.is_csr)               ex_result = csr_rdata;
    else if (ex_ctrl.is_muldiv)            ex_result = muldiv_result;
    else                                   ex_result = alu_y;
  end

  // ---- data memory request (leaves from EX, answer arrives in MEM) ----
  assign dmem_req   = id_ex.valid && (ex_ctrl.is_load || ex_ctrl.is_store) && !ex_exc;
  assign dmem_we    = ex_ctrl.is_store;
  assign dmem_addr  = alu_y;
  assign dmem_wdata = st_wdata;
  assign dmem_wstrb = ex_ctrl.is_store ? st_wstrb : 4'b0000;
  assign dmem_hold  = global_stall;

  // ===========================================================================
  // MEM - load data comes back
  // ===========================================================================
  logic [31:0] load_value;

  load_align u_load_align (
    .funct3     (ex_mem.funct3),
    .addr_lo    (ex_mem.addr_lo),
    .rdata      (dmem_rdata),
    .value      (load_value),
    .misaligned ()
  );

  // ===========================================================================
  // WB - retire
  // ===========================================================================
  assign retire_valid = mem_wb.valid && advance;
  assign retire_pc    = mem_wb.pc;
  assign retire_instr = mem_wb.instr;
  assign retire_we    = mem_wb.reg_write;
  assign retire_rd    = mem_wb.rd;
  assign retire_wdata = mem_wb.wb_data;

  // ===========================================================================
  // Pipeline register updates (one clock edge moves everything one stage)
  // ===========================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      pc           <= RESET_PC;
      if_valid     <= 1'b0;
      if_id.valid  <= 1'b0;
      id_ex.valid  <= 1'b0;
      ex_mem.valid <= 1'b0;
      mem_wb.valid <= 1'b0;
    end else if (advance) begin
      // ---- IF: pc ----
      if (pc_update) begin
        pc       <= pc_next;
        if_valid <= 1'b1;
      end

      // ---- IF -> ID ----
      if (redirect) begin
        if_id.valid <= 1'b0;                       // wrong-path instruction: drop
      end else if (!load_use_stall) begin
        if_id.valid <= if_valid;
        if_id.pc    <= pc;
        if_id.instr <= imem_rdata;
      end                                          // else: hold (load-use stall)

      // ---- ID -> EX ----
      if (redirect || load_use_stall) begin
        id_ex.valid <= 1'b0;                       // bubble
      end else begin
        id_ex.valid   <= if_id.valid;
        id_ex.pc      <= if_id.pc;
        id_ex.instr   <= if_id.instr;
        id_ex.ctrl    <= id_ctrl;
        id_ex.rs1_val <= rf_rdata1;
        id_ex.rs2_val <= rf_rdata2;
      end

      // ---- EX -> MEM ----
      ex_mem.valid     <= id_ex.valid && !ex_exc;  // a trapping instruction dies here
      ex_mem.pc        <= id_ex.pc;
      ex_mem.instr     <= id_ex.instr;
      ex_mem.reg_write <= ex_ctrl.reg_write;
      ex_mem.rd        <= ex_ctrl.rd;
      ex_mem.is_load   <= ex_ctrl.is_load;
      ex_mem.funct3    <= ex_ctrl.funct3;
      ex_mem.addr_lo   <= alu_y[1:0];
      ex_mem.result    <= ex_result;

      // ---- MEM -> WB ----
      mem_wb.valid     <= ex_mem.valid;
      mem_wb.pc        <= ex_mem.pc;
      mem_wb.instr     <= ex_mem.instr;
      mem_wb.reg_write <= ex_mem.reg_write;
      mem_wb.rd        <= ex_mem.rd;
      mem_wb.wb_data   <= ex_mem.is_load ? load_value : ex_mem.result;
    end
  end

endmodule

// =============================================================================
// csr_file.sv - Control and Status Registers (machine mode only) + trap logic
//
// Used by the EX stage. CSR instructions read the OLD value (it goes to rd)
// and write the NEW value at the clock edge when the pipeline advances.
//
// Implemented CSRs
//   0x300 mstatus   MIE (bit 3), MPIE (bit 7); MPP (bits 12:11) always 11 = M-mode
//   0x301 misa      read-only value: RV32 + I + M
//   0x304 mie       stored, not used yet (no interrupts yet)
//   0x305 mtvec     trap handler address (direct mode only, low 2 bits = 0)
//   0x340 mscratch  free register for the trap handler
//   0x341 mepc      address of the instruction that trapped
//   0x342 mcause    why we trapped
//   0x343 mtval     extra info: bad address or bad instruction bits
//   0x344 mip       reads 0 (no interrupts yet)
//   0xB00/0xB80 mcycle(h)   0xB02/0xB82 minstret(h)     64-bit counters, writable
//   0xC00/0xC80 cycle(h)    0xC02/0xC82 instret(h)      read-only copies
//   0xF11-0xF14 mvendorid, marchid, mimpid, mhartid    read 0
// Any other address -> illegal instruction. Writing a read-only CSR -> illegal.
//
// 🔗 HOLY CORE also has a csr_file.sv (2_soc_software_edition/src/); this one is
//    written from the RISC-V privileged spec, keeping only what we need.
// =============================================================================
module csr_file
  import core_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        advance,       // pipeline moves at this edge -> commit updates

  // ---- CSR instruction currently in EX ----
  input  logic        csr_access,    // valid csr* instruction in EX
  input  logic [11:0] csr_addr,
  input  logic [2:0]  csr_op,        // funct3
  input  logic [31:0] csr_src,       // rs1 value, or zimm for the *i forms
  input  logic [4:0]  csr_rs1_field, // rs1 index / zimm; 0 means "no write" for set/clear
  output logic [31:0] csr_rdata,     // old value -> rd
  output logic        csr_illegal,

  // ---- traps and mret (decided in EX) ----
  input  logic        trap,
  input  logic [31:0] trap_cause,
  input  logic [31:0] trap_pc,
  input  logic [31:0] trap_tval,
  input  logic        mret,

  // ---- counting ----
  input  logic        retire,        // one instruction completed this cycle

  output logic [31:0] mtvec,
  output logic [31:0] mepc
);

  localparam logic [31:0] MISA_VALUE = 32'h4000_1100; // MXL=1 (32-bit), bits I(8) and M(12)

  logic        mstatus_mie, mstatus_mpie;
  logic [31:0] mie_q, mscratch, mcause, mtval;
  logic [63:0] mcycle, minstret;

  logic        csr_exists, csr_readonly, csr_writes;
  logic [31:0] old_value, new_value;

  // ---- does this CSR instruction actually write? ----
  // csrrw/csrrwi always write. csrrs/csrrc(i) only write when rs1/zimm != 0.
  assign csr_writes   = (csr_op[1:0] == 2'b01) || (csr_rs1_field != 5'd0);
  assign csr_readonly = (csr_addr[11:10] == 2'b11);   // RISC-V rule: top bits 11 = read-only

  // ---- read mux ----
  always_comb begin
    csr_exists = 1'b1;
    old_value  = 32'd0;
    unique case (csr_addr)
      12'h300: old_value = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
      12'h301: old_value = MISA_VALUE;
      12'h304: old_value = mie_q;
      12'h305: old_value = mtvec;
      12'h340: old_value = mscratch;
      12'h341: old_value = mepc;
      12'h342: old_value = mcause;
      12'h343: old_value = mtval;
      12'h344: old_value = 32'd0;
      12'hB00, 12'hC00: old_value = mcycle[31:0];
      12'hB80, 12'hC80: old_value = mcycle[63:32];
      12'hB02, 12'hC02: old_value = minstret[31:0];
      12'hB82, 12'hC82: old_value = minstret[63:32];
      12'hF11, 12'hF12, 12'hF13, 12'hF14: old_value = 32'd0;
      default: csr_exists = 1'b0;
    endcase
  end

  assign csr_rdata   = old_value;
  assign csr_illegal = csr_access && (!csr_exists || (csr_writes && csr_readonly));

  // ---- new value for csrrw / csrrs / csrrc ----
  always_comb begin
    unique case (csr_op[1:0])
      2'b01:   new_value = csr_src;                 // write
      2'b10:   new_value = old_value |  csr_src;    // set bits
      2'b11:   new_value = old_value & ~csr_src;    // clear bits
      default: new_value = old_value;
    endcase
  end

  // ---- state updates ----
  logic do_write;
  assign do_write = advance && csr_access && csr_writes && !csr_illegal && !trap;

  always_ff @(posedge clk) begin
    if (rst) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_q        <= 32'd0;
      mtvec        <= 32'd0;
      mscratch     <= 32'd0;
      mepc         <= 32'd0;
      mcause       <= 32'd0;
      mtval        <= 32'd0;
      mcycle       <= 64'd0;
      minstret     <= 64'd0;
    end else begin
      // counters tick on their own; a CSR write below overrides them
      mcycle   <= mcycle + 64'd1;
      minstret <= minstret + {63'd0, retire};

      if (advance && trap) begin
        mepc         <= {trap_pc[31:2], 2'b00};
        mcause       <= trap_cause;
        mtval        <= trap_tval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
      end else if (advance && mret) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end else if (do_write) begin
        unique case (csr_addr)
          12'h300: begin mstatus_mie <= new_value[3]; mstatus_mpie <= new_value[7]; end
          12'h304: mie_q            <= new_value & 32'h0000_0888;
          12'h305: mtvec            <= {new_value[31:2], 2'b00};
          12'h340: mscratch         <= new_value;
          12'h341: mepc             <= {new_value[31:2], 2'b00};
          12'h342: mcause           <= new_value;
          12'h343: mtval            <= new_value;
          12'hB00: mcycle[31:0]     <= new_value;
          12'hB80: mcycle[63:32]    <= new_value;
          12'hB02: minstret[31:0]   <= new_value;
          12'hB82: minstret[63:32]  <= new_value;
          default: ;                                   // misa etc.: writes ignored
        endcase
      end
    end
  end

endmodule

// =============================================================================
// decoder.sv - turns a 32-bit instruction into control signals (ID stage)
//
// Supported: RV32I + M (mul/div) + Zicsr (csr*) + Zifencei (fence.i)
//            + ecall, ebreak, mret, wfi (treated as nop).
// Anything else sets `illegal`, which makes the EX stage take an
// illegal-instruction trap (mcause = 2).
//
// Instruction field reminder:
//   [31:25] funct7  [24:20] rs2  [19:15] rs1  [14:12] funct3  [11:7] rd  [6:0] opcode
// =============================================================================
module decoder
  import core_pkg::*;
(
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);

  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [6:0]  funct7;
  imm_type_t   imm_type;
  logic [31:0] imm;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];

  imm_gen u_imm_gen (
    .instr    (instr),
    .imm_type (imm_type),
    .imm      (imm)
  );

  // Which immediate format? Depends only on the opcode.
  // (Kept in its own block so the tools see no false combinational loop.)
  always_comb begin
    unique case (opcode)
      OP_LUI, OP_AUIPC: imm_type = IMM_U;
      OP_JAL:           imm_type = IMM_J;
      OP_BRANCH:        imm_type = IMM_B;
      OP_STORE:         imm_type = IMM_S;
      OP_SYSTEM:        imm_type = IMM_Z;   // csr*i immediate forms
      default:          imm_type = IMM_I;   // op-imm, loads, jalr
    endcase
  end

  always_comb begin
    // ---- defaults: a harmless "do nothing" instruction ----
    ctrl           = '0;
    ctrl.rd        = instr[11:7];
    ctrl.rs1       = instr[19:15];
    ctrl.rs2       = instr[24:20];
    ctrl.funct3    = funct3;
    ctrl.src_a     = SRC_A_RS1;
    ctrl.alu_op    = ALU_ADD;

    unique case (opcode)
      // ---------------------------------------------------------------- LUI
      OP_LUI: begin
        ctrl.reg_write = 1'b1;
        ctrl.src_a     = SRC_A_ZERO;   // 0 + imm
        ctrl.src_b_imm = 1'b1;
      end
      // -------------------------------------------------------------- AUIPC
      OP_AUIPC: begin
        ctrl.reg_write = 1'b1;
        ctrl.src_a     = SRC_A_PC;     // pc + imm
        ctrl.src_b_imm = 1'b1;
      end
      // ---------------------------------------------------------------- JAL
      OP_JAL: begin
        ctrl.reg_write = 1'b1;         // rd = pc + 4
        ctrl.is_jal    = 1'b1;
      end
      // --------------------------------------------------------------- JALR
      OP_JALR: begin
        ctrl.reg_write = 1'b1;
        ctrl.is_jalr   = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        if (funct3 != 3'b000) ctrl.illegal = 1'b1;
      end
      // ------------------------------------------------------------- BRANCH
      OP_BRANCH: begin
        ctrl.is_branch = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.uses_rs2  = 1'b1;
        if (funct3 == 3'b010 || funct3 == 3'b011) ctrl.illegal = 1'b1;
      end
      // --------------------------------------------------------------- LOAD
      OP_LOAD: begin
        ctrl.reg_write = 1'b1;
        ctrl.is_load   = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.src_b_imm = 1'b1;         // address = rs1 + imm
        if (!(funct3 inside {F3_B, F3_H, F3_W, F3_BU, F3_HU})) ctrl.illegal = 1'b1;
      end
      // -------------------------------------------------------------- STORE
      OP_STORE: begin
        ctrl.is_store  = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.uses_rs2  = 1'b1;         // the data to store
        ctrl.src_b_imm = 1'b1;
        if (!(funct3 inside {F3_B, F3_H, F3_W})) ctrl.illegal = 1'b1;
      end
      // ------------------------------------------------ OP-IMM (addi, ...)
      OP_IMM: begin
        ctrl.reg_write = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.src_b_imm = 1'b1;
        unique case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;
          3'b010: ctrl.alu_op = ALU_SLT;
          3'b011: ctrl.alu_op = ALU_SLTU;
          3'b100: ctrl.alu_op = ALU_XOR;
          3'b110: ctrl.alu_op = ALU_OR;
          3'b111: ctrl.alu_op = ALU_AND;
          3'b001: begin                           // slli
            ctrl.alu_op = ALU_SLL;
            if (funct7 != 7'b0000000) ctrl.illegal = 1'b1;
          end
          3'b101: begin                           // srli / srai
            if      (funct7 == 7'b0000000) ctrl.alu_op = ALU_SRL;
            else if (funct7 == 7'b0100000) ctrl.alu_op = ALU_SRA;
            else                           ctrl.illegal = 1'b1;
          end
          default: ctrl.illegal = 1'b1;
        endcase
      end
      // ---------------------------------------------- OP (add, ..., mul, div)
      OP_REG: begin
        ctrl.reg_write = 1'b1;
        ctrl.uses_rs1  = 1'b1;
        ctrl.uses_rs2  = 1'b1;
        if (funct7 == 7'b0000001) begin
          ctrl.is_muldiv = 1'b1;                  // M extension, funct3 = operation
        end else if (funct7 == 7'b0000000) begin
          unique case (funct3)
            3'b000: ctrl.alu_op = ALU_ADD;
            3'b001: ctrl.alu_op = ALU_SLL;
            3'b010: ctrl.alu_op = ALU_SLT;
            3'b011: ctrl.alu_op = ALU_SLTU;
            3'b100: ctrl.alu_op = ALU_XOR;
            3'b101: ctrl.alu_op = ALU_SRL;
            3'b110: ctrl.alu_op = ALU_OR;
            3'b111: ctrl.alu_op = ALU_AND;
            default: ;
          endcase
        end else if (funct7 == 7'b0100000 && funct3 == 3'b000) begin
          ctrl.alu_op = ALU_SUB;
        end else if (funct7 == 7'b0100000 && funct3 == 3'b101) begin
          ctrl.alu_op = ALU_SRA;
        end else begin
          ctrl.illegal = 1'b1;
        end
      end
      // -------------------------------------------------- FENCE / FENCE.I
      OP_FENCE: begin
        // fence   : our core is in-order with one memory port -> nothing to do
        // fence.i : caches must be synchronised, then refetch (handled in EX)
        if      (funct3 == 3'b000) ;
        else if (funct3 == 3'b001) ctrl.is_fencei = 1'b1;
        else                       ctrl.illegal   = 1'b1;
      end
      // ----------------------------------------------------------- SYSTEM
      OP_SYSTEM: begin
        if (funct3 == 3'b000) begin
          // ecall / ebreak / mret / wfi need rd = 0 and rs1 = 0
          if (instr[19:15] != 5'd0 || instr[11:7] != 5'd0) ctrl.illegal = 1'b1;
          else begin
            unique case (instr[31:20])
              12'h000: ctrl.is_ecall  = 1'b1;
              12'h001: ctrl.is_ebreak = 1'b1;
              12'h302: ctrl.is_mret   = 1'b1;
              12'h105: ;                          // wfi: allowed to act as a nop
              default: ctrl.illegal   = 1'b1;
            endcase
          end
        end else if (funct3 == 3'b100) begin
          ctrl.illegal = 1'b1;
        end else begin
          // csrrw / csrrs / csrrc / csrrwi / csrrsi / csrrci
          ctrl.is_csr    = 1'b1;
          ctrl.reg_write = 1'b1;                  // rd = old CSR value
          ctrl.uses_rs1  = ~funct3[2];            // register forms read rs1, *i forms use zimm
        end
      end
      default: ctrl.illegal = 1'b1;
    endcase

    // Only 32-bit instructions exist on this core (no "C" compressed extension)
    if (instr[1:0] != 2'b11) ctrl.illegal = 1'b1;

    ctrl.imm = imm;

    // Writing x0 does nothing, so pretend there is no write at all.
    // (This keeps the forwarding and stall logic simple.)
    if (ctrl.rd == 5'd0) ctrl.reg_write = 1'b0;

    // An illegal instruction must have no side effects at all.
    if (ctrl.illegal) begin
      ctrl.reg_write = 1'b0;
      ctrl.is_branch = 1'b0;
      ctrl.is_jal    = 1'b0;
      ctrl.is_jalr   = 1'b0;
      ctrl.is_load   = 1'b0;
      ctrl.is_store  = 1'b0;
      ctrl.is_muldiv = 1'b0;
      ctrl.is_csr    = 1'b0;
      ctrl.is_ecall  = 1'b0;
      ctrl.is_ebreak = 1'b0;
      ctrl.is_mret   = 1'b0;
      ctrl.is_fencei = 1'b0;
    end
  end

endmodule

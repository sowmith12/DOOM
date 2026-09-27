// =============================================================================
// core_pkg.sv - shared definitions for the CPU core
//
// Everything that more than one core file needs lives here: RISC-V opcodes,
// the ALU operation list, the "control bundle" the decoder produces, and the
// four pipeline-register bundles (IF/ID, ID/EX, EX/MEM, MEM/WB).
//
// Beginner note: a "package" is just a named box of constants and types.
// Other files use it with   import core_pkg::*;
// =============================================================================
package core_pkg;

  // ---------------------------------------------------------------------------
  // RISC-V major opcodes (instruction bits [6:0])
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;  // addi, slti, xori, slli ...
  localparam logic [6:0] OP_REG    = 7'b0110011;  // add, sub, ..., mul, div ...
  localparam logic [6:0] OP_FENCE  = 7'b0001111;  // fence, fence.i
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;  // ecall, ebreak, mret, csr*

  // ---------------------------------------------------------------------------
  // funct3 values we refer to by name
  // ---------------------------------------------------------------------------
  // loads / stores (the funct3 field says the size)
  localparam logic [2:0] F3_B  = 3'b000;  // lb  / sb
  localparam logic [2:0] F3_H  = 3'b001;  // lh  / sh
  localparam logic [2:0] F3_W  = 3'b010;  // lw  / sw
  localparam logic [2:0] F3_BU = 3'b100;  // lbu
  localparam logic [2:0] F3_HU = 3'b101;  // lhu

  // M extension (funct7 = 0000001 on OP_REG)
  localparam logic [2:0] F3_MUL    = 3'b000;
  localparam logic [2:0] F3_MULH   = 3'b001;
  localparam logic [2:0] F3_MULHSU = 3'b010;
  localparam logic [2:0] F3_MULHU  = 3'b011;
  localparam logic [2:0] F3_DIV    = 3'b100;
  localparam logic [2:0] F3_DIVU   = 3'b101;
  localparam logic [2:0] F3_REM    = 3'b110;
  localparam logic [2:0] F3_REMU   = 3'b111;

  // CSR instructions (funct3 on OP_SYSTEM). Bit 2 set = "immediate" form.
  localparam logic [2:0] F3_CSRRW  = 3'b001;
  localparam logic [2:0] F3_CSRRS  = 3'b010;
  localparam logic [2:0] F3_CSRRC  = 3'b011;

  // ---------------------------------------------------------------------------
  // mcause exception codes (RISC-V privileged spec, table "mcause values")
  // ---------------------------------------------------------------------------
  localparam logic [31:0] EXC_INSTR_MISALIGNED = 32'd0;
  localparam logic [31:0] EXC_ILLEGAL_INSTR    = 32'd2;
  localparam logic [31:0] EXC_BREAKPOINT       = 32'd3;
  localparam logic [31:0] EXC_LOAD_MISALIGNED  = 32'd4;
  localparam logic [31:0] EXC_STORE_MISALIGNED = 32'd6;
  localparam logic [31:0] EXC_ECALL_M          = 32'd11;

  // ---------------------------------------------------------------------------
  // ALU operations
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLL,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_SRL,
    ALU_SRA,
    ALU_OR,
    ALU_AND
  } alu_op_t;

  // Where the ALU's first operand (A) comes from
  typedef enum logic [1:0] {
    SRC_A_RS1,   // register rs1 (most instructions)
    SRC_A_PC,    // the instruction's own address (auipc)
    SRC_A_ZERO   // constant 0 (lui: 0 + imm)
  } src_a_t;

  // Which immediate format the instruction uses
  typedef enum logic [2:0] {
    IMM_I,  // addi, loads, jalr
    IMM_S,  // stores
    IMM_B,  // branches
    IMM_U,  // lui, auipc
    IMM_J,  // jal
    IMM_Z   // CSR immediate forms: 5-bit zero-extended value in the rs1 field
  } imm_type_t;

  // ---------------------------------------------------------------------------
  // Control bundle: everything the decoder figured out about one instruction.
  // It travels down the pipeline inside ID/EX.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        illegal;     // not an instruction we implement -> trap
    logic        reg_write;   // writes register rd (already forced 0 when rd == x0)
    logic [4:0]  rd;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic        uses_rs1;    // really reads rs1 (used to avoid false stalls)
    logic        uses_rs2;    // really reads rs2
    src_a_t      src_a;
    logic        src_b_imm;   // ALU B operand = immediate (else rs2)
    alu_op_t     alu_op;
    logic [2:0]  funct3;      // branch condition / memory size / mul-div op / csr op
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_load;
    logic        is_store;
    logic        is_muldiv;
    logic        is_csr;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        is_fencei;
    logic [31:0] imm;
  } ctrl_t;

  // ---------------------------------------------------------------------------
  // Pipeline registers. "valid = 0" means the slot holds a bubble (no-op).
  // pc and instr are carried to the end for traps and the retire trace.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
  } if_id_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    ctrl_t       ctrl;
    logic [31:0] rs1_val;     // register values read in ID (may be stale -> forwarding fixes)
    logic [31:0] rs2_val;
  } id_ex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        reg_write;
    logic [4:0]  rd;
    logic        is_load;
    logic [2:0]  funct3;      // load size / signedness
    logic [1:0]  addr_lo;     // low address bits, to pick the right byte/half
    logic [31:0] result;      // ALU / PC+4 / CSR / mul-div result (not for loads)
  } ex_mem_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        reg_write;
    logic [4:0]  rd;
    logic [31:0] wb_data;     // final value written to rd
  } mem_wb_t;

endpackage

// =============================================================================
// muldiv.sv - RISC-V "M" extension (EX stage)
//
// MULTIPLY (mul, mulh, mulhsu, mulhu)
//   One 33x33-bit signed multiply, done in a single cycle. Vivado maps it to
//   DSP48 blocks. The extra 33rd bit lets one multiplier handle signed AND
//   unsigned operands: we extend with the sign bit (signed) or 0 (unsigned).
//
// DIVIDE (div, divu, rem, remu)
//   Iterative "shift-and-subtract" division, 1 quotient bit per clock:
//   IDLE --start--> RUN (32 cycles) --> DONE --pipeline moves on--> IDLE
//   While a division is not DONE, `busy` = 1 and the whole pipeline waits.
//   Signed division works on absolute values, then fixes the signs.
//
//   Special cases required by the RISC-V spec (no traps on divide):
//     x / 0        -> quotient = all ones (-1),  remainder = x
//     -2^31 / -1   -> quotient = -2^31,          remainder = 0
//                     (falls out naturally from the absolute-value method)
// =============================================================================
module muldiv
  import core_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  input  logic        valid,     // a mul/div instruction is in EX
  input  logic [2:0]  op,        // funct3
  input  logic [31:0] a,         // rs1
  input  logic [31:0] b,         // rs2
  input  logic        advance,   // 1 = pipeline moves forward at this clock edge

  output logic [31:0] result,
  output logic        busy
);

  // ------------------------------------------------------------------ multiply
  logic               a_signed, b_signed;
  logic signed [32:0] mul_a, mul_b;
  logic signed [65:0] product;
  logic [31:0]        mul_result;

  assign a_signed   = (op == F3_MULH) || (op == F3_MULHSU);
  assign b_signed   = (op == F3_MULH);
  assign mul_a      = {a_signed & a[31], a};
  assign mul_b      = {b_signed & b[31], b};
  assign product    = mul_a * mul_b;
  assign mul_result = (op == F3_MUL) ? product[31:0] : product[63:32];

  // ------------------------------------------------------------------ divide
  typedef enum logic [1:0] {DIV_IDLE, DIV_RUN, DIV_DONE} div_state_t;

  div_state_t  state;
  logic        is_div;
  logic        div_signed;
  logic [31:0] quo;          // shifts the dividend out and quotient bits in
  logic [32:0] rem;          // partial remainder (1 extra bit for the compare)
  logic [31:0] divisor;
  logic [5:0]  count;
  logic        neg_quo, neg_rem, div_by_zero;
  logic [31:0] dividend_saved;
  logic [32:0] rem_shifted;
  logic [31:0] quo_final, rem_final;

  assign is_div     = valid && op[2];     // funct3 1xx = div/divu/rem/remu
  assign div_signed = ~op[0];             // div (100) and rem (110) are signed
  assign busy       = is_div && (state != DIV_DONE);

  assign rem_shifted = {rem[31:0], quo[31]};

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= DIV_IDLE;
    end else begin
      unique case (state)
        DIV_IDLE: if (is_div) begin
          quo            <= (div_signed && a[31]) ? -a : a;
          divisor        <= (div_signed && b[31]) ? -b : b;
          rem            <= 33'd0;
          count          <= 6'd32;
          neg_quo        <= div_signed && (a[31] ^ b[31]);
          neg_rem        <= div_signed && a[31];
          div_by_zero    <= (b == 32'd0);
          dividend_saved <= a;
          state          <= DIV_RUN;
        end
        DIV_RUN: begin
          if (rem_shifted >= {1'b0, divisor}) begin
            rem <= rem_shifted - {1'b0, divisor};
            quo <= {quo[30:0], 1'b1};
          end else begin
            rem <= rem_shifted;
            quo <= {quo[30:0], 1'b0};
          end
          count <= count - 6'd1;
          if (count == 6'd1) state <= DIV_DONE;
        end
        DIV_DONE: if (advance) state <= DIV_IDLE;   // result was consumed
        default:  state <= DIV_IDLE;
      endcase
    end
  end

  assign quo_final = div_by_zero ? 32'hFFFF_FFFF    : (neg_quo ? -quo       : quo);
  assign rem_final = div_by_zero ? dividend_saved   : (neg_rem ? -rem[31:0] : rem[31:0]);

  // funct3: 0xx = multiply, 10x = div/divu, 11x = rem/remu
  assign result = !op[2] ? mul_result
                : (op[1] ? rem_final : quo_final);

endmodule

// =============================================================================
// store_align.sv - prepares a store for a 32-bit-wide memory (EX stage)
//
// Memory is organised in 32-bit words. To store a byte or half-word we:
//   * copy the data into every lane it could go to  (wdata)
//   * enable only the byte lanes that should change (wstrb, 1 bit per byte)
//   * check alignment: sh needs addr[0]=0, sw needs addr[1:0]=0
//
//   example: sb to address ...2  -> wdata = {b,b,b,b}, wstrb = 4'b0100
// =============================================================================
module store_align
  import core_pkg::*;
(
  input  logic [2:0]  funct3,      // F3_B / F3_H / F3_W
  input  logic [1:0]  addr_lo,     // address bits [1:0]
  input  logic [31:0] data,        // rs2 value
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        misaligned
);

  always_comb begin
    wdata      = data;
    wstrb      = 4'b0000;
    misaligned = 1'b0;
    unique case (funct3)
      F3_B: begin
        wdata = {4{data[7:0]}};
        wstrb = 4'b0001 << addr_lo;
      end
      F3_H: begin
        wdata      = {2{data[15:0]}};
        wstrb      = addr_lo[1] ? 4'b1100 : 4'b0011;
        misaligned = addr_lo[0];
      end
      F3_W: begin
        wdata      = data;
        wstrb      = 4'b1111;
        misaligned = (addr_lo != 2'b00);
      end
      default: ;
    endcase
  end

endmodule

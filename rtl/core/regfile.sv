// =============================================================================
// regfile.sv - the 32 general-purpose registers x0..x31
//
// * 2 read ports (rs1, rs2), read combinationally in the ID stage.
// * 1 write port, written at the clock edge by the WB stage.
// * x0 always reads as 0 and ignores writes.
// * Write-through bypass: if WB writes a register in the same cycle that ID
//   reads it, ID gets the NEW value. This removes one forwarding case.
//
// No reset on purpose: so Vivado can map it to small LUT-RAMs.
// =============================================================================
module regfile (
  input  logic        clk,

  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2,

  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata
);

  logic [31:0] regs [32];

  always_ff @(posedge clk) begin
    if (we && waddr != 5'd0) regs[waddr] <= wdata;
  end

  always_comb begin
    if (raddr1 == 5'd0)                  rdata1 = 32'd0;
    else if (we && waddr == raddr1)      rdata1 = wdata;
    else                                 rdata1 = regs[raddr1];

    if (raddr2 == 5'd0)                  rdata2 = 32'd0;
    else if (we && waddr == raddr2)      rdata2 = wdata;
    else                                 rdata2 = regs[raddr2];
  end

endmodule

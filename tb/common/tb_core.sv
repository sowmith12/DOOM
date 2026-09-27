// =============================================================================
// tb_core.sv - simulation top: core + sim_mem
//
// cocotb (Python) drives clk and rst and watches tohost_valid.
// With plusarg +trace, every retired instruction is printed:
//   <pc> <instruction> x<rd> = <value>
// which can be compared line by line against the Spike reference simulator.
// =============================================================================
module tb_core (
  input  logic        clk,
  input  logic        rst,
  output logic        tohost_valid,
  output logic [31:0] tohost_value,
  output logic [63:0] retired_count
);

  logic        imem_req, imem_hold, imem_busy;
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_req, dmem_we, dmem_hold, dmem_busy;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        fencei_req;
  logic        retire_valid, retire_we;
  logic [31:0] retire_pc, retire_instr, retire_wdata;
  logic [4:0]  retire_rd;

  core u_core (
    .clk          (clk),
    .rst          (rst),
    .imem_req     (imem_req),
    .imem_addr    (imem_addr),
    .imem_hold    (imem_hold),
    .imem_rdata   (imem_rdata),
    .imem_busy    (imem_busy),
    .dmem_req     (dmem_req),
    .dmem_we      (dmem_we),
    .dmem_addr    (dmem_addr),
    .dmem_wdata   (dmem_wdata),
    .dmem_wstrb   (dmem_wstrb),
    .dmem_hold    (dmem_hold),
    .dmem_rdata   (dmem_rdata),
    .dmem_busy    (dmem_busy),
    .fencei_req   (fencei_req),
    .fencei_busy  (1'b0),          // no caches yet: memory is always coherent
    .retire_valid (retire_valid),
    .retire_pc    (retire_pc),
    .retire_instr (retire_instr),
    .retire_we    (retire_we),
    .retire_rd    (retire_rd),
    .retire_wdata (retire_wdata)
  );

  sim_mem u_mem (
    .clk          (clk),
    .rst          (rst),
    .i_req        (imem_req),
    .i_addr       (imem_addr),
    .i_hold       (imem_hold),
    .i_rdata      (imem_rdata),
    .i_busy       (imem_busy),
    .d_req        (dmem_req),
    .d_we         (dmem_we),
    .d_addr       (dmem_addr),
    .d_wdata      (dmem_wdata),
    .d_wstrb      (dmem_wstrb),
    .d_hold       (dmem_hold),
    .d_rdata      (dmem_rdata),
    .d_busy       (dmem_busy),
    .tohost_valid (tohost_valid),
    .tohost_value (tohost_value)
  );

  // ---- retire counter + optional trace ----
  logic trace_on;
  initial trace_on = $test$plusargs("trace");

  always_ff @(posedge clk) begin
    if (rst) retired_count <= 64'd0;
    else if (retire_valid) begin
      retired_count <= retired_count + 64'd1;
      if (trace_on) begin
        if (retire_we) $display("TRACE %08h %08h x%0d=%08h", retire_pc, retire_instr, retire_rd, retire_wdata);
        else           $display("TRACE %08h %08h", retire_pc, retire_instr);
      end
    end
  end

endmodule

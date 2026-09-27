// =============================================================================
// sim_mem.sv - SIMULATION-ONLY memory with two ports (instruction + data)
//
// Speaks exactly the core's memory protocol (see core.sv header):
//   request accepted at a clock edge when hold = 0,
//   answer in the next cycle, possibly after some random "busy" cycles.
//
// The random delays imitate cache misses, so the pipeline's stall logic is
// tested long before real caches exist. Set with plusarg  +stall_pct=N
// (0 = ideal memory, 30 = 30% of requests wait 1..8 extra cycles).
//
// Special addresses on the DATA port (not real memory):
//   0xF000_0000  TOHOST : test result. 1 = pass, (n<<1)|1 = test n failed
//   0xF000_0004  PUTC   : writes one character to the simulator console
//   0xF000_0008  EPC    : trap handler of the tests writes mepc here (for debug)
//
// Program image: +hex=<file>, one 32-bit little-endian word per line
// (made by tools/bin2hex.py), loaded at address 0.
// =============================================================================
module sim_mem #(
  parameter int SIZE_BYTES = 1 << 20          // 1 MB
)(
  input  logic        clk,
  input  logic        rst,

  // instruction port
  input  logic        i_req,
  input  logic [31:0] i_addr,
  input  logic        i_hold,
  output logic [31:0] i_rdata,
  output logic        i_busy,

  // data port
  input  logic        d_req,
  input  logic        d_we,
  input  logic [31:0] d_addr,
  input  logic [31:0] d_wdata,
  input  logic [3:0]  d_wstrb,
  input  logic        d_hold,
  output logic [31:0] d_rdata,
  output logic        d_busy,

  // test result
  output logic        tohost_valid,
  output logic [31:0] tohost_value
);

  localparam int WORDS = SIZE_BYTES / 4;
  localparam int AW    = $clog2(WORDS);

  localparam logic [31:0] ADDR_TOHOST = 32'hF000_0000;
  localparam logic [31:0] ADDR_PUTC   = 32'hF000_0004;
  localparam logic [31:0] ADDR_EPC    = 32'hF000_0008;

  logic [31:0] mem [WORDS];

  int unsigned stall_pct;
  string       hexfile;

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0000;
    if (!$value$plusargs("stall_pct=%d", stall_pct)) stall_pct = 0;
    if ($value$plusargs("hex=%s", hexfile)) begin
      $readmemh(hexfile, mem);
      $display("[sim_mem] loaded %s, random stall = %0d%%", hexfile, stall_pct);
    end else begin
      $display("[sim_mem] WARNING: no +hex=<file> given, memory is empty");
    end
  end

  function automatic int unsigned pick_delay();
    if (stall_pct != 0 && ($urandom % 100) < stall_pct) return 1 + ($urandom % 8);
    return 0;
  endfunction

  function automatic logic [AW-1:0] widx(input logic [31:0] a);
    return a[AW+1:2];
  endfunction

  // ------------------------------------------------------------------ I port
  int unsigned i_wait;
  always_ff @(posedge clk) begin
    if (rst) begin
      i_wait  <= 0;
      i_rdata <= 32'h0000_0013;         // nop
    end else if (!i_hold) begin
      if (i_req) begin
        i_rdata <= mem[widx(i_addr)];
        i_wait  <= pick_delay();
      end else begin
        i_wait  <= 0;
      end
    end else if (i_wait != 0) begin
      i_wait <= i_wait - 1;
    end
  end
  assign i_busy = (i_wait != 0);

  // ------------------------------------------------------------------ D port
  int unsigned d_wait;
  always_ff @(posedge clk) begin
    if (rst) begin
      d_wait       <= 0;
      d_rdata      <= 32'd0;
      tohost_valid <= 1'b0;
      tohost_value <= 32'd0;
    end else if (!d_hold) begin
      if (d_req) begin
        d_wait <= pick_delay();
        if (d_we) begin
          if (d_addr == ADDR_TOHOST) begin
            tohost_valid <= 1'b1;
            tohost_value <= d_wdata;
          end else if (d_addr == ADDR_PUTC) begin
            $write("%c", d_wdata[7:0]);
          end else if (d_addr == ADDR_EPC) begin
            $display("[sim_mem] trap handler reports mepc = 0x%08h", d_wdata);
          end else begin
            for (int b = 0; b < 4; b++)
              if (d_wstrb[b]) mem[widx(d_addr)][8*b +: 8] <= d_wdata[8*b +: 8];
          end
        end else begin
          d_rdata <= mem[widx(d_addr)];
        end
      end else begin
        d_wait <= 0;
      end
    end else if (d_wait != 0) begin
      d_wait <= d_wait - 1;
    end
  end
  assign d_busy = (d_wait != 0);

endmodule

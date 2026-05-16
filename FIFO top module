// =============================================================
// Module : FIFO
// Depth  : 16 entries  |  Width : 8 bits
// Type   : Synchronous, single-clock
// Notes  : Simultaneous wr+rd not supported — write takes priority
// =============================================================
module FIFO (
  input            clk,   // Clock — all logic triggers on rising edge
  input            rst,   // Synchronous active-high reset
  input            wr,    // Write enable — push din into FIFO
  input            rd,    // Read enable  — pop data onto dout
  input      [7:0] din,   // 8-bit data input (write side)
  output reg [7:0] dout,  // 8-bit data output (read side)
  output           empty, // High when FIFO holds 0 entries
  output           full   // High when FIFO holds 16 entries
);

  // ------------------------------------------------------------------
  // Internal pointers — 4-bit so they naturally wrap 15 → 0,
  // giving circular-buffer behavior with no extra logic needed
  // ------------------------------------------------------------------
  reg [3:0] wptr = 0;  // Points to next slot to be written
  reg [3:0] rptr = 0;  // Points to next slot to be read

  // ------------------------------------------------------------------
  // Entry counter — needs 5 bits to hold values 0 through 16
  // (16 does not fit in 4 bits)
  // ------------------------------------------------------------------
  reg [4:0] cnt = 0;

  // ------------------------------------------------------------------
  // Storage array — 16 slots, each 8 bits wide
  // ------------------------------------------------------------------
  reg [7:0] mem [15:0];

  // ------------------------------------------------------------------
  // Synchronous control block
  // All three operations (reset / write / read) are mutually exclusive.
  // Priority order: reset > write > read
  // ------------------------------------------------------------------
  always @(posedge clk) begin

    if (rst) begin
      // --- RESET ---------------------------------------------------
      // Return both pointers and the counter to zero.
      // Memory contents are irrelevant; cnt == 0 makes empty go high,
      // so stale mem values can never be read out.
      wptr <= 0;
      rptr <= 0;
      cnt  <= 0;
    end

    else if (wr && !full) begin
      // --- WRITE ---------------------------------------------------
      // Accepted only when FIFO is not full.
      // 1. Store incoming byte at the current write slot.
      // 2. Advance wptr (wraps automatically via 4-bit overflow).
      // 3. Increment the entry counter.
      mem[wptr] <= din;
      wptr      <= wptr + 1;
      cnt       <= cnt + 1;
    end

    else if (rd && !empty) begin
      // --- READ ----------------------------------------------------
      // Accepted only when FIFO is not empty.
      // 1. Place the oldest byte onto dout.
      // 2. Advance rptr (wraps automatically via 4-bit overflow).
      // 3. Decrement the entry counter.
      dout <= mem[rptr];
      rptr <= rptr + 1;
      cnt  <= cnt - 1;
    end

  end

  // ------------------------------------------------------------------
  // Status flags — combinational, update immediately when cnt changes
  // (no one-cycle lag, unlike if they were registered)
  // ------------------------------------------------------------------
  assign empty = (cnt == 0)  ? 1'b1 : 1'b0;  // No entries left to read
  assign full  = (cnt == 16) ? 1'b1 : 1'b0;  // All 16 slots occupied

endmodule


// =============================================================
// Interface : fifo_if
// Bundles every FIFO signal into one named handle so the DUT
// port list and testbench connections stay in sync automatically
// =============================================================
interface fifo_if;

  logic        clock;     // Drives clk on the DUT
  logic        rst;       // Synchronous active-high reset
  logic        wr;        // Write-enable driven by the driver
  logic        rd;        // Read-enable driven by the driver
  logic        full;      // Status flag driven by the DUT
  logic        empty;     // Status flag driven by the DUT
  logic [7:0]  data_in;   // Payload written into the FIFO
  logic [7:0]  data_out;  // Payload read out of the FIFO

endinterface

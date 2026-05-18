// ============================================================
// MODULE: dff
// Implements a D Flip-Flop (DFF) — a 1-bit memory element.
// It receives all its signals through the interface 'vif'
// instead of individual ports.
// ============================================================
module dff (dff_if vif);

  // ----------------------------------------------------------
  // This always block runs on every rising edge of the clock
  // (when clk goes from 0 → 1). This is what makes it a
  // synchronous (clock-driven) flip-flop.
  // ----------------------------------------------------------
  always @(posedge vif.clk)
    begin
      // ------------------------------------------------------
      // RESET CONDITION (active-high)
      // If rst = 1, ignore din and force dout to 0.
      // This puts the flip-flop in a known state at startup
      // or whenever we want to clear it.
      // ------------------------------------------------------
      if (vif.rst == 1'b1)
        // '<=' is non-blocking assignment — always use this
        // inside clocked always blocks to avoid race conditions
        vif.dout <= 1'b0;
      else
        // ------------------------------------------------------
        // NORMAL OPERATION
        // rst = 0, so capture din and store it into dout.
        // This stored value holds until the next rising edge.
        // ------------------------------------------------------
        vif.dout <= vif.din;
    end
  
endmodule


// ============================================================
// INTERFACE: dff_if
// An interface bundles all related signals into one unit.
// Both the DUT (dff module) and the testbench connect through
// this interface instead of wiring signals one by one.
// ============================================================
interface dff_if;
  logic clk;   // Clock  — triggers the flip-flop on every 0→1 rise
  logic rst;   // Reset  — when 1, forces dout to 0 (active-high reset)
  logic din;   // Data Input  — value to be captured on the next clock edge
  logic dout;  // Data Output — value currently stored in the flip-flop
  
endinterface

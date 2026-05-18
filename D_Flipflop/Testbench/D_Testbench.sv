// ============================================================
// CLASS: transaction
// A transaction is a data object that holds one set of
// stimulus (din) and response (dout) values.
// The generator creates these and passes them around.
// ============================================================
class transaction;
  rand bit din;  // 'rand' means din gets a random 0 or 1 on each randomize() call
  bit dout;      // Holds the output captured from the DUT

  // ----------------------------------------------------------
  // FUNCTION: copy
  // Returns a new transaction object with the same values.
  // We send copies (not the original) to mailboxes so that
  // the original can be re-randomized without affecting
  // what was already sent.
  // ----------------------------------------------------------
  function transaction copy();
    copy = new();
    copy.din  = this.din;
    copy.dout = this.dout;
  endfunction

  // ----------------------------------------------------------
  // FUNCTION: display
  // Prints din and dout with a tag (e.g. "GEN", "DRV", "SCO")
  // so we can tell which component printed the message.
  // ----------------------------------------------------------
  function void display(input string tag);
    $display("[%0s] : DIN : %0b DOUT : %0b", tag, din, dout);
  endfunction

endclass

// ============================================================
// CLASS: generator
// Responsible for creating random stimulus and sending it to:
//   1. The driver  (via mbx)    — to be applied to the DUT
//   2. The scoreboard (via mbxref) — as the golden reference
// ============================================================
class generator;
  transaction tr;                    // Reused transaction object for randomization
  mailbox #(transaction) mbx;        // Sends stimulus copies to the driver
  mailbox #(transaction) mbxref;     // Sends stimulus copies to the scoreboard
  event sconext;  // Generator waits on this after each transaction;
                  // scoreboard triggers it when it finishes comparing
  event done;     // Triggered when all 'count' transactions are sent
  int count;      // Number of transactions to generate (set from testbench)

  function new(mailbox #(transaction) mbx, mailbox #(transaction) mbxref);
    this.mbx    = mbx;
    this.mbxref = mbxref;
    tr = new();
  endfunction

  task run();
    repeat(count) begin
      assert(tr.randomize) else $error("[GEN] : RANDOMIZATION FAILED");
      mbx.put(tr.copy);     // Send a copy to the driver
      mbxref.put(tr.copy);  // Send the same copy to the scoreboard
      tr.display("GEN");
      @(sconext);           // Pause until scoreboard finishes this transaction
    end
    ->done;                 // Notify that all stimuli have been sent
  endtask

endclass

// ============================================================
// CLASS: driver
// Receives transactions from the generator and applies
// din to the DUT through the virtual interface.
// ============================================================
class driver;
  transaction tr;              // Holds the current transaction being driven
  mailbox #(transaction) mbx;  // Receives transactions from the generator
  virtual dff_if vif;          // Virtual interface — connects to the actual DUT signals

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  // ----------------------------------------------------------
  // TASK: reset
  // Asserts rst for 5 clock cycles to put the DUT in a known
  // state before the actual test begins.
  // ----------------------------------------------------------
  task reset();
    vif.rst <= 1'b1;              // Assert reset (active-high)
    repeat(5) @(posedge vif.clk); // Hold reset for 5 rising edges
    vif.rst <= 1'b0;              // Deassert reset — DUT is now ready
    @(posedge vif.clk);           // Wait one extra cycle to settle
    $display("[DRV] : RESET DONE");
  endtask

  // ----------------------------------------------------------
  // TASK: run
  // Continuously fetches transactions and drives din onto
  // the DUT for one clock cycle, then clears it.
  // ----------------------------------------------------------
  task run();
    forever begin
      mbx.get(tr);           // Block until a transaction is available
      vif.din <= tr.din;     // Drive din onto the DUT input
      @(posedge vif.clk);    // Wait one clock edge — DUT captures din into dout
      tr.display("DRV");
      vif.din <= 1'b0;       // Clear din after the capture
      @(posedge vif.clk);    // Wait one more edge before next transaction
    end
  endtask

endclass

// ============================================================
// CLASS: monitor
// Watches the DUT outputs and forwards what it sees to
// the scoreboard for checking.
// ============================================================
class monitor;
  transaction tr;              // Holds the captured output values
  mailbox #(transaction) mbx;  // Sends captured transactions to the scoreboard
  virtual dff_if vif;          // Virtual interface — reads DUT output signals

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  // ----------------------------------------------------------
  // TASK: run
  // Waits 2 clock edges (matching the driver's 2-edge cycle),
  // then samples dout and forwards it to the scoreboard.
  // ----------------------------------------------------------
  task run();
    tr = new();
    forever begin
      repeat(2) @(posedge vif.clk); // Wait 2 edges to align with driver timing
      tr.dout = vif.dout;           // Sample DUT output
      mbx.put(tr);                  // Forward to scoreboard
      tr.display("MON");
    end
  endtask

endclass

// ============================================================
// CLASS: scoreboard
// Compares the DUT's actual output (from monitor) against
// the expected output (from generator's reference copy).
// ============================================================
class scoreboard;
  transaction tr;                    // Actual output received from the monitor
  transaction trref;                 // Expected output received from the generator
  mailbox #(transaction) mbx;        // Receives actual results from the monitor
  mailbox #(transaction) mbxref;     // Receives reference data from the generator
  event sconext;  // Triggered after each comparison to unblock the generator

  function new(mailbox #(transaction) mbx, mailbox #(transaction) mbxref);
    this.mbx    = mbx;
    this.mbxref = mbxref;
  endfunction

  // ----------------------------------------------------------
  // TASK: run
  // Gets one actual and one reference transaction per cycle,
  // compares them, and signals the generator to proceed.
  //
  // NOTE: For a DFF, the expected dout equals the din that
  // was applied one clock earlier — so we compare
  // tr.dout (actual) with trref.din (reference input).
  // ----------------------------------------------------------
  task run();
    forever begin
      mbx.get(tr);         // Wait for actual output from monitor
      mbxref.get(trref);   // Wait for reference data from generator
      tr.display("SCO");
      trref.display("REF");
      if (tr.dout == trref.din)
        $display("[SCO] : DATA MATCHED");
      else
        $display("[SCO] : DATA MISMATCHED");
      $display("-------------------------------------------------");
      ->sconext;           // Unblock the generator for the next transaction
    end
  endtask

endclass

// ============================================================
// CLASS: environment
// The top-level container that creates and connects all
// testbench components: generator, driver, monitor, scoreboard.
// ============================================================
class environment;
  generator  gen;  // Generates random stimulus
  driver     drv;  // Drives stimulus onto the DUT
  monitor    mon;  // Observes DUT outputs
  scoreboard sco;  // Checks actual vs. expected output
  event next;      // Shared event between generator and scoreboard

  mailbox #(transaction) gdmbx;   // Generator → Driver
  mailbox #(transaction) msmbx;   // Monitor   → Scoreboard
  mailbox #(transaction) mbxref;  // Generator → Scoreboard (reference)

  virtual dff_if vif;

  function new(virtual dff_if vif);
    gdmbx  = new();
    mbxref = new();
    gen = new(gdmbx, mbxref);  // Generator needs both mailboxes
    drv = new(gdmbx);          // Driver only needs the generator→driver mailbox
    msmbx = new();
    mon = new(msmbx);          // Monitor sends to scoreboard
    sco = new(msmbx, mbxref);  // Scoreboard receives from monitor and generator
    this.vif  = vif;
    drv.vif   = this.vif;      // Give driver access to DUT signals
    mon.vif   = this.vif;      // Give monitor access to DUT signals
    gen.sconext = next;        // Generator waits on this event
    sco.sconext = next;        // Scoreboard triggers this event
  endfunction

  // ----------------------------------------------------------
  // TASK: pre_test — runs before the main test
  // Resets the DUT so it starts from a known state.
  // ----------------------------------------------------------
  task pre_test();
    drv.reset();
  endtask

  // ----------------------------------------------------------
  // TASK: test — runs all 4 components in parallel
  // fork-join_any starts all 4 and returns as soon as
  // any one of them finishes (the generator finishes first).
  // ----------------------------------------------------------
  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sco.run();
    join_any
  endtask

  // ----------------------------------------------------------
  // TASK: post_test — runs after the main test
  // Waits for the generator's 'done' event to confirm all
  // transactions are processed, then ends simulation.
  // ----------------------------------------------------------
  task post_test();
    wait(gen.done.triggered);
    $finish();
  endtask

  task run();
    pre_test();
    test();
    post_test();
  endtask

endclass

// ============================================================
// MODULE: tb (testbench top)
// The top-level module that instantiates the DUT and
// environment, generates the clock, and kicks off the test.
// ============================================================
module tb;
  dff_if vif();    // Instantiate the interface (holds all DUT signals)
  dff dut(vif);    // Instantiate the DUT and connect it to the interface

  // Clock initialization — start at 0
  initial begin
    vif.clk <= 0;
  end

  // Clock generator — toggles every 10 time units → period = 20
  always #10 vif.clk <= ~vif.clk;

  environment env;

  initial begin
    env = new(vif);       // Build and connect all testbench components
    env.gen.count = 30;   // Run 30 randomized transactions
    env.run();            // Execute pre_test → test → post_test
  end

  // Waveform dump — lets you view signals in a waveform viewer
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end

endmodule

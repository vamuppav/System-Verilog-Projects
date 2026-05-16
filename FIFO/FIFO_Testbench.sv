// =============================================================
// Class : transaction
// Purpose : Data carrier passed between all testbench components.
//           Generator fills 'oper'; monitor fills everything else.
// =============================================================
class transaction;

  rand bit       oper;      // Randomized — 1 = write, 0 = read
  bit            rd, wr;    // Control signals sampled from interface by monitor
  bit [7:0]      data_in;   // Data written into the FIFO
  bit [7:0]      data_out;  // Data read out of the FIFO
  bit            full;      // FIFO full flag sampled at time of transaction
  bit            empty;     // FIFO empty flag sampled at time of transaction

  // 50% chance of write, 50% chance of read each randomization call
  constraint oper_ctrl {
    oper dist {1 :/ 50, 0 :/ 50};
  }

endclass


// =============================================================
// Class : generator
// Purpose : Randomizes transactions and sends them to the driver
//           one at a time, paced by the scoreboard via 'next' event.
// =============================================================
class generator;

  transaction              tr;    // Reused transaction object
  mailbox #(transaction)   mbx;   // Shared mailbox → driver picks up from here
  int                      count; // Total transactions to generate; set from tb
  int                      i;     // Iteration counter for display

  event next;   // Scoreboard triggers this after each check — unblocks generator
  event done;   // Generator triggers this after all iterations — signals $finish

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
    tr = new();
  endfunction

  task run();
    repeat (count) begin
      // Randomize oper (write or read); fail loudly if solver finds no solution
      assert (tr.randomize) else $error("Randomization failed");
      i++;
      mbx.put(tr);   // Hand transaction to driver
      $display("[GEN] : Oper : %0d  Iteration : %0d", tr.oper, i);
      @(next);       // Wait for scoreboard to finish checking before firing next
    end
    -> done;         // All iterations complete — post_test can now call $finish
  endtask

endclass


// =============================================================
// Class : driver
// Purpose : Receives transactions from the generator and drives
//           the DUT through the virtual interface accordingly.
// =============================================================
class driver;

  virtual fifo_if          fif;    // Handle to the actual interface signals
  mailbox #(transaction)   mbx;    // Shared mailbox — generator puts, driver gets
  transaction              datac;  // Transaction received from mailbox

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  // -------------------------------------------------------------------
  // Task : reset
  // Holds rst high for 5 clock cycles, clearing wptr/rptr/cnt in DUT.
  // Called once in pre_test before any transactions are driven.
  // -------------------------------------------------------------------
  task reset();
    fif.rst     <= 1'b1;
    fif.rd      <= 1'b0;
    fif.wr      <= 1'b0;
    fif.data_in <= 0;
    repeat (5) @(posedge fif.clock);  // Keep reset asserted for 5 cycles
    fif.rst <= 1'b0;
    $display("[DRV] : DUT Reset Done");
    $display("------------------------------------------");
  endtask

  // -------------------------------------------------------------------
  // Task : write
  // Drives a single write transaction — 3 clock edges total:
  //   Edge 1 : Assert wr, place random data on data_in
  //   Edge 2 : DUT latches data on this rising edge
  //   Edge 3 : Deassert wr, allow signals to settle
  // -------------------------------------------------------------------
  task write();
    @(posedge fif.clock);
    fif.rst     <= 1'b0;
    fif.rd      <= 1'b0;
    fif.wr      <= 1'b1;
    fif.data_in <= $urandom_range(1, 10);  // Random payload 1–10
    @(posedge fif.clock);
    fif.wr <= 1'b0;   // Deassert after DUT has latched
    $display("[DRV] : DATA WRITE  data : %0d", fif.data_in);
    @(posedge fif.clock);  // Settling cycle before next operation
  endtask

  // -------------------------------------------------------------------
  // Task : read
  // Drives a single read transaction — 3 clock edges total:
  //   Edge 1 : Assert rd
  //   Edge 2 : DUT drives dout on this rising edge
  //   Edge 3 : Deassert rd; dout is now stable for monitor to sample
  // -------------------------------------------------------------------
  task read();
    @(posedge fif.clock);
    fif.rst <= 1'b0;
    fif.rd  <= 1'b1;
    fif.wr  <= 1'b0;
    @(posedge fif.clock);
    fif.rd <= 1'b0;   // Deassert after DUT has driven dout
    $display("[DRV] : DATA READ");
    @(posedge fif.clock);  // Settling cycle — monitor samples dout here
  endtask

  // -------------------------------------------------------------------
  // Task : run
  // Loops forever: pulls a transaction from the mailbox, then calls
  // write() or read() based on oper. Killed by join_any in environment
  // once the generator finishes all iterations.
  // -------------------------------------------------------------------
  task run();
    forever begin
      mbx.get(datac);               // Blocks until generator puts a transaction
      if (datac.oper == 1'b1)
        write();
      else
        read();
    end
  endtask

endclass


// =============================================================
// Class : monitor
// Purpose : Passively samples the interface after each driver
//           operation and forwards a filled transaction to the
//           scoreboard. Never drives any signal.
// =============================================================
class monitor;

  virtual fifo_if          fif;  // Read-only view of the interface
  mailbox #(transaction)   mbx;  // Shared mailbox — monitor puts, scoreboard gets
  transaction              tr;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  // -------------------------------------------------------------------
  // Task : run
  // Sampling strategy — aligned to driver's 3-edge timing:
  //   Skip 2 edges : wr/rd/data_in/full/empty are stable by edge 2
  //   Skip 1 more  : dout is stable by edge 3 (one cycle after rd)
  // -------------------------------------------------------------------
  task run();
    tr = new();
    forever begin
      repeat (2) @(posedge fif.clock);  // Wait for control signals to settle
      tr.wr      = fif.wr;
      tr.rd      = fif.rd;
      tr.data_in = fif.data_in;
      tr.full    = fif.full;
      tr.empty   = fif.empty;
      @(posedge fif.clock);             // One more edge — dout now valid
      tr.data_out = fif.data_out;
      mbx.put(tr);  // Forward fully-populated transaction to scoreboard
      $display("[MON] : Wr:%0d rd:%0d din:%0d dout:%0d full:%0d empty:%0d",
               tr.wr, tr.rd, tr.data_in, tr.data_out, tr.full, tr.empty);
    end
  endtask

endclass


// =============================================================
// Class : scoreboard
// Purpose : Maintains a software model of the FIFO (a queue) and
//           compares DUT output against expected values.
//           Triggers 'next' after each check to pace the generator.
// =============================================================
class scoreboard;

  mailbox #(transaction)   mbx;     // Shared mailbox — monitor puts, scoreboard gets
  transaction              tr;
  event                    next;    // Fired after each check → unblocks generator
  bit [7:0]                din[$];  // Reference queue mirroring DUT contents
  bit [7:0]                temp;    // Holds expected data during read comparison
  int                      err;     // Cumulative mismatch count

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  // -------------------------------------------------------------------
  // Task : run
  // Reference model logic:
  //   Write path : push data_in to front of queue (if not full)
  //   Read path  : pop from back of queue and compare with DUT dout
  //
  // Queue direction — push_front / pop_back gives FIFO order:
  //   First item written lands at the back after subsequent push_fronts,
  //   so pop_back always retrieves the oldest entry first.
  // -------------------------------------------------------------------
  task run();
    forever begin
      mbx.get(tr);  // Block until monitor sends a transaction
      $display("[SCO] : Wr:%0d rd:%0d din:%0d dout:%0d full:%0d empty:%0d",
               tr.wr, tr.rd, tr.data_in, tr.data_out, tr.full, tr.empty);

      // --- Write path -----------------------------------------------
      if (tr.wr == 1'b1) begin
        if (tr.full == 1'b0) begin
          din.push_front(tr.data_in);   // Mirror the DUT write in reference queue
          $display("[SCO] : DATA STORED IN QUEUE : %0d", tr.data_in);
        end
        else
          $display("[SCO] : FIFO IS FULL — write ignored");
        $display("--------------------------------------");
      end

      // --- Read path ------------------------------------------------
      if (tr.rd == 1'b1) begin
        if (tr.empty == 1'b0) begin
          temp = din.pop_back();        // Retrieve oldest entry from reference queue
          if (tr.data_out == temp)
            $display("[SCO] : DATA MATCH expected %0d got %0d", temp, tr.data_out);
          else begin
            $error("[SCO] : DATA MISMATCH expected %0d got %0d", temp, tr.data_out);
            err++;
          end
        end
        else
          $display("[SCO] : FIFO IS EMPTY — read ignored");
        $display("--------------------------------------");
      end

      -> next;  // Unblock generator — safe to fire the next transaction
    end
  endtask

endclass


// =============================================================
// Class : environment
// Purpose : Constructs all components, wires mailboxes and events,
//           and sequences the three test phases (pre/test/post).
// =============================================================
class environment;

  generator    gen;
  driver       drv;
  monitor      mon;
  scoreboard   sco;

  mailbox #(transaction)   gdmbx;   // Generator → Driver channel
  mailbox #(transaction)   msmbx;   // Monitor  → Scoreboard channel

  event          nextgs;    // Pacing event shared between generator and scoreboard
  virtual fifo_if fif;

  function new(virtual fifo_if fif);
    gdmbx    = new();
    gen      = new(gdmbx);
    drv      = new(gdmbx);
    msmbx    = new();
    mon      = new(msmbx);
    sco      = new(msmbx);
    this.fif = fif;
    drv.fif  = this.fif;   // Give driver access to interface
    mon.fif  = this.fif;   // Give monitor access to interface
    gen.next = nextgs;     // Generator waits on this event
    sco.next = nextgs;     // Scoreboard triggers this event
  endfunction

  // Reset DUT before any stimulus
  task pre_test();
    drv.reset();
  endtask

  // Launch all four components in parallel.
  // join_any exits as soon as gen.run() returns (after count iterations);
  // drv/mon/sco run forever and are killed by join_any.
  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sco.run();
    join_any
  endtask

  // Wait for generator's done event, report errors, end simulation
  task post_test();
    wait (gen.done.triggered);
    $display("---------------------------------------------");
    $display("Error Count : %0d", sco.err);
    $display("---------------------------------------------");
    $finish();
  endtask

  task run();
    pre_test();
    test();
    post_test();
  endtask

endclass


// =============================================================
// Module : tb (testbench top)
// Purpose : Only synthesizable piece is DUT instantiation.
//           Generates clock, creates environment, starts simulation.
// =============================================================
module tb;

  fifo_if fif();   // Interface instance — bundles all DUT signals

  // DUT instantiation — positional port order must match module header
  FIFO dut (
    fif.clock,
    fif.rst,
    fif.wr,
    fif.rd,
    fif.data_in,
    fif.data_out,
    fif.empty,
    fif.full
  );

  // Initialize clock to 0 before simulation starts
  initial fif.clock <= 0;

  // Toggle every 10 time units → 20-unit period → 50 MHz
  always #10 fif.clock <= ~fif.clock;

  environment env;

  initial begin
    env           = new(fif);
    env.gen.count = 10;     // Run 10 randomized transactions
    env.run();
  end

  // Dump all signals for waveform viewing
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end

endmodule

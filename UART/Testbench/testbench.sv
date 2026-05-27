// =============================================================
// Class : transaction
// Holds all signals for one UART operation (TX or RX)
// oper : write = TX path, read = RX path (randc — alternates)
// =============================================================
class transaction;

  typedef enum bit {write = 1'b0, read = 1'b1} oper_type;

  randc oper_type oper;   // Alternates between write and read

  bit        rx;
  rand bit [7:0] dintx;  // Random data to transmit

  bit        newd;
  bit        tx;
  bit  [7:0] doutrx;
  bit        donetx;
  bit        donerx;

  // Returns a deep copy of this transaction
  function transaction copy();
    copy        = new();
    copy.rx     = this.rx;
    copy.dintx  = this.dintx;
    copy.newd   = this.newd;
    copy.tx     = this.tx;
    copy.doutrx = this.doutrx;
    copy.donetx = this.donetx;
    copy.donerx = this.donerx;
    copy.oper   = this.oper;
  endfunction

endclass


// =============================================================
// Class : generator
// Randomizes transactions and sends copies to driver via mailbox
// Waits for drvnext and sconext after each transaction
// =============================================================
class generator;

  transaction            tr;
  mailbox #(transaction) mbx;

  event done;     // Triggered after all transactions are sent
  event drvnext;  // Driver signals ready for next transaction
  event sconext;  // Scoreboard signals check complete

  int count = 0;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
    tr = new();
  endfunction

  task run();
    repeat(count) begin
      assert(tr.randomize) else $error("[GEN] : Randomization Failed");
      mbx.put(tr.copy);
      $display("[GEN] : Oper : %0s Din : %0d", tr.oper.name(), tr.dintx);
      @(drvnext);  // Wait for driver to complete
      @(sconext);  // Wait for scoreboard to complete
    end
    -> done;   // All transactions sent
  endtask

endclass


///////////////////////////////////////////////////////////////////


// =============================================================
// Class : driver
// Drives DUT via virtual interface based on transaction oper type
// write (TX) : asserts newd, sends dintx over TX path
// read  (RX) : drives serial bits on rx line bit by bit
// =============================================================
class driver;

  virtual uart_if        vif;
  transaction            tr;
  mailbox #(transaction) mbx;
  mailbox #(bit [7:0])   mbxds;  // Forwards sent/received data to scoreboard

  event drvnext;

  bit [7:0] din;
  bit       wr = 0;
  bit [7:0] datarx;

  function new(mailbox #(bit [7:0]) mbxds, mailbox #(transaction) mbx);
    this.mbx   = mbx;
    this.mbxds = mbxds;
  endfunction

  // Assert reset and hold for 5 baud cycles
  task reset();
    vif.rst   <= 1'b1;
    vif.dintx <= 0;
    vif.newd  <= 0;
    vif.rx    <= 1'b1;
    repeat(5) @(posedge vif.uclktx);
    vif.rst   <= 1'b0;
    @(posedge vif.uclktx);
    $display("[DRV] : RESET DONE");
    $display("----------------------------------------");
  endtask

  task run();
    forever begin
      mbx.get(tr);

      // TX path — assert newd, drive dintx, wait for donetx
      if (tr.oper == 1'b0) begin
        @(posedge vif.uclktx);
        vif.rst   <= 1'b0;
        vif.newd  <= 1'b1;   // Trigger transmission
        vif.rx    <= 1'b1;
        vif.dintx  = tr.dintx;
        @(posedge vif.uclktx);
        vif.newd  <= 1'b0;
        mbxds.put(tr.dintx);
        $display("[DRV] : Data Sent : %0d", tr.dintx);
        wait(vif.donetx == 1'b1);
        -> drvnext;
      end

      // RX path — drive start bit then 8 serial bits on rx line
      else if (tr.oper == 1'b1) begin
        @(posedge vif.uclkrx);
        vif.rst  <= 1'b0;
        vif.rx   <= 1'b0;    // Start bit
        vif.newd <= 1'b0;
        @(posedge vif.uclkrx);

        for (int i = 0; i <= 7; i++) begin
          @(posedge vif.uclkrx);
          vif.rx    <= $urandom;
          datarx[i]  = vif.rx;   // Capture each driven bit
        end

        mbxds.put(datarx);
        $display("[DRV] : Data RCVD : %0d", datarx);
        wait(vif.donerx == 1'b1);
        vif.rx <= 1'b1;   // Return line to idle
        -> drvnext;
      end

    end
  endtask

endclass


///////////////////////////////////////////////////////////////////


// =============================================================
// Class : monitor
// Observes DUT outputs passively on the interface
// TX path : samples tx line bit by bit after newd asserted
// RX path : captures doutrx after donerx asserted
// =============================================================
class monitor;

  transaction          tr;
  mailbox #(bit [7:0]) mbx;

  bit [7:0] srx;   // Data observed on TX path
  bit [7:0] rrx;   // Data observed on RX path

  virtual uart_if vif;

  function new(mailbox #(bit [7:0]) mbx);
    this.mbx = mbx;
  endfunction

  task run();
    forever begin
      @(posedge vif.uclktx);

      // TX path — collect 8 bits from tx line after newd asserted
      if ((vif.newd == 1'b1) && (vif.rx == 1'b1)) begin
        @(posedge vif.uclktx);   // Skip to first data bit

        for (int i = 0; i <= 7; i++) begin
          @(posedge vif.uclktx);
          srx[i] = vif.tx;       // Sample each transmitted bit
        end

        $display("[MON] : DATA SEND on UART TX %0d", srx);
        @(posedge vif.uclktx);
        mbx.put(srx);
      end

      // RX path — wait for donerx then capture doutrx
      else if ((vif.rx == 1'b0) && (vif.newd == 1'b0)) begin
        wait(vif.donerx == 1);
        rrx = vif.doutrx;
        $display("[MON] : DATA RCVD RX %0d", rrx);
        @(posedge vif.uclktx);
        mbx.put(rrx);
      end

    end
  endtask

endclass


///////////////////////////////////////////////////////////////////


// =============================================================
// Class : scoreboard
// Compares data from driver mailbox against monitor mailbox
// Triggers sconext after each check to unblock generator
// =============================================================
class scoreboard;

  mailbox #(bit [7:0]) mbxds;   // Data from driver
  mailbox #(bit [7:0]) mbxms;   // Data from monitor

  bit [7:0] ds;
  bit [7:0] ms;

  event sconext;

  function new(mailbox #(bit [7:0]) mbxds, mailbox #(bit [7:0]) mbxms);
    this.mbxds = mbxds;
    this.mbxms = mbxms;
  endfunction

  task run();
    forever begin
      mbxds.get(ds);
      mbxms.get(ms);

      $display("[SCO] : DRV : %0d MON : %0d", ds, ms);

      if (ds == ms)
        $display("DATA MATCHED");
      else
        $display("DATA MISMATCHED");

      $display("----------------------------------------");
      -> sconext;   // Unblock generator for next transaction
    end
  endtask

endclass


///////////////////////////////////////////////////////////////////


// =============================================================
// Class : environment
// Constructs and connects all testbench components
// Mailbox wiring : gen → drv (mbxgd), drv → sco (mbxds), mon → sco (mbxms)
// Event wiring   : drvnext (gen ↔ drv), sconext (gen ↔ sco)
// =============================================================
class environment;

  generator  gen;
  driver     drv;
  monitor    mon;
  scoreboard sco;

  event nextgd;   // Synchronizes generator and driver
  event nextgs;   // Synchronizes generator and scoreboard

  mailbox #(transaction) mbxgd;   // Generator → driver
  mailbox #(bit [7:0])   mbxds;   // Driver    → scoreboard
  mailbox #(bit [7:0])   mbxms;   // Monitor   → scoreboard

  virtual uart_if vif;

  function new(virtual uart_if vif);
    mbxgd = new();
    mbxms = new();
    mbxds = new();

    gen = new(mbxgd);
    drv = new(mbxds, mbxgd);
    mon = new(mbxms);
    sco = new(mbxds, mbxms);

    this.vif = vif;
    drv.vif  = this.vif;
    mon.vif  = this.vif;

    gen.sconext = nextgs;
    sco.sconext = nextgs;

    gen.drvnext = nextgd;
    drv.drvnext = nextgd;
  endfunction

  task pre_test();
    drv.reset();
  endtask

  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sco.run();
    join_any
  endtask

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


///////////////////////////////////////////////////////////////////


// =============================================================
// Module : tb
// Instantiates DUT and environment; assigns internal baud clocks
// to interface signals for driver and monitor synchronization
// =============================================================
module tb;

  uart_if vif();

  uart_top #(1000000, 9600) dut (
    vif.clk, vif.rst, vif.rx, vif.dintx,
    vif.newd, vif.tx, vif.doutrx, vif.donetx, vif.donerx
  );

  initial vif.clk <= 0;
  always #10 vif.clk <= ~vif.clk;

  environment env;

  initial begin
    env           = new(vif);
    env.gen.count = 5;
    env.run();
  end

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end

  // Expose internal baud clocks through interface for testbench synchronization
  assign vif.uclktx = dut.utx.uclk;
  assign vif.uclkrx = dut.rtx.uclk;

endmodule

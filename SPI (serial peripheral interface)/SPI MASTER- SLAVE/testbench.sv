//------------------------------------------------
// Transaction Class
// Blueprint for one SPI transaction.
// Holds stimulus (din) and response (dout).
// newd is not randomized here — driver controls it.
//------------------------------------------------
class transaction;

    bit        newd;    // new data flag (driven by driver, not randomized)
    rand bit [11:0] din;  // randomized 12-bit data to send
    bit [11:0] dout;    // 12-bit data received from slave

    // Deep copy — generator sends a copy to mailbox
    // so the original tr can be randomized again
    // without corrupting what the driver received
    function transaction copy();
        copy      = new();
        copy.newd = this.newd;
        copy.din  = this.din;
        copy.dout = this.dout;
    endfunction

endclass


//------------------------------------------------
// Generator Class
// Randomizes transactions and sends copies
// to the driver via mailbox.
// Waits for scoreboard to finish before
// sending the next transaction.
//------------------------------------------------
class generator;

    transaction            tr;
    mailbox #(transaction) mbx;     // mailbox to driver
    event                  done;    // fired when all transactions sent
    int                    count;   // how many transactions to generate
    event                  drvnext; // unused in this version
    event                  sconext; // waits for scoreboard to finish each check

    function new(mailbox #(transaction) mbx);
        this.mbx = mbx;
        tr       = new();
    endfunction

    task run();
        repeat(count) begin
            // randomize tr; $error if randomization fails
            assert(tr.randomize) else $error("[GEN] : Randomization Failed");
            mbx.put(tr.copy);               // send copy to driver
            $display("[GEN] : din : %0d", tr.din);
            @(sconext);                     // wait for scoreboard to finish
                                            // before generating next transaction
        end
        -> done;                            // notify environment: all done
    endtask

endclass


//------------------------------------------------
// Driver Class
// Fetches transactions from generator mailbox
// and applies stimulus to the DUT via
// the virtual interface.
// Also forwards sent data to scoreboard
// via mbxds for later comparison.
//------------------------------------------------
class driver;

    virtual spi_if         vif;
    transaction            tr;
    mailbox #(transaction) mbx;     // mailbox from generator
    mailbox #(bit [11:0])  mbxds;   // forwards sent din to scoreboard
    event                  drvnext; // unused in this version

    function new(mailbox #(bit [11:0]) mbxds, mailbox #(transaction) mbx);
        this.mbx   = mbx;
        this.mbxds = mbxds;
    endfunction

    // Hold reset for 10 clk cycles then release.
    // Ensures DUT starts from a known clean state.
    task reset();
        vif.rst  <= 1'b1;
        vif.newd <= 1'b0;
        vif.din  <= 1'b0;
        repeat(10) @(posedge vif.clk);
        vif.rst  <= 1'b0;
        repeat(5)  @(posedge vif.clk);
        $display("[DRV] : RESET DONE");
        $display("-----------------------------------------");
    endtask

    task run();
        forever begin
            mbx.get(tr);                    // block until generator sends a transaction

            vif.newd <= 1'b1;               // tell master: new data is ready
            vif.din  <= tr.din;             // place 12-bit data on the bus
            mbxds.put(tr.din);              // send reference copy to scoreboard

            @(posedge vif.sclk);            // wait one sclk so master latches din
            vif.newd <= 1'b0;               // deassert newd

            @(posedge vif.done);            // wait for slave to finish receiving
            $display("[DRV] : DATA SENT TO DAC : %0d", tr.din);

            @(posedge vif.sclk);            // allow one extra sclk before next transaction
        end
    endtask

endclass


//------------------------------------------------
// Monitor Class
// Passively observes the DUT outputs.
// Waits for done to pulse, then captures dout
// and forwards it to the scoreboard.
// Does NOT drive anything.
//------------------------------------------------
class monitor;

    transaction           tr;
    mailbox #(bit [11:0]) mbx;   // mailbox to scoreboard

    virtual spi_if vif;

    function new(mailbox #(bit [11:0]) mbx);
        this.mbx = mbx;
    endfunction

    task run();
        tr = new();
        forever begin
            @(posedge vif.sclk);        // align to sclk

            @(posedge vif.done);        // wait for slave to assert done
                                        // done = all 12 bits received

            tr.dout = vif.dout;         // capture 12-bit reconstructed output

            @(posedge vif.sclk);        // one extra sclk for stability

            $display("[MON] : DATA SENT : %0d", tr.dout);
            mbx.put(tr.dout);           // forward to scoreboard
        end
    endtask

endclass


//------------------------------------------------
// Scoreboard Class
// Receives reference data from driver (mbxds)
// and observed data from monitor (mbxms).
// Compares them and reports PASS or FAIL.
// Fires sconext after each check so generator
// can proceed to the next transaction.
//------------------------------------------------
class scoreboard;

    mailbox #(bit [11:0]) mbxds;   // reference data from driver
    mailbox #(bit [11:0]) mbxms;   // observed data from monitor
    bit [11:0]            ds;      // driver's sent value
    bit [11:0]            ms;      // monitor's captured value
    event                 sconext; // notifies generator: check done

    function new(mailbox #(bit [11:0]) mbxds, mailbox #(bit [11:0]) mbxms);
        this.mbxds = mbxds;
        this.mbxms = mbxms;
    endfunction

    task run();
        forever begin
            mbxds.get(ds);          // block until driver sends reference
            mbxms.get(ms);          // block until monitor sends observation

            $display("[SCO] : DRV : %0d MON : %0d", ds, ms);

            if (ds == ms)
                $display("[SCO] : DATA MATCHED");
            else
                $display("[SCO] : DATA MISMATCHED");

            $display("-----------------------------------------");
            -> sconext;             // unblock generator for next transaction
        end
    endtask

endclass


//------------------------------------------------
// Environment Class
// Creates and connects all testbench components.
// Manages the three-phase execution:
//   pre_test  : reset
//   test      : run all components in parallel
//   post_test : wait for generator to finish
//------------------------------------------------
class environment;

    generator  gen;
    driver     drv;
    monitor    mon;
    scoreboard sco;

    event nextgd;   // generator <-> driver sync (declared but unused here)
    event nextgs;   // generator <-> scoreboard sync

    mailbox #(transaction) mbxgd;   // generator -> driver
    mailbox #(bit [11:0])  mbxds;   // driver    -> scoreboard
    mailbox #(bit [11:0])  mbxms;   // monitor   -> scoreboard

    virtual spi_if vif;

    function new(virtual spi_if vif);
        // create all mailboxes first
        mbxgd = new();
        mbxms = new();
        mbxds = new();

        // construct components and pass their mailboxes
        gen = new(mbxgd);
        drv = new(mbxds, mbxgd);
        mon = new(mbxms);
        sco = new(mbxds, mbxms);

        // pass virtual interface down to components that need it
        this.vif = vif;
        drv.vif  = this.vif;
        mon.vif  = this.vif;

        // connect synchronization events
        // sconext: scoreboard fires it, generator waits on it
        gen.sconext = nextgs;
        sco.sconext = nextgs;

        // drvnext: declared but not actively used in this version
        gen.drvnext = nextgd;
        drv.drvnext = nextgd;
    endfunction

    task pre_test();
        drv.reset();            // apply and release reset before any stimulus
    endtask

    // fork all four components — join_any exits as soon as
    // the generator finishes (post_test handles $finish)
    task test();
        fork
            gen.run();
            drv.run();
            mon.run();
            sco.run();
        join_any
    endtask

    // wait for generator done event then end simulation
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


//------------------------------------------------
// Testbench Top Module
// Instantiates the DUT and environment.
// Generates the system clock.
// Connects sclk from inside the DUT since
// it is not a port of the top module.
//------------------------------------------------
module tb;

    spi_if vif();   // interface instance holds all shared signals

    // connect interface signals to top module ports
    top dut (
        vif.clk,
        vif.rst,
        vif.newd,
        vif.din,
        vif.dout,
        vif.done
    );

    // clock generation: period = 20 time units
    initial      vif.clk <= 0;
    always #10   vif.clk <= ~vif.clk;

    // sclk is internal to top (wire between master and slave)
    // tap it directly from the master submodule
    assign vif.sclk = dut.m1.sclk;

    environment env;

    initial begin
        env           = new(vif);
        env.gen.count = 4;      // run 4 transactions
        env.run();
    end

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars;
    end

endmodule

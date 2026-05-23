//------------------------------------------------
// Transaction Class
// Holds all signals for one SPI transaction
//------------------------------------------------
class transaction;

    rand bit        newd;   // randomized new data flag
    rand bit [11:0] din;    // randomized 12-bit data input
    bit             cs;     // chip select
    bit             mosi;   // serial data line

    // Print current transaction state with a tag label
    function void display(input string tag);
        $display("[%0s] : DATA_NEW : %0b DIN : %0d CS : %b MOSI : %0b ",
                  tag, newd, din, cs, mosi);
    endfunction

    // Return a deep copy of this transaction
    function transaction copy();
        copy       = new();
        copy.newd  = this.newd;
        copy.din   = this.din;
        copy.cs    = this.cs;
        copy.mosi  = this.mosi;
    endfunction

endclass


//------------------------------------------------
// Generator Class
// Randomizes transactions and sends them to
// the driver via a mailbox
//------------------------------------------------
class generator;

    transaction             tr;
    mailbox #(transaction)  mbx;     // mailbox to driver
    event                   done;    // signals all transactions sent
    int                     count;   // number of transactions to generate
    event                   drvnext; // waits for driver to finish
    event                   sconext; // waits for scoreboard to finish

    function new(mailbox #(transaction) mbx);
        this.mbx = mbx;
        tr       = new();
    endfunction

    task run();
        repeat(count) begin
            assert(tr.randomize) else $error("[GEN] : Randomization Failed");
            mbx.put(tr.copy);        // send copy to driver
            tr.display("GEN");
            @(drvnext);              // wait for driver to complete
            @(sconext);              // wait for scoreboard to complete
        end
        -> done;                     // notify environment all transactions done
    endtask

endclass


//------------------------------------------------
// Driver Class
// Receives transactions from generator and
// drives them onto the virtual interface
//------------------------------------------------
class driver;

    virtual spi_if          vif;
    transaction             tr;
    mailbox #(transaction)  mbx;     // mailbox from generator
    mailbox #(bit [11:0])   mbxds;   // mailbox to scoreboard with sent data
    event                   drvnext; // notifies generator when done

    function new(mailbox #(bit [11:0]) mbxds, mailbox #(transaction) mbx);
        this.mbx   = mbx;
        this.mbxds = mbxds;
    endfunction

    // Apply reset and hold for stable startup
    task reset();
        vif.rst  <= 1'b1;
        vif.cs   <= 1'b1;
        vif.newd <= 1'b0;
        vif.din  <= 1'b0;
        vif.mosi <= 1'b0;
        repeat(10) @(posedge vif.clk);
        vif.rst  <= 1'b0;
        repeat(5)  @(posedge vif.clk);
        $display("[DRV] : RESET DONE");
        $display("-----------------------------------------");
    endtask

    // Drive each transaction onto the interface
    task run();
        forever begin
            mbx.get(tr);                        // fetch next transaction
            @(posedge vif.sclk);
            vif.newd <= 1'b1;                   // assert new data flag
            vif.din  <= tr.din;                 // place data on bus
            mbxds.put(tr.din);                  // forward to scoreboard
            @(posedge vif.sclk);
            vif.newd <= 1'b0;                   // deassert new data flag
            wait(vif.cs == 1'b1);               // wait for transaction to complete
            $display("[DRV] : DATA SENT TO DAC : %0d", tr.din);
            -> drvnext;                         // notify generator
        end
    endtask

endclass


//------------------------------------------------
// Monitor Class
// Observes MOSI bit by bit and reconstructs
// the 12-bit value for the scoreboard
//------------------------------------------------
class monitor;

    transaction           tr;
    mailbox #(bit [11:0]) mbx;    // mailbox to scoreboard
    bit [11:0]            srx;    // shift register for received bits

    virtual spi_if vif;

    function new(mailbox #(bit [11:0]) mbx);
        this.mbx = mbx;
    endfunction

    task run();
        forever begin
            @(posedge vif.sclk);
            wait(vif.cs == 1'b0);          // wait for cs to go low (start)
            @(posedge vif.sclk);

            // Sample MOSI on each sclk edge, LSB first
            for (int i = 0; i <= 11; i++) begin
                @(posedge vif.sclk);
                srx[i] = vif.mosi;
            end

            wait(vif.cs == 1'b1);          // wait for cs to go high (end)
            $display("[MON] : DATA SENT : %0d", srx);
            mbx.put(srx);                  // send reconstructed data to scoreboard
        end
    endtask

endclass


//------------------------------------------------
// Scoreboard Class
// Compares data from driver and monitor
// to verify correctness
//------------------------------------------------
class scoreboard;

    mailbox #(bit [11:0]) mbxds;   // data from driver
    mailbox #(bit [11:0]) mbxms;   // data from monitor
    bit [11:0]            ds;      // driver data
    bit [11:0]            ms;      // monitor data
    event                 sconext; // notifies generator when check done

    function new(mailbox #(bit [11:0]) mbxds, mailbox #(bit [11:0]) mbxms);
        this.mbxds = mbxds;
        this.mbxms = mbxms;
    endfunction

    task run();
        forever begin
            mbxds.get(ds);                         // get driver reference data
            mbxms.get(ms);                         // get monitor observed data
            $display("[SCO] : DRV : %0d MON : %0d", ds, ms);

            if (ds == ms)
                $display("[SCO] : DATA MATCHED");
            else
                $display("[SCO] : DATA MISMATCHED");

            $display("-----------------------------------------");
            -> sconext;                            // notify generator
        end
    endtask

endclass


//------------------------------------------------
// Environment Class
// Connects all testbench components and
// manages execution flow
//------------------------------------------------
class environment;

    generator  gen;
    driver     drv;
    monitor    mon;
    scoreboard sco;

    event nextgd;   // generator -> driver sync
    event nextgs;   // generator -> scoreboard sync

    mailbox #(transaction)  mbxgd;   // generator to driver
    mailbox #(bit [11:0])   mbxds;   // driver to scoreboard
    mailbox #(bit [11:0])   mbxms;   // monitor to scoreboard

    virtual spi_if vif;

    function new(virtual spi_if vif);
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

        // Connect synchronization events
        gen.sconext = nextgs;
        sco.sconext = nextgs;
        gen.drvnext = nextgd;
        drv.drvnext = nextgd;
    endfunction

    // Apply reset before test begins
    task pre_test();
        drv.reset();
    endtask

    // Launch all components in parallel
    task test();
        fork
            gen.run();
            drv.run();
            mon.run();
            sco.run();
        join_any
    endtask

    // Wait for generator to finish then end simulation
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
// Testbench Top
// Instantiates DUT and environment,
// generates clock, starts simulation
//------------------------------------------------
module tb;

    spi_if vif();

    // Connect interface signals to DUT ports
    spi dut (
        vif.clk,
        vif.newd,
        vif.rst,
        vif.din,
        vif.sclk,
        vif.cs,
        vif.mosi
    );

    // Clock generation: 20 time unit period
    initial vif.clk <= 0;
    always #10 vif.clk <= ~vif.clk;

    environment env;

    initial begin
        env           = new(vif);
        env.gen.count = 20;       // run 20 transactions
        env.run();
    end

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars;
    end

endmodule

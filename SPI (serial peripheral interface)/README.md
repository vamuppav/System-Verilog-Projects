# SPI Master-Slave Communication — SystemVerilog Project

---

## 1. Overview

This project implements a full SPI (Serial Peripheral Interface) communication system in SystemVerilog, consisting of a master transmitter, a slave receiver, and a layered class-based testbench. The master serializes a 12-bit parallel input into a single MOSI line (LSB first) while generating a divided SPI clock. The slave deserializes the incoming bit stream back into a 12-bit output and asserts a `done` flag upon successful reception.

---

## 2. Goal

The primary goal was to learn and practice the following:

- Designing a clock divider and an FSM-based SPI master in RTL
- Implementing a shift-register-based SPI slave
- Building a layered SystemVerilog testbench with a generator, driver, monitor, and scoreboard communicating via mailboxes and synchronization events
- Understanding how interface, virtual interface, and the DUT connect in a self-checking testbench environment

---

## 3. Parameters

| Name | Default Value | Description |
|------|--------------|-------------|
| Clock Divider Count | 10 | `sclk` toggles every 10 `clk` cycles, giving `sclk = fclk / 20` |
| Data Width | 12 bits | Width of the parallel data bus (`din` / `dout`) |
| Bit Count | 12 | Number of SPI bits per transaction (0 through 11) |
| Transaction Count | 4 (tb) / 20 (tb v2) | Number of randomized transactions run by the generator |

> Note: These are not `parameter` declarations in the RTL — they are hardcoded constants. Parameterizing data width and clock division ratio would be a natural next step.

---

## 4. Interface

### `spi_if` — Virtual Interface Signals

| Port Name | Direction | Width | Purpose |
|-----------|-----------|-------|---------|
| `clk` | input (tb drives) | 1 | System clock — drives master clock divider |
| `rst` | input (tb drives) | 1 | Synchronous reset for master FSM and clock divider |
| `newd` | input (tb drives) | 1 | New data flag — tells master to begin a transaction |
| `din` | input (tb drives) | 12 | Parallel data input to the SPI master |
| `dout` | output (DUT drives) | 12 | Parallel data reconstructed by the SPI slave |
| `done` | output (DUT drives) | 1 | Pulses high when slave has received all 12 bits |
| `sclk` | internal wire | 1 | Divided SPI clock; tapped from `dut.m1.sclk` since it is not a port of `top` |

### `top` Module Ports

| Port Name | Direction | Width | Purpose |
|-----------|-----------|-------|---------|
| `clk` | input | 1 | System clock |
| `rst` | input | 1 | Synchronous reset |
| `newd` | input | 1 | New data flag |
| `din` | input | 12 | Parallel data input |
| `dout` | output | 12 | Parallel data output from slave |
| `done` | output | 1 | Transaction complete flag |

> `sclk`, `cs`, and `mosi` are internal wires between master and slave — they are not exposed as ports of `top`.

---

## 5. Design Approach

### Clock Divider
The master generates `sclk` internally using a counter (`countc`). The counter increments every `clk` cycle and toggles `sclk` every 10 cycles, producing a clock running at `fclk / 20`. This keeps the SPI clock well within timing margins and is a standard industrial pattern.

### Master FSM
The master uses a 2-state effective FSM (`idle` → `send` → `idle`) encoded with a 4-value enum (`idle`, `enable`, `send`, `comp`). The `enable` and `comp` states are declared but unused — placeholders for future handshake or completion logic. In `idle`, the master waits for `newd`. When asserted, it latches `din` into `temp` (protecting against mid-transaction changes), asserts `cs` low, and moves to `send`. In `send`, it shifts out `temp[count]` on each `sclk` edge (LSB first) until all 12 bits are sent, then deasserts `cs` and returns to `idle`.

### Slave Shift Register
The slave uses a right-shift register pattern:
```
temp <= {mosi, temp[11:1]};
```
Each incoming bit is inserted at the MSB and old bits shift right. Since the master sends LSB first, after 12 cycles the bits naturally settle into their correct positions. This is elegant — no bit reversal needed post-reception.

### Why LSB first?
Many SPI peripheral devices (DACs, ADCs) expect LSB first. Starting `count` at 0 and indexing `temp[count]` directly implements this without any extra logic.

---

## 6. Testbench Strategy

### Architecture
The testbench follows the layered class-based pattern:

```
Generator → [mbxgd] → Driver → DUT → Monitor → [mbxms] → Scoreboard
                         ↓                                      ↑
                      [mbxds] ───────────────────────────────────
```

### Components

**Generator** — Randomizes `din` using `rand bit [11:0]` and sends deep copies via mailbox. Waits on `sconext` before generating the next transaction, enforcing one-at-a-time flow control.

**Driver** — Applies `newd` and `din` to the virtual interface. Forwards `din` to the scoreboard as the reference value. Waits for `done` (or `cs` deassertion) before proceeding.

**Monitor** — Passively observes `dout` after `done` is asserted (or reconstructs `mosi` bit-by-bit in the alternative version). Sends observed data to the scoreboard.

**Scoreboard** — Compares driver reference (`ds`) against monitor observation (`ms`). Prints `DATA MATCHED` or `DATA MISMATCHED`. Fires `sconext` to unblock the generator.

### Two Testbench Variants
Two TB versions were developed:

- **Version 1** (with `top` DUT): Monitor reads `vif.dout` after `done`. `sclk` is tapped via `assign vif.sclk = dut.m1.sclk`.
- **Version 2** (with `spi` DUT): Monitor reconstructs data by sampling `vif.mosi` bit-by-bit on each `sclk` edge — a more realistic monitor that does not rely on `dout`.

---

## 7. How to Simulate

### Icarus Verilog

```bash
# Compile all files
iverilog -g2012 -o spi_sim \
  spi_master.sv \
  spi_slave.sv \
  top.sv \
  spi_if.sv \
  tb.sv

# Run simulation
vvp spi_sim

# View waveform
gtkwave dump.vcd
```

### ModelSim

```tcl
# In ModelSim transcript
vlib work
vlog -sv spi_master.sv spi_slave.sv top.sv spi_if.sv tb.sv
vsim -t 1ns tb
run -all
```

---

## 8. Expected Output

A passing simulation prints the following pattern for each transaction:

```
[DRV] : RESET DONE
-----------------------------------------
[GEN] : din : 2473
[DRV] : DATA SENT TO DAC : 2473
[MON] : DATA SENT : 2473
[SCO] : DRV : 2473 MON : 2473
[SCO] : DATA MATCHED
-----------------------------------------
[GEN] : din : 891
[DRV] : DATA SENT TO DAC : 891
[MON] : DATA SENT : 891
[SCO] : DRV : 891 MON : 891
[SCO] : DATA MATCHED
-----------------------------------------
... (repeats for count transactions)
$finish called
```

`dump.vcd` should show `cs` going low for exactly 12 `sclk` cycles per transaction, `mosi` changing on each cycle, and `done` pulsing high at the end of each transfer.

---

## 9. Did We Achieve It?

**What worked:**
- The clock divider correctly generates `sclk` at `fclk / 20`
- The master FSM correctly serializes 12-bit data LSB first with proper `cs` framing
- The slave shift register correctly reconstructs the original `din` value after 12 cycles
- The layered testbench correctly catches mismatches via the scoreboard
- Synchronization between generator and scoreboard via events works cleanly

**What was not tested / limitations:**

- **No constraint on `newd`** — `newd` is randomized in the transaction class in one version, which could cause back-to-back transactions without proper spacing. The master does not have explicit protection for this.
- **`enable` and `comp` FSM states are dead code** — they are declared in the enum but never entered. If a `default` assignment routes there, behavior is undefined in terms of intent.
- **No reset during active transmission** — what happens if `rst` is asserted mid-transaction was never tested. The master resets `cs` and `mosi` but `count` and `state` in RTL are `int` types initialized at declaration, not in a reset block — this could cause issues in real synthesis.
- **Single clock domain assumption** — the testbench drives `newd` and `din` relative to `clk`, but the master FSM samples them on `sclk`. There is a subtle CDC (clock domain crossing) risk that was not formally addressed.
- **No edge cases tested** — `din = 0`, `din = 12'hFFF`, and repeated identical values were not explicitly constrained or targeted.

---

## 10. Alternate Approaches

### 1. Parameterized Data Width
The current design hardcodes 12-bit width throughout (`[11:0]`, `count <= 11`). A better approach:

```systemverilog
module spi_master #(parameter DATA_WIDTH = 12) (
    ...
    input [DATA_WIDTH-1:0] din
);
```

This makes the master reusable for 8-bit, 16-bit, or 24-bit SPI devices without modifying RTL. The testbench transaction class would also use `DATA_WIDTH` as a parameter.

### 2. UVM-based Testbench
The current testbench manually implements what UVM provides as a framework — `uvm_sequence_item` instead of `transaction`, `uvm_driver` instead of `driver`, `uvm_scoreboard` instead of scoreboard, and so on. Migrating to UVM would add:

- Built-in factory overrides for easy test configuration
- Standardized phasing (`build_phase`, `run_phase`)
- Coverage-driven verification with `uvm_covergroup`
- Reusable verification IP (VIP) structure

This is the natural next step after mastering the manual layered testbench pattern used here.

### 3. Functional Coverage
No coverage was collected in this project. Adding a `covergroup` to the transaction class would let the simulator report which input values were actually exercised:

```systemverilog
covergroup spi_cg;
    cp_din: coverpoint din {
        bins zero     = {0};
        bins max_val  = {12'hFFF};
        bins mid[]    = {[1:12'hFFE]};
    }
endgroup
```

This shifts verification from "did it run?" to "did it run enough of the right things?" — a fundamental step toward production-grade verification.

---

*Project developed as part of a structured SystemVerilog learning curriculum covering RTL design, FSM implementation, and class-based testbench architecture.*

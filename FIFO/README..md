# SystemVerilog FIFO — Verification Project

---

## 1. Overview

This project implements a synchronous, single-clock, 8-bit wide, 16-entry deep FIFO in SystemVerilog and verifies it using a layered, self-checking testbench. The DUT manages data flow through a circular buffer using write and read pointers, a 5-bit entry counter, and combinational full/empty flags. The testbench follows the generator → driver → monitor → scoreboard architecture with mailbox-based inter-component communication.

---

## 2. Goal

The primary goal was to build a complete layered testbench from scratch for a synchronous FIFO and verify two fundamental boundary conditions: that the FIFO correctly fills to capacity (full flag asserts after 16 writes) and correctly drains to empty (empty flag asserts after 16 reads), with every read value matching the corresponding written value in FIFO order. A secondary goal was to understand how the pacing event mechanism (`next`/`done`) keeps the generator and scoreboard in lockstep without race conditions.

---

## 3. Parameters

| Name    | Default Value | Description                                              |
|---------|---------------|----------------------------------------------------------|
| Width   | 8             | Bit width of each data entry (din / dout)                |
| Depth   | 16            | Number of storage slots in the FIFO memory array         |
| PtrBits | 4             | Width of wptr and rptr — must satisfy 2^PtrBits == Depth |
| CntBits | 5             | Width of entry counter — must hold values 0 through Depth |

> Note: Width, Depth, PtrBits, and CntBits are not parameterized in the RTL as written — they are hardcoded. The table above documents their effective values.

---

## 4. Interface

### DUT Ports

| Port Name | Direction | Width | Purpose                                          |
|-----------|-----------|-------|--------------------------------------------------|
| `clk`     | input     | 1     | Clock — all internal logic triggers on rising edge |
| `rst`     | input     | 1     | Synchronous active-high reset                    |
| `wr`      | input     | 1     | Write enable — push `din` into FIFO              |
| `rd`      | input     | 1     | Read enable — pop data onto `dout`               |
| `din`     | input     | 8     | Data input on the write side                     |
| `dout`    | output    | 8     | Data output on the read side (registered)        |
| `empty`   | output    | 1     | High when FIFO holds 0 entries                   |
| `full`    | output    | 1     | High when FIFO holds 16 entries                  |

### Interface Bundle (`fifo_if`)

| Signal      | Direction (TB→DUT) | Width | Purpose                            |
|-------------|-------------------|-------|------------------------------------|
| `clock`     | TB drives         | 1     | Connects to DUT `clk`              |
| `rst`       | TB drives         | 1     | Connects to DUT `rst`              |
| `wr`        | TB drives         | 1     | Connects to DUT `wr`               |
| `rd`        | TB drives         | 1     | Connects to DUT `rd`               |
| `data_in`   | TB drives         | 8     | Connects to DUT `din`              |
| `data_out`  | DUT drives        | 8     | Connects to DUT `dout`             |
| `full`      | DUT drives        | 1     | Observed by monitor and driver     |
| `empty`     | DUT drives        | 1     | Observed by monitor and driver     |

---

## 5. Design Approach

**Circular buffer via natural pointer overflow.**
Both `wptr` and `rptr` are declared as `reg [3:0]`, which means they automatically wrap from 15 back to 0 on overflow. No modulo arithmetic or explicit wrap logic is needed. This only works correctly because the depth is exactly a power of two (16).

**5-bit counter as the source of truth.**
Rather than inferring full/empty from pointer equality (a common but error-prone approach), the design uses a dedicated 5-bit counter `cnt`. This makes the full/empty conditions unambiguous (`cnt == 16`, `cnt == 0`) and avoids the classic ambiguity where `wptr == rptr` could mean either empty or full.

**Combinational status flags.**
`empty` and `full` are driven by continuous `assign` statements rather than being registered. This means they update in the same simulation timestep that `cnt` changes, with no one-cycle lag. This matters for the testbench — the driver's guard conditions (`!full`, `!empty`) reflect the true DUT state before the next clock edge.

**Mutually exclusive operations with write priority.**
The `always` block uses `if / else if / else if` chaining, which means simultaneous assertion of `wr` and `rd` is handled by write winning. This is a deliberate and documented simplification — the testbench never asserts both simultaneously, so this limitation is safe for this verification scope.

**Synchronous reset only.**
Reset is checked inside `always @(posedge clk)`, meaning it only takes effect on a rising clock edge. There is no asynchronous path. This keeps the design simple and avoids the reset synchronizer complexity that asynchronous reset deassertion would require.

---

## 6. Testbench Strategy

**Architecture.**
Four-component layered testbench: generator, driver, monitor, scoreboard. Two typed mailboxes (`gdmbx`, `msmbx`) carry `transaction` objects between components. A shared `next` event paces the generator — it does not fire the next transaction until the scoreboard confirms the previous one was checked.

**Test scenario — Fill then Drain.**
Rather than randomizing the operation mix, this test runs two explicit deterministic phases to target the boundary conditions directly:

| Phase   | Transactions | What is verified                              |
|---------|--------------|-----------------------------------------------|
| Write   | 16           | All 16 slots fill; `full` asserts on the 16th |
| Read    | 16           | All 16 entries drain; `empty` asserts on 16th; each `dout` matches the corresponding `din` in FIFO order |

**Stimulus generation.**
The generator creates a new `transaction` object per iteration, sets `oper = 1` (write) or `oper = 0` (read), and for writes assigns `data_in = $urandom_range(1, 255)`. The value 0 is excluded to make mismatches visually obvious in simulation logs.

**Driver timing — 3-edge protocol.**
Each write and read operation consumes exactly 3 clock edges: assert the control signal, allow the DUT to respond on the next rising edge, then deassert and hold for one settling cycle. This gives the monitor a stable window to sample all signals cleanly.

**Monitor sampling.**
The monitor skips 2 clock edges (aligning to when `wr`/`rd`/`data_in`/`full`/`empty` are stable), then samples one more edge later to capture `dout` (which is registered and valid one cycle after `rd` is asserted).

**Scoreboard reference model.**
A SystemVerilog queue `din[$]` mirrors the DUT's internal contents. Writes push to the front (`push_front`); reads pop from the back (`pop_back`). This gives FIFO ordering without any explicit index tracking. On each read, the popped value is compared against `tr.data_out` using `==`.

---

## 7. How to Simulate

### Icarus Verilog

```bash
# Compile
iverilog -g2012 -o fifo_sim design.sv testbench.sv

# Run
vvp fifo_sim

# View waveform (requires GTKWave)
gtkwave dump.vcd
```

### ModelSim / QuestaSim

```tcl
# In ModelSim console
vlib work
vlog design.sv testbench.sv
vsim tb
run -all
```

### EDA Playground

1. Paste `design.sv` into the **Design** tab
2. Paste `testbench.sv` into the **Testbench** tab
3. Select **Cadence Xcelium** or **Synopsys VCS**
4. Check **Open EPWave after run** for waveform viewing
5. Click **Run**

---

## 8. Expected Output

A passing simulation produces output in this pattern:

```
[DRV] : DUT Reset Done
------------------------------------------
[GEN] : WRITE transaction 1 | data : 42
[DRV] : DATA WRITE  data : 42
[MON] : Wr:1 rd:0 din:42  dout:0  full:0 empty:1
[SCO] : DATA STORED IN QUEUE : 42
--------------------------------------
...
[GEN] : WRITE transaction 16 | data : 17
[DRV] : DATA WRITE  data : 17
[MON] : Wr:1 rd:0 din:17  dout:0  full:1 empty:0
[SCO] : DATA STORED IN QUEUE : 17
--------------------------------------
[GEN] : READ transaction 17
[DRV] : DATA READ
[MON] : Wr:0 rd:1 din:0  dout:42 full:1 empty:0
[SCO] : DATA MATCH — expected 42 got 42
--------------------------------------
...
[GEN] : READ transaction 32
[DRV] : DATA READ
[MON] : Wr:0 rd:1 din:0  dout:17 full:0 empty:1
[SCO] : DATA MATCH — expected 17 got 17
--------------------------------------
=============================================
Total Error Count : 0
RESULT : ALL 16 WRITES AND 16 READS PASSED
=============================================
```

Key indicators of a passing run:
- `full:1` appears on the monitor line for the 16th write
- `empty:1` appears on the monitor line for the 16th read
- Every `[SCO]` line in the read phase prints `DATA MATCH`
- `Total Error Count : 0`

---

## 9. Did We Achieve It?

**What worked.**
The fill-and-drain scenario executed correctly. All 16 write transactions were accepted by the DUT, the full flag asserted exactly on the 16th write, all 16 read transactions returned data in FIFO order, and the scoreboard confirmed zero mismatches. The pacing mechanism (`next` event) worked correctly — the generator never outran the scoreboard.

**What was not tested.**
- **Simultaneous wr and rd** — the DUT's write-wins behavior when both are asserted in the same cycle was never exercised because the testbench never generates this condition
- **Write to a full FIFO** — a 17th write attempt after full asserts was not sent; the guard `!full` inside the driver silently prevents it rather than logging it as a detected boundary
- **Read from an empty FIFO** — symmetrically, reading past empty was not tested
- **Back-to-back writes with no clock gap** — the driver inserts a deassert cycle between every transaction; sustained single-cycle throughput was never driven
- **Reset mid-operation** — asserting reset while a write or read is in progress was not covered

**Surprises.**
The most subtle issue encountered during development was that `write()` originally used `$urandom_range` locally inside the driver, which meant the scoreboard received the data value from the monitor (sampled from the interface) while the driver had already moved to the next cycle. Switching to `datac.data_in` — where the generator assigns the value and the driver uses it directly — made the write value consistent across all components.

**Honest assessment.**
This testbench verifies the happy path thoroughly. It does not constitute a complete verification of the FIFO — corner cases around boundary conditions, simultaneous control signals, and reset behavior remain untested. It is a solid functional baseline, not a sign-off quality verification.

---

## 10. Alternate Approaches

**1. Constrained-random operation mix instead of fixed phases.**
Rather than 16 writes followed by 16 reads, the generator could randomize `oper` with a weighted distribution (e.g., 70% write early, shifting to 70% read later) and run hundreds of transactions. This would exercise the full/empty boundary conditions organically through random stimulus rather than by construction, and would catch interaction bugs that deterministic sequencing misses. The scoreboard's queue model already supports this without modification — only the generator changes.

**2. Modport-based interface with separate driver and monitor modports.**
The current `fifo_if` has no modports — every signal is accessible to every component with no direction enforcement. Adding modports (`modport drv_mp` with all inputs as `output`, all outputs as `input`; `modport mon_mp` with everything as `input`) would let the simulator enforce at compile time that the monitor never accidentally drives a signal. This is closer to production testbench practice and eliminates an entire class of potential bugs.

**3. Parameterized DUT with matching testbench.**
The current FIFO hardcodes depth=16 and width=8. Wrapping the module in `parameter` declarations and threading those parameters through the testbench (pointer width, counter width, memory size) would make the design reusable for any power-of-two depth and any data width. The testbench generator would then drive `2**DEPTH_BITS` writes instead of the hardcoded 16, making the fill/drain test automatically correct for any configuration.

# FIFO Verification — SystemVerilog Testbench

## Overview

This project implements a **self-checking layered testbench** for a synchronous 8-bit wide, 16-entry deep FIFO in SystemVerilog. The testbench follows the 4-component architecture — generator, driver, monitor, scoreboard — communicating through typed mailboxes.

---

## DUT Specification

| Parameter     | Value                        |
|---------------|------------------------------|
| Type          | Synchronous, single-clock    |
| Width         | 8 bits                       |
| Depth         | 16 entries                   |
| Reset         | Synchronous, active-high     |
| Simultaneous  | wr + rd not supported        |
| Priority      | reset > write > read         |

### Ports

| Port       | Direction | Width | Description                        |
|------------|-----------|-------|------------------------------------|
| `clk`      | input     | 1     | Rising-edge triggered clock        |
| `rst`      | input     | 1     | Synchronous active-high reset      |
| `wr`       | input     | 1     | Write enable                       |
| `rd`       | input     | 1     | Read enable                        |
| `din`      | input     | 8     | Data input (write side)            |
| `dout`     | output    | 8     | Data output (read side)            |
| `empty`    | output    | 1     | High when FIFO holds 0 entries     |
| `full`     | output    | 1     | High when FIFO holds 16 entries    |

---

## Internal Architecture

```
wptr [3:0]  — write pointer, wraps 15→0 via 4-bit overflow
rptr [3:0]  — read pointer,  wraps 15→0 via 4-bit overflow
cnt  [4:0]  — entry counter, range 0–16 (needs 5 bits)
mem  [7:0][15:0] — 16-slot storage array
```

`empty` and `full` are **combinational** — they update the same cycle `cnt` changes with no added latency.

---

## Testbench Architecture

```
┌───────────┐   mailbox (gdmbx)   ┌────────┐   virtual if   ┌─────┐
│ generator │ ──────────────────► │ driver │ ─────────────► │ DUT │
└───────────┘                     └────────┘                 └─────┘
      ▲                                                          │
      │ @(next)                                           virtual if
      │                                                          │
┌────────────┐  mailbox (msmbx)  ┌─────────┐                   ▼
│ scoreboard │ ◄───────────────── │ monitor │ ◄─────────────────┘
└────────────┘                    └─────────┘
```

### Mailboxes

| Mailbox  | From      | To         | Carries     |
|----------|-----------|------------|-------------|
| `gdmbx`  | generator | driver     | transaction |
| `msmbx`  | monitor   | scoreboard | transaction |

### Pacing Event

| Event    | Triggered by | Waited on by | Purpose                              |
|----------|--------------|--------------|--------------------------------------|
| `next`   | scoreboard   | generator    | Prevents generator from outrunning scoreboard |
| `done`   | generator    | environment  | Signals all iterations complete      |

---

## Component Descriptions

### transaction
Data carrier passed between all components. Generator sets `oper`; monitor fills the rest.

| Field      | Type      | Set by    | Description                    |
|------------|-----------|-----------|--------------------------------|
| `oper`     | bit       | generator | 1 = write, 0 = read            |
| `wr`       | bit       | monitor   | Write signal sampled from interface |
| `rd`       | bit       | monitor   | Read signal sampled from interface  |
| `data_in`  | bit [7:0] | generator | Payload to write                |
| `data_out` | bit [7:0] | monitor   | Data read from DUT              |
| `full`     | bit       | monitor   | Full flag at time of transaction |
| `empty`    | bit       | monitor   | Empty flag at time of transaction |

---

### generator
Controls the test sequence. In the fill/drain variant it runs two fixed phases:

```
Phase 1 — 16 writes   →  FIFO should be FULL  (full == 1)
Phase 2 — 16 reads    →  FIFO should be EMPTY (empty == 1)
```

After each `mbx.put()` it waits on `@(next)` so the scoreboard finishes checking before the next transaction is fired.

---

### driver
Translates transactions into timed signal activity on the interface.

**reset** — holds `rst` high for 5 clock cycles, then deasserts.

**write() — 3-edge timing:**
```
Edge 1 : assert wr, place data_in on interface
Edge 2 : DUT latches data on rising edge
Edge 3 : deassert wr, settling cycle
```

**read() — 3-edge timing:**
```
Edge 1 : assert rd
Edge 2 : DUT drives dout on rising edge
Edge 3 : deassert rd, dout stable for monitor
```

> Note: `write()` uses `datac.data_in` from the transaction — not a local `$urandom_range` — so the scoreboard and driver always agree on what was written.

---

### monitor
Passive observer — never drives any signal.

Sampling is aligned to the driver's 3-edge pattern:
```
skip 2 edges → sample wr, rd, data_in, full, empty
skip 1 more  → sample data_out (valid one cycle after rd)
```

---

### scoreboard
Maintains a **reference queue** `din[$]` that mirrors what the DUT holds internally.

| Operation | Action                                      |
|-----------|---------------------------------------------|
| Write     | `din.push_front(tr.data_in)` if not full    |
| Read      | `temp = din.pop_back()` then compare with `tr.data_out` |

`push_front` + `pop_back` gives FIFO ordering — the oldest entry is always at the back of the queue.

After every check, scoreboard triggers `-> next` to unblock the generator.

---

### environment
Wiring layer — constructs all components, connects mailboxes, shares the virtual interface and the `next` event.

Three phases:
```
pre_test  — drv.reset()
test      — fork gen/drv/mon/sco join_any
post_test — wait(gen.done) → print errors → $finish
```

`join_any` kills the forever-running driver, monitor, and scoreboard as soon as the generator's `repeat` loops complete.

---

## Test Scenario — Fill and Drain

```
1.  DUT reset (5 cycles)
2.  Write 16 entries  →  verify full flag asserts after 16th write
3.  Read  16 entries  →  verify data matches and empty flag asserts after 16th read
4.  Report total error count
```

Expected terminal output pattern:
```
[GEN] : Starting WRITE Phase — 16 writes
[DRV] : DATA WRITE  data : 42
[MON] : Wr:1 rd:0 din:42  dout:0  full:0 empty:1
[SCO] : DATA STORED IN QUEUE : 42
...
[MON] : Wr:1 rd:0 din:17  dout:0  full:1 empty:0   ← full asserted
[GEN] : Starting READ Phase — 16 reads
[MON] : Wr:0 rd:1 din:0   dout:42 full:1 empty:0
[SCO] : DATA MATCH — expected 42 got 42
...
[MON] : Wr:0 rd:1 din:0   dout:17 full:0 empty:1   ← empty asserted
Total Error Count : 0
RESULT : ALL 16 WRITES AND 16 READS PASSED
```

---

## File Structure

```
fifo_tb/
├── design.sv      — FIFO module + fifo_if interface
└── testbench.sv   — transaction, generator, driver,
                     monitor, scoreboard, environment, tb
```

---

## Clock and Timing

```
always #10 fif.clock <= ~fif.clock;
```

| Parameter   | Value  |
|-------------|--------|
| Half period | 10 ns  |
| Full period | 20 ns  |
| Frequency   | 50 MHz |

---

## Known Limitations

- Simultaneous `wr` and `rd` in the same cycle is not supported by the DUT — write takes priority via `else if` chaining
- `dout` is not cleared on reset — it holds its last value; this is safe because `empty` prevents reads until valid data exists
- `data_in` range in this test is `$urandom_range(1, 255)` — value `0` excluded to make mismatches visually obvious in logs

---

## How to Run (EDA Playground)

1. Paste `design.sv` content into the **Design** tab
2. Paste `testbench.sv` content into the **Testbench** tab
3. Select **Cadence Xcelium** or **Synopsys VCS**
4. Enable `$dumpfile` / `$dumpvars` for waveform viewing
5. Click **Run**

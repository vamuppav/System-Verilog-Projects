# UART — Universal Asynchronous Receiver-Transmitter in SystemVerilog

---

## 1. Overview

This project implements a full-duplex UART in SystemVerilog, comprising a transmitter (`uarttx`) and a receiver (`uartrx`) integrated under a common top-level wrapper (`uart_top`). The transmitter serializes an 8-bit parallel byte onto the `tx` line using a standard UART frame, and the receiver deserializes incoming bits on the `rx` line back into an 8-bit parallel byte. Both submodules derive their baud-rate clock internally by dividing the system clock, making the design parameterizable for any clock frequency and baud rate combination.

---

## 2. Goal

The goal of this project was to understand how a real serial communication protocol is implemented at the RTL level — specifically how a single clock system drives time-sensitive bit-level operations through clock division and FSM-based control. On the verification side, the objective was to build a layered, class-based testbench following the generator → driver → monitor → scoreboard pattern, apply it to a protocol DUT for the first time, and understand how to synchronize a testbench with a DUT that has internal clocks not directly visible at the top-level ports.

---

## 3. Parameters

| Name        | Default Value | Description                                                                 |
|-------------|---------------|-----------------------------------------------------------------------------|
| `clk_freq`  | `1000000`     | System clock frequency in Hz. Used to compute the baud-rate clock divisor. |
| `baud_rate` | `9600`        | Target UART baud rate in bits per second.                                   |

> Both parameters are passed identically to `uarttx` and `uartrx` so both submodules operate at the same baud rate.

---

## 4. Interface

### `uart_top` Ports

| Port Name | Direction | Width  | Purpose                                                        |
|-----------|-----------|--------|----------------------------------------------------------------|
| `clk`     | input     | 1      | System clock input                                             |
| `rst`     | input     | 1      | Synchronous active-high reset                                  |
| `rx`      | input     | 1      | Serial receive line — incoming bits from external device       |
| `dintx`   | input     | 8      | Parallel byte to transmit over UART                            |
| `newd`    | input     | 1      | Pulse high for one cycle to trigger a new transmission         |
| `tx`      | output    | 1      | Serial transmit line — outgoing bits to external device        |
| `doutrx`  | output    | 8      | Parallel byte assembled from received serial bits              |
| `donetx`  | output    | 1      | Pulses high for one baud cycle when transmission completes     |
| `donerx`  | output    | 1      | Pulses high for one baud cycle when a full byte is received    |

### `uart_if` Interface Signals

| Signal    | Width | Purpose                                                              |
|-----------|-------|----------------------------------------------------------------------|
| `clk`     | 1     | System clock driven by testbench                                     |
| `uclktx`  | 1     | Internal baud clock of `uarttx` — tapped via `assign` in `tb`       |
| `uclkrx`  | 1     | Internal baud clock of `uartrx` — tapped via `assign` in `tb`       |
| `rst`     | 1     | Reset signal                                                         |
| `rx`      | 1     | Serial input line driven by driver during RX transactions            |
| `dintx`   | 8     | Parallel TX data                                                     |
| `newd`    | 1     | TX trigger                                                           |
| `tx`      | 1     | Serial output observed by monitor                                    |
| `doutrx`  | 8     | Parallel RX output observed by monitor                               |
| `donetx`  | 1     | TX completion flag                                                   |
| `donerx`  | 1     | RX completion flag                                                   |

---

## 5. Design Approach

**Baud clock generation by division.**
Rather than requiring an external baud clock, both `uarttx` and `uartrx` generate their own internal `uclk` by counting system clock edges and toggling at `clkcount/2`. This keeps the design self-contained and directly parameterizable. The tradeoff is that both submodules run independent counters — there is no shared baud clock, which is fine for simulation but worth noting for silicon.

**FSM-based serial control.**
Both submodules use a simple 2-state FSM (`idle` → `transfer`/`start` → back to `idle`) clocked on `uclk`. This is the natural fit for UART: the FSM idles until triggered, counts bits, then returns to idle. The `done` flags are asserted on the final FSM transition, giving the testbench a clean handshake signal to wait on.

**No start-bit sampling delay on the receiver.**
The receiver transitions to the `start` state immediately on detecting `rx = 0` and begins sampling on the very next `uclk` edge. Ideally, a robust receiver should sample at the center of each bit period rather than at the edge. This was a deliberate simplification for learning purposes, and it works in simulation because the transmitter and receiver share the same clock source and run at exactly the same baud rate.

**LSB-first transmission, MSB-first reception.**
The transmitter shifts out `din[counts]` starting from bit 0 (LSB-first), which is the UART standard. The receiver shifts in using `{rx, rxdata[7:1]}`, which inserts each new bit at the MSB and shifts existing bits right — this correctly reassembles the byte because the first bit received (LSB) ends up at position 0 after 8 shifts.

---

## 6. Testbench Strategy

**Layered architecture.**
The testbench follows the generator → driver → monitor → scoreboard pattern with mailbox-based communication between layers. The generator randomizes transactions using `randc` on the operation type, ensuring it alternates between TX and RX operations without repeating the same direction consecutively.

**Two operation types tested.**

- **Write (TX path):** The driver asserts `newd`, drives `dintx` with the transaction data, then waits for `donetx`. The monitor independently samples the `tx` line bit-by-bit and reconstructs the byte. The scoreboard compares what the driver sent against what the monitor observed on the wire.

- **Read (RX path):** The driver asserts a start bit on `rx`, then drives 8 random bits serially on `rx` at `uclkrx` rate, capturing each bit as it drives. The monitor waits for `donerx` and captures `doutrx`. The scoreboard compares what the driver drove against what the DUT output.

**Internal clock tapping.**
Because `uclk` is internal to each submodule and not exposed at the top-level ports, the testbench uses `assign` statements to tap them directly:
```systemverilog
assign vif.uclktx = dut.utx.uclk;
assign vif.uclkrx = dut.rtx.uclk;
```
This is necessary because the driver and monitor must synchronize to the baud clock, not the system clock, to correctly time bit-level stimulus and sampling.

**Synchronization.**
Generator-driver synchronization uses the `drvnext` event. Generator-scoreboard synchronization uses the `sconext` event. Both are triggered after each transaction completes so the generator never sends a new transaction before the previous one is fully checked.

---

## 7. How to Simulate

### ModelSim
```bash
vlog uart_top.sv tb.sv
vsim -c tb -do "run -all; quit"
```

### Icarus Verilog
```bash
iverilog -g2012 -o uart_sim uart_top.sv tb.sv
vvp uart_sim
```

### View Waveforms (GTKWave)
```bash
gtkwave dump.vcd
```

> Set `env.gen.count` in `tb` to control how many transactions are run. Default is 5.

---

## 8. Expected Output

A passing simulation produces alternating TX and RX transactions. Each transaction prints a generator line, a driver line, a monitor line, and a scoreboard comparison. A clean run looks like:

```
[DRV] : RESET DONE
----------------------------------------
[GEN] : Oper : write  Din : 147
[DRV] : Data Sent : 147
[MON] : DATA SEND on UART TX 147
[SCO] : DRV : 147  MON : 147
DATA MATCHED
----------------------------------------
[GEN] : Oper : read  Din : 0
[DRV] : Data RCVD : 83
[MON] : DATA RCVD RX 83
[SCO] : DRV : 83  MON : 83
DATA MATCHED
----------------------------------------
```

No `DATA MISMATCHED` lines should appear. Simulation ends with `$finish` after all `count` transactions complete.

---

## 9. Did We Achieve It?

**What worked:**
The core TX path works correctly end-to-end. The driver sends a byte, the monitor independently reconstructs it from the serial `tx` line, and the scoreboard consistently confirms a match. The baud clock generation and FSM transitions are clean and the `donetx`/`donerx` handshake signals give the testbench reliable synchronization points.

**What has limitations:**

- **No center-of-bit sampling on the receiver.** The receiver samples `rx` at the first `uclk` edge after the start bit, not at the midpoint of each bit period. In a real system where the transmitter and receiver clocks are not perfectly aligned, this would cause bit errors. It works here only because both sides share the same clock source in simulation.

- **No stop bit verification.** The transmitter drives a stop bit (`tx = 1`) after the 8 data bits, but the receiver does not check for it. A framing error condition — where the stop bit is missing or corrupted — is silently ignored.

- **No parity support.** Standard UART implementations often include an optional parity bit. This design has none, so single-bit error detection is not available.

- **RX stimulus is synthetic, not looped back.** The driver constructs the RX serial stream manually bit by bit rather than routing the DUT's own `tx` output back to `rx`. A true loopback test would be a stronger correctness check.

- **Only 5 transactions by default.** The count is low enough that not all corner cases (e.g., back-to-back transactions, maximum value `8'hFF`, minimum value `8'h00`) are guaranteed to appear in any given run.

---

## 10. Alternate Approaches

**1. True loopback testbench.**
Instead of driving `rx` manually in the driver, connect `tx` directly back to `rx` at the testbench level. Send a byte through `uarttx` and verify that `uartrx` recovers the same byte from `doutrx`. This removes the need for the driver to manually serialize bits and produces a much stronger end-to-end correctness check. The tradeoff is that it only tests the TX→RX round trip and cannot independently stress the RX path with arbitrary bit patterns.

**2. Center-of-bit sampling with a 16x oversampled clock.**
A production-grade UART receiver generates a clock at 16x the baud rate and samples `rx` at the 8th tick after the start bit edge is detected — the midpoint of each bit period. This makes the receiver tolerant of clock frequency mismatch between sender and receiver (typically up to ±4%). Implementing this would be the natural next step to make this design synthesizable and robust for real hardware deployment.

**3. UVM-based testbench.**
The layered class-based testbench used here is structurally very close to UVM. Migrating to UVM would replace the hand-written mailboxes and events with `uvm_tlm_fifo`, replace the environment class with `uvm_env`, and add a proper `uvm_sequencer`/`uvm_driver` pair. This would be the natural progression after mastering the manual layered pattern.

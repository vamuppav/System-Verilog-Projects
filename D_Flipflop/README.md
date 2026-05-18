# D Flip-Flop Verification using SystemVerilog

A SystemVerilog testbench implementing a layered, self-checking verification environment for a D Flip-Flop (DFF). The design follows standard UVM-inspired component separation — without using the UVM library — making it beginner-friendly while reflecting real industry verification practices.

---

## What is a D Flip-Flop?

A D Flip-Flop is a fundamental 1-bit memory element. It captures its input (`din`) on every rising clock edge and holds it as output (`dout`) until the next rising edge. Although simple, it is an ideal starting point for learning structured testbench design.

---

## Testbench Architecture

The testbench follows a layered architecture where each component has a single, well-defined responsibility. Data flows through the environment in one direction, with mailboxes acting as synchronised queues between components.

```
┌─────────────┐     mbx      ┌─────────────┐
│  Generator  │ ──────────► │   Driver    │
│             │              └──────┬──────┘
│             │  mbxref             │ vif
│             │ ──────────►  ┌──────▼──────┐
└─────────────┘              │     DUT     │  (dff module)
       ▲                     └──────┬──────┘
       │ sconext                    │ vif
       │                    ┌──────▼──────┐
┌──────┴──────┐     mbx     │   Monitor   │
│ Scoreboard  │ ◄────────── │             │
└─────────────┘             └─────────────┘
```

- The **Generator** creates randomised transactions and sends copies to both the Driver and the Scoreboard
- The **Driver** receives transactions and applies `din` to the DUT through the virtual interface
- The **DUT** (the actual flip-flop) responds to the driven inputs
- The **Monitor** passively observes the DUT output and forwards it to the Scoreboard
- The **Scoreboard** compares actual output against the Generator's reference and reports pass or fail
- The **Environment** instantiates and connects every component together

The Generator and Scoreboard stay in sync using a shared event (`sconext`), so the Generator only sends the next transaction after the Scoreboard finishes checking the current one.

---

## Component Breakdown

| Component | Role |
|---|---|
| `transaction` | A data object holding `din` and `dout`. Declared with `rand` for automatic randomisation. Includes `copy()` and `display()` helper functions. |
| `generator` | Creates `count` randomised transactions. Sends a copy to the Driver (to drive the DUT) and another to the Scoreboard (as golden reference). Waits for Scoreboard acknowledgement after each transaction. |
| `driver` | Receives transactions from the Generator and applies `din` to the DUT via the virtual interface. Also handles the initial reset sequence before the test begins. |
| `monitor` | Passively observes DUT output signals through the virtual interface. Samples `dout` after every 2 clock edges and forwards it to the Scoreboard. Does not interact with the DUT. |
| `scoreboard` | Receives actual output from the Monitor and the expected input from the Generator. Compares them and prints `DATA MATCHED` or `DATA MISMATCHED`. Triggers `sconext` to unblock the Generator after each check. |
| `environment` | Top-level container. Creates all mailboxes, instantiates all components, connects interfaces and events, and runs `pre_test → test → post_test` in sequence. |

---

## Key Concepts Demonstrated

- **Transaction-Level Modeling (TLM)** — stimulus and response are packaged as objects rather than raw signal assignments
- **Mailbox-based communication** — components are fully decoupled and communicate only through typed mailboxes (`mailbox #(transaction)`)
- **Virtual interfaces** — the testbench references DUT signals through a `virtual dff_if`, keeping the verification environment reusable
- **Constrained random verification** — `rand` + `randomize()` automatically generates a wide range of input patterns without manual effort
- **Self-checking scoreboard** — the testbench automatically determines pass/fail without any manual waveform inspection
- **Event synchronisation** — the `sconext` event enforces ordered, one-at-a-time checking between the Generator and Scoreboard
- **`fork-join_any` parallelism** — all four components run concurrently, mirroring how real hardware operates simultaneously

---

## File Structure

```
├── dff.sv          # DUT — D Flip-Flop module and interface
└── tb.sv           # Testbench — all verification components and top module
```

---

## How to Run

1. Compile the DUT (`dff`) and interface (`dff_if`) files
2. Compile the testbench files in order: `transaction → generator → driver → monitor → scoreboard → environment → tb`
3. Run the simulation — the testbench will apply 30 randomised transactions and report results in the console
4. Optionally open `dump.vcd` in a waveform viewer to inspect signal-level behaviour

---

## Sample Console Output

```
[GEN] : DIN : 1 DOUT : 0
[DRV] : DIN : 1 DOUT : 0
[MON] : DIN : 0 DOUT : 1
[SCO] : DIN : 0 DOUT : 1
[REF] : DIN : 1 DOUT : 0
[SCO] : DATA MATCHED
-------------------------------------------------
```

---

## Concepts to Explore Next

- Add functional coverage using `covergroup` and `coverpoint`
- Constrain `din` with `constraint` blocks for directed random testing
- Extend the environment to verify a more complex sequential design (e.g. shift register, counter)
- Migrate the environment to UVM using `uvm_component`, `uvm_sequence`, and `uvm_driver`

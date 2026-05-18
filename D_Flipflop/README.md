D Flip-Flop Verification using SystemVerilog
A SystemVerilog testbench implementing a layered, self-checking verification environment for a D Flip-Flop (DFF). The design follows standard UVM-inspired component separation — without using the UVM library — making it beginner-friendly while reflecting industry verification practices.

Overview
A D Flip-Flop is a fundamental 1-bit memory element that captures its input (din) on every rising clock edge and holds it as output (dout). Although simple, it serves as an ideal starting point to learn how a structured testbench is built and how each component communicates.

Testbench Architecture
The testbench follows a layered architecture where each component has a single, well-defined responsibility. Data flows through the environment in one direction, connected by mailboxes which act as synchronised queues between components.
The flow looks like this:

The Generator creates randomised transactions and sends copies to both the Driver and the Scoreboard
The Driver receives those transactions and applies them to the DUT through the virtual interface
The DUT (the actual flip-flop) responds to the driven inputs
The Monitor silently observes the DUT's output and forwards what it sees to the Scoreboard
The Scoreboard compares the DUT's actual output against the Generator's reference copy and reports pass or fail
The Environment sits above all of this, instantiating and connecting every component together

The Generator and Scoreboard are kept in sync using a shared event (sconext), so the Generator only sends the next transaction after the Scoreboard finishes checking the current one.

Component Breakdown
ComponentRoleTransactionA data object holding din and dout. Declared with rand so inputs can be randomised. Also contains copy() and display() helper functions.GeneratorCreates count randomised transactions. Sends a copy to the Driver (to drive the DUT) and another to the Scoreboard (as golden reference). Waits for Scoreboard acknowledgement after each transaction.DriverReceives transactions from the Generator and applies din to the DUT via the virtual interface. Also handles the initial reset sequence before the test begins.MonitorPassively observes the DUT's output signals through the virtual interface. Samples dout after every 2 clock edges and forwards it to the Scoreboard. Does not interact with the DUT.ScoreboardReceives actual output from the Monitor and expected input from the Generator. Compares them and prints DATA MATCHED or DATA MISMATCHED. Triggers sconext to unblock the Generator after each check.EnvironmentThe top-level container. Creates all mailboxes, instantiates all components, connects interfaces and events, and runs pre_test → test → post_test in sequence.

Key Concepts Demonstrated

Transaction-Level Modeling (TLM) — stimulus and response are packaged as objects rather than raw signal assignments
Mailbox-based communication — components are fully decoupled and communicate only through typed mailboxes (mailbox #(transaction))
Virtual interfaces — the testbench references DUT signals through a virtual dff_if, keeping the verification environment reusable
Constrained random verification — rand + randomize() automatically generates a wide range of input patterns without manual effort
Self-checking scoreboard — the testbench automatically determines pass/fail without any manual waveform inspection
Event synchronisation — the sconext event enforces ordered, one-at-a-time checking between the Generator and Scoreboard
fork-join_any parallelism — all four components run concurrently, mirroring how real hardware operates simultaneously


How to Run

Compile the DUT (dff) and interface (dff_if) files
Compile the testbench files (transaction, generator, driver, monitor, scoreboard, environment, tb)
Run the simulation — the testbench will automatically apply 30 randomised transactions and report results in the console
Optionally open dump.vcd in a waveform viewer to inspect signal-level behavi

`timescale 1ns / 1ps

// =============================================================================
// Module: i2c_Slave
// Description:
//   I2C Slave controller implemented in SystemVerilog.
//   Responds to both read and write requests from an I2C master at 100 kHz.
//   Contains an internal 128-byte memory array initialized to mem[i] = i.
//   Uses a 4-phase pulse generator (synchronized to master timing) and an FSM
//   to sequence through address reception, acknowledgement, and data transfer.
//
// Ports:
//   scl     - Serial clock input driven by master
//   clk     - System clock (40 MHz)
//   rst     - Synchronous active-high reset
//   sda     - Bidirectional serial data line (open-drain)
//   ack_err - High if master sent NACK unexpectedly during read operation
//   done    - Pulses high for one cycle when transaction completes
// =============================================================================

module i2c_Slave(
    input      scl, clk, rst,
    inout      sda,
    output reg ack_err, done
);

// -----------------------------------------------------------------------------
// FSM State Encoding
// idle        : waiting for START condition (SCL high, SDA falling)
// wait_p      : aligns slave pulse counter to master before reading address
// read_addr   : shifts in 8-bit address frame {addr[6:0], op} from master
// send_ack1   : slave pulls SDA low to ACK the address frame
// send_data   : slave shifts out 8-bit data byte to master (read operation)
// master_ack  : slave checks NACK/ACK sent by master after send_data
// read_data   : slave shifts in 8-bit data byte from master (write operation)
// send_ack2   : slave pulls SDA low to ACK the received data byte
// detect_stop : waits for STOP condition before returning to idle
// -----------------------------------------------------------------------------
typedef enum logic [3:0] {
    idle        = 0,
    read_addr   = 1,
    send_ack1   = 2,
    send_data   = 3,
    master_ack  = 4,
    read_data   = 5,
    send_ack2   = 6,
    wait_p      = 7,
    detect_stop = 8
} state_type;

state_type state = idle;

// -----------------------------------------------------------------------------
// Internal 128-byte memory
// Initialized to mem[i] = i on reset.
// r_mem=1 triggers a read  : dout <= mem[addr]
// w_mem=1 triggers a write : mem[addr] <= din
// -----------------------------------------------------------------------------
reg [7:0] mem [128];
reg [7:0] r_addr;
reg [6:0] addr;
reg       r_mem = 0;
reg       w_mem = 0;
reg [7:0] dout;
reg [7:0] din;

reg sda_t;
reg sda_en;
reg [3:0] bitcnt = 0;

// -----------------------------------------------------------------------------
// Memory Controller
// Handles reset initialization, read, and write to internal memory.
// Runs on system clock so memory updates are synchronous.
// -----------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        for (int i = 0; i < 128; i++)
            mem[i] = i;
        dout <= 8'h0;
    end
    else if (r_mem == 1'b1)
        dout <= mem[addr];
    else if (w_mem == 1'b1)
        mem[addr] <= din;
end

// -----------------------------------------------------------------------------
// Clock frequency parameters
// sys_freq  : system clock frequency (40 MHz)
// i2c_freq  : target I2C SCL frequency (100 kHz)
// clk_count4: system clock cycles per full SCL period (400 cycles)
// clk_count1: system clock cycles per quarter SCL period (100 cycles)
// -----------------------------------------------------------------------------
parameter sys_freq   = 40000000;
parameter i2c_freq   = 100000;

parameter clk_count4 = (sys_freq / i2c_freq);
parameter clk_count1 = clk_count4 / 4;

integer count1  = 0;
reg     i2c_clk = 0;

// -----------------------------------------------------------------------------
// 4-Phase Pulse Generator
// Mirrors the master's pulse generator so slave FSM uses the same phase
// references (0,1,2,3) to time SDA transitions and sampling points.
// When idle (busy=0), pulse and count1 are pre-loaded to (2, 202) so that
// after START detection the slave is already aligned to the master's phase.
// -----------------------------------------------------------------------------
reg [1:0] pulse = 0;
reg       busy;

always @(posedge clk) begin
    if (rst) begin
        pulse  <= 0;
        count1 <= 0;
    end
    else if (busy == 1'b0) begin
        pulse  <= 2;
        count1 <= 202;
    end
    else if (count1 == clk_count1 - 1) begin
        pulse  <= 1;
        count1 <= count1 + 1;
    end
    else if (count1 == clk_count1*2 - 1) begin
        pulse  <= 2;
        count1 <= count1 + 1;
    end
    else if (count1 == clk_count1*3 - 1) begin
        pulse  <= 3;
        count1 <= count1 + 1;
    end
    else if (count1 == clk_count1*4 - 1) begin
        pulse  <= 0;
        count1 <= 0;
    end
    else begin
        count1 <= count1 + 1;
    end
end

// -----------------------------------------------------------------------------
// START Condition Detector
// In I2C, START = SDA falls while SCL is high.
// scl_t holds the previous SCL value; comparing ~scl & scl_t detects
// a falling edge on SCL — but since SDA falls while SCL stays high,
// this detects the moment SCL goes low after the START, signalling
// the slave to begin receiving the address frame.
// -----------------------------------------------------------------------------
reg  scl_t;
wire start;

always @(posedge clk)
    scl_t <= scl;

assign start = ~scl & scl_t;

reg r_ack;

// -----------------------------------------------------------------------------
// Main FSM
// Sequences through I2C slave protocol states on every rising system clock edge.
// SDA sampling always occurs at count1==200 (midpoint of SCL high period)
// to avoid metastability at edges.
// SDA driving always occurs at pulse 0/1 (SCL low period) per I2C spec.
// -----------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        bitcnt  <= 0;
        state   <= idle;
        r_addr  <= 7'b0000000;
        sda_en  <= 1'b0;
        sda_t   <= 1'b0;
        addr    <= 0;
        r_mem   <= 0;
        din     <= 8'h00;
        ack_err <= 0;
        done    <= 1'b0;
        busy    <= 1'b0;
    end
    else begin
        case (state)

            // -----------------------------------------------------------------
            // IDLE: Monitor SDA and SCL for I2C START condition.
            // START = SDA low while SCL high.
            // On detection, assert busy to start pulse generator and
            // move to wait_p to synchronize with master timing.
            // -----------------------------------------------------------------
            idle: begin
                if (scl == 1'b1 && sda == 1'b0) begin
                    busy  <= 1'b1;
                    state <= wait_p;
                end
                else
                    state <= idle;
            end

            // -----------------------------------------------------------------
            // WAIT_P: Wait until pulse generator reaches end of first SCL period.
            // Ensures slave FSM is phase-aligned with master before reading bits.
            // Proceeds when pulse==3 and count1==399 (end of full SCL period).
            // -----------------------------------------------------------------
            wait_p: begin
                if (pulse == 2'b11 && count1 == 399)
                    state <= read_addr;
                else
                    state <= wait_p;
            end

            // -----------------------------------------------------------------
            // READ_ADDR: Shift in 8-bit address frame from master, MSB first.
            // SDA released (sda_en=0) — master is driving.
            // SDA sampled at count1==200 (midpoint of SCL high) into r_addr.
            // Shift left each bit: {r_addr[6:0], sda}.
            // After 8 bits: extract addr[6:0] = r_addr[7:1], go to send_ack1.
            // -----------------------------------------------------------------
            read_addr: begin
                sda_en <= 1'b0;
                if (bitcnt <= 7) begin
                    case (pulse)
                        0: begin end
                        1: begin end
                        2: begin r_addr <= (count1 == 200) ? {r_addr[6:0], sda} : r_addr; end
                        3: begin end
                    endcase

                    if (count1 == clk_count1*4 - 1) begin
                        state  <= read_addr;
                        bitcnt <= bitcnt + 1;
                    end
                    else
                        state <= read_addr;
                end
                else begin
                    state  <= send_ack1;
                    bitcnt <= 0;
                    sda_en <= 1'b1;
                    addr   <= r_addr[7:1];
                end
            end

            // -----------------------------------------------------------------
            // SEND_ACK1: Slave acknowledges the address frame.
            // Pulls SDA low at pulse 0 (SCL low) — master reads ACK at pulse 2.
            // After ACK period: branch based on op bit (r_addr[0]).
            //   op=1 (read)  → send_data: fetch byte from memory
            //   op=0 (write) → read_data: receive byte from master
            // -----------------------------------------------------------------
            send_ack1: begin
                case (pulse)
                    0: begin sda_t <= 1'b0; end
                    1: begin end
                    2: begin end
                    3: begin end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    if (r_addr[0] == 1'b1) begin
                        state <= send_data;
                        r_mem <= 1'b1;
                    end
                    else begin
                        state <= read_data;
                        r_mem <= 1'b0;
                    end
                end
                else
                    state <= send_ack1;
            end

            // -----------------------------------------------------------------
            // READ_DATA: Shift in 8-bit data byte from master, MSB first.
            // Same sampling mechanism as read_addr.
            // After 8 bits: go to send_ack2 and trigger memory write (w_mem=1).
            // -----------------------------------------------------------------
            read_data: begin
                sda_en <= 1'b0;
                if (bitcnt <= 7) begin
                    case (pulse)
                        0: begin end
                        1: begin end
                        2: begin din <= (count1 == 200) ? {din[6:0], sda} : din; end
                        3: begin end
                    endcase

                    if (count1 == clk_count1*4 - 1) begin
                        state  <= read_data;
                        bitcnt <= bitcnt + 1;
                    end
                    else
                        state <= read_data;
                end
                else begin
                    state  <= send_ack2;
                    bitcnt <= 0;
                    sda_en <= 1'b1;
                    w_mem  <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // SEND_ACK2: Slave acknowledges the received data byte.
            // Pulls SDA low at pulse 0. Clears w_mem at pulse 1 (one-cycle
            // write pulse is sufficient for the memory controller).
            // After ACK period: release SDA and go to detect_stop.
            // -----------------------------------------------------------------
            send_ack2: begin
                case (pulse)
                    0: begin sda_t <= 1'b0; end
                    1: begin w_mem <= 1'b0; end
                    2: begin end
                    3: begin end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    state  <= detect_stop;
                    sda_en <= 1'b0;
                end
                else
                    state <= send_ack2;
            end

            // -----------------------------------------------------------------
            // SEND_DATA: Shift out 8-bit data byte to master, MSB first.
            // sda_t is set at count1==100 (midpoint of pulse 1, SCL low) so
            // SDA is stable before SCL rises at pulse 2 for master to sample.
            // r_mem cleared after first cycle — memory read was a one-shot.
            // After 8 bits: release SDA and go to master_ack.
            // -----------------------------------------------------------------
            send_data: begin
                sda_en <= 1'b1;
                if (bitcnt <= 7) begin
                    r_mem <= 1'b0;
                    case (pulse)
                        0: begin end
                        1: begin sda_t <= (count1 == 100) ? dout[7 - bitcnt] : sda_t; end
                        2: begin end
                        3: begin end
                    endcase

                    if (count1 == clk_count1*4 - 1) begin
                        state  <= send_data;
                        bitcnt <= bitcnt + 1;
                    end
                    else
                        state <= send_data;
                end
                else begin
                    state  <= master_ack;
                    bitcnt <= 0;
                    sda_en <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // MASTER_ACK: Slave reads the ACK/NACK sent by master after send_data.
            // SDA released (sda_en=0) — master drives SDA.
            // SDA sampled at count1==200 into r_ack.
            // NACK (r_ack=1): normal end of read — master has what it needs.
            // ACK  (r_ack=0): unexpected — master wants more data; flag ack_err.
            // Both branches proceed to detect_stop.
            // -----------------------------------------------------------------
            master_ack: begin
                case (pulse)
                    0: begin end
                    1: begin end
                    2: begin r_ack <= (count1 == 200) ? sda : r_ack; end
                    3: begin end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    if (r_ack == 1'b1) begin
                        ack_err <= 1'b0;
                        state   <= detect_stop;
                        sda_en  <= 1'b0;
                    end
                    else begin
                        ack_err <= 1'b1;
                        state   <= detect_stop;
                        sda_en  <= 1'b0;
                    end
                end
                else
                    state <= master_ack;
            end

            // -----------------------------------------------------------------
            // DETECT_STOP: Wait for master to complete the STOP condition.
            // STOP = SDA rises while SCL high; this occurs at pulse==3, count==399
            // (end of the last SCL period where SCL is held high).
            // On detection: clear busy, assert done, return to idle.
            // -----------------------------------------------------------------
            detect_stop: begin
                if (pulse == 2'b11 && count1 == 399) begin
                    state <= idle;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                end
                else
                    state <= detect_stop;
            end

            default: state <= idle;

        endcase
    end
end

// -----------------------------------------------------------------------------
// SDA Tri-State Driver
// When sda_en=1 (slave drives): output sda_t directly.
// When sda_en=0 (master drives): release SDA to Hi-Z.
// Open-drain: slave never drives SDA high — releases to pull-up resistor.
// -----------------------------------------------------------------------------
assign sda = (sda_en == 1'b1) ? sda_t : 1'bz;

endmodule

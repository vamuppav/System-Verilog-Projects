`timescale 1ns / 1ps

// =============================================================================
// Module: i2c_master
// Description:
//   I2C Master controller implemented in SystemVerilog.
//   Supports both write and read operations at 100 kHz (Standard Mode).
//   Uses a 4-phase pulse generator to time SCL and SDA transitions,
//   and an FSM to sequence through the I2C protocol states.
//
// Ports:
//   clk     - System clock (40 MHz)
//   rst     - Synchronous active-high reset
//   newd    - New data trigger: assert high for one cycle to start a transaction
//   addr    - 7-bit I2C slave address
//   op      - Operation select: 1 = read, 0 = write
//   sda     - Bidirectional serial data line (open-drain)
//   scl     - Serial clock output to slave
//   din     - 8-bit data to write to slave
//   dout    - 8-bit data received from slave (read operation)
//   busy    - High while a transaction is in progress
//   ack_err - High if slave did not acknowledge (NACK received)
//   done    - Pulses high for one cycle when transaction completes
// =============================================================================

module i2c_master(
    input        clk, rst, newd,
    input  [6:0] addr,
    input        op,
    inout        sda,
    output       scl,
    input  [7:0] din,
    output [7:0] dout,
    output reg   busy, ack_err, done
);

// -----------------------------------------------------------------------------
// Internal tri-state buffer registers for SCL and SDA
// -----------------------------------------------------------------------------
reg scl_t = 0;
reg sda_t = 0;

// -----------------------------------------------------------------------------
// Clock frequency parameters
// sys_freq  : system clock frequency (40 MHz)
// i2c_freq  : target I2C SCL frequency (100 kHz)
// clk_count4: number of system clock cycles per full SCL period (400 cycles)
// clk_count1: number of system clock cycles per quarter SCL period (100 cycles)
//             Used to divide one SCL period into 4 equal phases (0,1,2,3)
// -----------------------------------------------------------------------------
parameter sys_freq   = 40000000;
parameter i2c_freq   = 100000;

parameter clk_count4 = (sys_freq / i2c_freq);
parameter clk_count1 = clk_count4 / 4;

integer count1  = 0;
reg     i2c_clk = 0;

// -----------------------------------------------------------------------------
// 4-Phase Pulse Generator
// Divides each SCL period into 4 equal quarter-periods (pulse 0 to 3).
// pulse advances every clk_count1 system clock cycles.
// FSM uses pulse value to determine when to drive SCL/SDA transitions.
// Counter and pulse reset when bus is idle (busy == 0).
// -----------------------------------------------------------------------------
reg [1:0] pulse = 0;

always @(posedge clk) begin
    if (rst) begin
        pulse  <= 0;
        count1 <= 0;
    end
    else if (busy == 1'b0) begin
        pulse  <= 0;
        count1 <= 0;
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
// FSM Registers
// bitcount : tracks how many bits have been shifted out or in (0-7)
// data_addr: holds {addr, op} — 7-bit address + R/W bit
// data_tx  : holds the byte to transmit to slave
// r_ack    : captures the ACK/NACK bit from slave on SDA
// rx_data  : shift register that assembles the byte received from slave
// sda_en   : 1 = master drives SDA, 0 = SDA released (slave drives or Hi-Z)
// -----------------------------------------------------------------------------
reg [3:0] bitcount  = 0;
reg [7:0] data_addr = 0, data_tx = 0;
reg       r_ack     = 0;
reg [7:0] rx_data   = 0;
reg       sda_en    = 0;

// -----------------------------------------------------------------------------
// FSM State Encoding
// idle       : waiting for newd
// start      : generating I2C START condition (SDA falls while SCL high)
// write_addr : shifting out 8-bit address frame {addr[6:0], op}
// ack_1      : receiving ACK from slave after address phase
// write_data : shifting out 8-bit data byte to slave
// read_data  : shifting in 8-bit data byte from slave
// ack_2      : receiving ACK from slave after write_data
// master_ack : master sends NACK to slave after read_data (signals end of read)
// stop       : generating I2C STOP condition (SDA rises while SCL high)
// -----------------------------------------------------------------------------
typedef enum logic [3:0] {
    idle       = 0,
    start      = 1,
    write_addr = 2,
    ack_1      = 3,
    write_data = 4,
    read_data  = 5,
    stop       = 6,
    ack_2      = 7,
    master_ack = 8
} state_type;

state_type state = idle;

// -----------------------------------------------------------------------------
// Main FSM
// Sequences through I2C protocol states on every rising system clock edge.
// SCL and SDA transitions are gated by the 4-phase pulse counter.
// Each state stays active for one full SCL period (4 quarter-phases),
// then advances on the terminal count (count1 == clk_count1*4 - 1).
// -----------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        bitcount  <= 0;
        data_addr <= 0;
        data_tx   <= 0;
        scl_t     <= 1;
        sda_t     <= 1;
        state     <= idle;
        busy      <= 1'b0;
        ack_err   <= 1'b0;
        done      <= 1'b0;
    end
    else begin
        case (state)

            // -----------------------------------------------------------------
            // IDLE: Wait for newd. Latch address, R/W bit, and transmit data.
            // -----------------------------------------------------------------
            idle: begin
                done <= 1'b0;
                if (newd == 1'b1) begin
                    data_addr <= {addr, op};
                    data_tx   <= din;
                    busy      <= 1'b1;
                    state     <= start;
                    ack_err   <= 1'b0;
                end
                else begin
                    data_addr <= 0;
                    data_tx   <= 0;
                    busy      <= 1'b0;
                    state     <= idle;
                    ack_err   <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // START: Generate I2C START condition.
            // SCL held high throughout. SDA pulled low at pulse 2.
            // SDA falling while SCL is high signals START to all slaves.
            // -----------------------------------------------------------------
            start: begin
                sda_en <= 1'b1;
                case (pulse)
                    0: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                    1: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                    2: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                    3: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    state <= write_addr;
                    scl_t <= 1'b0;
                end
                else
                    state <= start;
            end

            // -----------------------------------------------------------------
            // WRITE_ADDR: Shift out 8-bit address frame MSB first.
            // SDA is set at pulse 1 (SCL low) and held through pulse 2-3 (SCL high).
            // After all 8 bits, release SDA and wait for slave ACK.
            // -----------------------------------------------------------------
            write_addr: begin
                sda_en <= 1'b1;
                if (bitcount <= 7) begin
                    case (pulse)
                        0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                        1: begin scl_t <= 1'b0; sda_t <= data_addr[7 - bitcount]; end
                        2: begin scl_t <= 1'b1; end
                        3: begin scl_t <= 1'b1; end
                    endcase

                    if (count1 == clk_count1*4 - 1) begin
                        state    <= write_addr;
                        scl_t    <= 1'b0;
                        bitcount <= bitcount + 1;
                    end
                    else
                        state <= write_addr;
                end
                else begin
                    state    <= ack_1;
                    bitcount <= 0;
                    sda_en   <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // ACK_1: Receive ACK from slave after address phase.
            // SDA released (sda_en=0); slave pulls SDA low to acknowledge.
            // SDA sampled at pulse 2 (SCL high) into r_ack.
            // On ACK (r_ack=0): branch to write_data or read_data based on op.
            // On NACK: abort to stop with ack_err asserted.
            // -----------------------------------------------------------------
            ack_1: begin
                sda_en <= 1'b0;
                case (pulse)
                    0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                    1: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                    2: begin scl_t <= 1'b1; sda_t <= 1'b0; r_ack <= sda; end
                    3: begin scl_t <= 1'b1; end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    if (r_ack == 1'b0 && data_addr[0] == 1'b0) begin
                        state    <= write_data;
                        sda_t    <= 1'b0;
                        sda_en   <= 1'b1;
                        bitcount <= 0;
                    end
                    else if (r_ack == 1'b0 && data_addr[0] == 1'b1) begin
                        state    <= read_data;
                        sda_t    <= 1'b1;
                        sda_en   <= 1'b0;
                        bitcount <= 0;
                    end
                    else begin
                        state   <= stop;
                        sda_en  <= 1'b1;
                        ack_err <= 1'b1;
                    end
                end
                else
                    state <= ack_1;
            end

            // -----------------------------------------------------------------
            // WRITE_DATA: Shift out 8-bit data byte to slave, MSB first.
            // Same SCL/SDA timing as write_addr.
            // After all 8 bits, release SDA and wait for slave ACK (ack_2).
            // -----------------------------------------------------------------
            write_data: begin
                if (bitcount <= 7) begin
                    case (pulse)
                        0: begin scl_t <= 1'b0; end
                        1: begin scl_t <= 1'b0; sda_en <= 1'b1; sda_t <= data_tx[7 - bitcount]; end
                        2: begin scl_t <= 1'b1; end
                        3: begin scl_t <= 1'b1; end
                    endcase

                    if (count1 == clk_count1*4 - 1) begin
                        state    <= write_data;
                        scl_t    <= 1'b0;
                        bitcount <= bitcount + 1;
                    end
                    else
                        state <= write_data;
                end
                else begin
                    state    <= ack_2;
                    bitcount <= 0;
                    sda_en   <= 1'b0;
                end
            end

            // -----------------------------------------------------------------
            // READ_DATA: Shift in 8-bit data byte from slave, MSB first.
            // SDA released (sda_en=0); slave drives SDA.
            // SDA sampled at the midpoint of pulse 2 (count1==200) and
            // shifted into rx_data MSB first: {rx_data[6:0], sda}.
            // After 8 bits, assert sda_en and send NACK to slave (master_ack).
            // -----------------------------------------------------------------
            read_data: begin
                sda_en <= 1'b0;
                if (bitcount <= 7) begin
                    case (pulse)
                        0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                        1: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                        2: begin scl_t <= 1'b1; rx_data[7:0] <= (count1 == 200) ? {rx_data[6:0], sda} : rx_data; end
                        3: begin scl_t <= 1'b1; end
                    endcase

                    if (count1 == clk_count1*4 - 1) begin
                        state    <= read_data;
                        scl_t    <= 1'b0;
                        bitcount <= bitcount + 1;
                    end
                    else
                        state <= read_data;
                end
                else begin
                    state    <= master_ack;
                    bitcount <= 0;
                    sda_en   <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // MASTER_ACK: Master sends NACK (SDA=1) to slave.
            // NACK tells slave the master does not want more data.
            // SDA held high throughout all 4 phases while SCL pulses.
            // Proceeds to STOP after one full SCL period.
            // -----------------------------------------------------------------
            master_ack: begin
                sda_en <= 1'b1;
                case (pulse)
                    0: begin scl_t <= 1'b0; sda_t <= 1'b1; end
                    1: begin scl_t <= 1'b0; sda_t <= 1'b1; end
                    2: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                    3: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    sda_t  <= 1'b0;
                    state  <= stop;
                    sda_en <= 1'b1;
                end
                else
                    state <= master_ack;
            end

            // -----------------------------------------------------------------
            // ACK_2: Receive ACK from slave after write_data phase.
            // Same mechanics as ack_1.
            // On ACK (r_ack=0): proceed to stop, clear ack_err.
            // On NACK: proceed to stop, assert ack_err.
            // -----------------------------------------------------------------
            ack_2: begin
                sda_en <= 1'b0;
                case (pulse)
                    0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                    1: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                    2: begin scl_t <= 1'b1; sda_t <= 1'b0; r_ack <= sda; end
                    3: begin scl_t <= 1'b1; end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    sda_t  <= 1'b0;
                    sda_en <= 1'b1;
                    if (r_ack == 1'b0) begin
                        state   <= stop;
                        ack_err <= 1'b0;
                    end
                    else begin
                        state   <= stop;
                        ack_err <= 1'b1;
                    end
                end
                else
                    state <= ack_2;
            end

            // -----------------------------------------------------------------
            // STOP: Generate I2C STOP condition.
            // SCL held high throughout. SDA rises at pulse 2.
            // SDA rising while SCL is high signals STOP to all slaves.
            // Returns to idle, clears busy, asserts done for one cycle.
            // -----------------------------------------------------------------
            stop: begin
                sda_en <= 1'b1;
                case (pulse)
                    0: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                    1: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                    2: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                    3: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                endcase

                if (count1 == clk_count1*4 - 1) begin
                    state  <= idle;
                    scl_t  <= 1'b0;
                    busy   <= 1'b0;
                    sda_en <= 1'b1;
                    done   <= 1'b1;
                end
                else
                    state <= stop;
            end

            default: state <= idle;

        endcase
    end
end

// -----------------------------------------------------------------------------
// SDA Tri-State Driver
// When sda_en=1 (master drives): output sda_t directly (0 or 1).
// When sda_en=0 (slave drives):  release SDA to Hi-Z so slave can pull low.
// Open-drain behaviour: master never drives SDA high — it releases to pull-up.
// -----------------------------------------------------------------------------
assign sda = (sda_en == 1) ? (sda_t == 0) ? 1'b0 : 1'b1 : 1'bz;

assign scl  = scl_t;
assign dout = rx_data;

endmodule

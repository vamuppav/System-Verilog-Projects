`timescale 1ns / 1ps

// =============================================================
// Module : uart_top
// Top-level wrapper — instantiates transmitter and receiver
// =============================================================
module uart_top
#(
  parameter clk_freq = 1000000,
  parameter baud_rate = 9600
)
(
  input        clk, rst,
  input        rx,
  input  [7:0] dintx,
  input        newd,
  output       tx,
  output [7:0] doutrx,
  output       donetx,
  output       donerx
);

  // Instantiate UART transmitter
  uarttx #(clk_freq, baud_rate) utx (clk, rst, newd, dintx, tx, donetx);

  // Instantiate UART receiver
  uartrx #(clk_freq, baud_rate) rtx (clk, rst, rx, donerx, doutrx);

endmodule


///////////////////////////////////////////////////////////////////


// =============================================================
// Module : uarttx
// Serializes 8-bit parallel data onto tx line
// FSM States : idle → transfer → idle
// =============================================================
module uarttx
#(
  parameter clk_freq = 1000000,
  parameter baud_rate = 9600
)
(
  input        clk, rst,
  input        newd,
  input  [7:0] tx_data,
  output reg   tx,
  output reg   donetx
);

  // System clock cycles per baud period
  localparam clkcount = (clk_freq / baud_rate);

  integer count  = 0;
  integer counts = 0;

  reg uclk = 0;

  enum bit [1:0] {idle = 2'b00, start = 2'b01, transfer = 2'b10, done = 2'b11} state;

  // Divide system clock to generate baud-rate clock
  always @(posedge clk) begin
    if (count < clkcount / 2)
      count <= count + 1;
    else begin
      count <= 0;
      uclk  <= ~uclk;
    end
  end

  reg [7:0] din;

  // Transmitter FSM — clocked on baud-rate clock
  always @(posedge uclk) begin
    if (rst) begin
      state <= idle;
    end else begin
      case (state)

        // Hold line high; latch data and drive start bit when newd asserted
        idle: begin
          counts <= 0;
          tx     <= 1'b1;
          donetx <= 1'b0;

          if (newd) begin
            din   <= tx_data;   // Latch input byte
            tx    <= 1'b0;      // Assert start bit
            state <= transfer;
          end else begin
            state <= idle;
          end
        end

        // Shift out 8 bits LSB-first; drive stop bit and assert donetx after
        transfer: begin
          if (counts <= 7) begin
            tx     <= din[counts];   // Transmit current bit
            counts <= counts + 1;
            state  <= transfer;
          end else begin
            counts <= 0;
            tx     <= 1'b1;          // Drive stop bit
            donetx <= 1'b1;          // Signal transmission complete
            state  <= idle;
          end
        end

        default: state <= idle;

      endcase
    end
  end

endmodule


///////////////////////////////////////////////////////////////////


// =============================================================
// Module : uartrx
// Deserializes incoming bits on rx line into 8-bit parallel data
// FSM States : idle → start → idle
// =============================================================
module uartrx
#(
  parameter clk_freq = 1000000,
  parameter baud_rate = 9600
)
(
  input            clk, rst,
  input            rx,
  output reg       done,
  output reg [7:0] rxdata
);

  // System clock cycles per baud period
  localparam clkcount = (clk_freq / baud_rate);

  integer count  = 0;
  integer counts = 0;

  reg uclk = 0;

  enum bit [1:0] {idle = 2'b00, start = 2'b01} state;

  // Divide system clock to generate baud-rate clock
  always @(posedge clk) begin
    if (count < clkcount / 2)
      count <= count + 1;
    else begin
      count <= 0;
      uclk  <= ~uclk;
    end
  end

  // Receiver FSM — clocked on baud-rate clock
  always @(posedge uclk) begin
    if (rst) begin
      rxdata <= 8'h00;
      counts <= 0;
      done   <= 1'b0;
    end else begin
      case (state)

        // Monitor rx line; transition to start on start bit detected (rx = 0)
        idle: begin
          rxdata <= 8'h00;
          counts <= 0;
          done   <= 1'b0;

          if (rx == 1'b0)
            state <= start;
          else
            state <= idle;
        end

        // Shift in 8 bits MSB-first; assert done and return to idle after last bit
        start: begin
          if (counts <= 7) begin
            rxdata <= {rx, rxdata[7:1]};   // Shift received bit into MSB
            counts <= counts + 1;
          end else begin
            counts <= 0;
            done   <= 1'b1;                // Full byte received
            state  <= idle;
          end
        end

        default: state <= idle;

      endcase
    end
  end

endmodule


///////////////////////////////////////////////////////////////////


// =============================================================
// Interface : uart_if
// Bundles all UART signals for use in the testbench
// =============================================================
interface uart_if;
  logic        clk;
  logic        uclktx;
  logic        uclkrx;
  logic        rst;
  logic        rx;
  logic  [7:0] dintx;
  logic        newd;
  logic        tx;
  logic  [7:0] doutrx;
  logic        donetx;
  logic        donerx;
endinterface

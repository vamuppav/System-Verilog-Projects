//------------------------------------------------
// SPI Master
// Generates SCLK and serializes 12-bit data
// over MOSI, LSB first
//------------------------------------------------
module spi_master(
    input             clk, newd, rst,
    input      [11:0] din,
    output reg        sclk, cs, mosi
);

    typedef enum bit [1:0] {
        idle   = 2'b00,
        enable = 2'b01,
        send   = 2'b10,
        comp   = 2'b11
    } state_type;

    state_type state = idle;

    int countc = 0;  // clock divider counter
    int count  = 0;  // bit index counter

    reg [11:0] temp; // holds din during transmission

    //--------------------------------------------
    // SCLK Generator
    // Divides clk by 20 (toggles every 10 cycles)
    //--------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            countc <= 0;
            sclk   <= 1'b0;
        end
        else begin
            if (countc < 10)
                countc <= countc + 1;
            else begin
                countc <= 0;
                sclk   <= ~sclk;
            end
        end
    end

    //--------------------------------------------
    // FSM : idle -> send -> idle
    // Runs on SCLK edges
    //--------------------------------------------
    always @(posedge sclk) begin
        if (rst) begin
            cs   <= 1'b1;  // deassert chip select
            mosi <= 1'b0;
        end
        else begin
            case (state)

                // Wait for newd; latch din and begin transaction
                idle: begin
                    if (newd) begin
                        state <= send;
                        temp  <= din;
                        cs    <= 1'b0;  // assert chip select
                    end
                    else begin
                        state <= idle;
                        temp  <= 8'h00;
                    end
                end

                // Shift out 12 bits, LSB first
                send: begin
                    if (count <= 11) begin
                        mosi  <= temp[count];
                        count <= count + 1;
                    end
                    else begin
                        count <= 0;
                        state <= idle;
                        cs    <= 1'b1;  // deassert chip select
                        mosi  <= 1'b0;
                    end
                end

                default: state <= idle;

            endcase
        end
    end

endmodule


//------------------------------------------------
// SPI Slave
// Deserializes MOSI into 12-bit dout
// Asserts done when all bits received
//------------------------------------------------
module spi_slave(
    input             sclk, cs, mosi,
    output     [11:0] dout,
    output reg        done
);

    typedef enum bit {
        detect_start = 1'b0,
        read_data    = 1'b1
    } state_type;

    state_type state = detect_start;

    reg [11:0] temp  = 12'h000;
    int        count = 0;

    //--------------------------------------------
    // FSM : detect_start -> read_data -> detect_start
    // Runs on SCLK edges
    //--------------------------------------------
    always @(posedge sclk) begin
        case (state)

            // Wait for cs to go low (master starts transaction)
            detect_start: begin
                done <= 1'b0;
                if (!cs)
                    state <= read_data;
                else
                    state <= detect_start;
            end

            // Shift in 12 bits via right-shift register
            // MSB side receives mosi; LSB side shifts out
            // After 12 cycles temp holds the original din
            read_data: begin
                if (count <= 11) begin
                    count <= count + 1;
                    temp  <= {mosi, temp[11:1]};
                end
                else begin
                    count <= 0;
                    done  <= 1'b1;  // signal data ready
                    state <= detect_start;
                end
            end

        endcase
    end

    assign dout = temp;

endmodule


//------------------------------------------------
// Top Module
// Structural wrapper connecting master and slave
// sclk, cs, mosi are internal wires
//------------------------------------------------
module top(
    input             clk, rst, newd,
    input      [11:0] din,
    output     [11:0] dout,
    output            done
);

    wire sclk, cs, mosi;

    spi_master m1 (clk, newd, rst, din, sclk, cs, mosi);
    spi_slave  s1 (sclk, cs, mosi, dout, done);

endmodule


//------------------------------------------------
// SPI Interface
// Bundles all signals between DUT and testbench
// sclk is assigned from dut.m1.sclk in tb
// since it is internal to top
//------------------------------------------------
interface spi_if;
    logic        clk;
    logic        rst;
    logic        newd;
    logic [11:0] din;
    logic [11:0] dout;
    logic        done;
    logic        sclk;
endinterface

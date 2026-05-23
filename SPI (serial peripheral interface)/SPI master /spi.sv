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
            cs   <= 1'b1;
            mosi <= 1'b0;
        end
        else begin
            case (state)

                // Wait for newd; latch din and begin transaction
                idle: begin
                    if (newd) begin
                        state <= send;
                        temp  <= din;
                        cs    <= 1'b0;
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
                        cs    <= 1'b1;
                        mosi  <= 1'b0;
                    end
                end

                default: state <= idle;

            endcase
        end
    end

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

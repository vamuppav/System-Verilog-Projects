/////////// Master

`timescale 1ns / 1ps

module i2c_master( input clk, rst , newd,
input [6:0] addr,
input op,//1-r
inout sda,
output scl,
input [7:0] din,
output [7:0] dout,
output reg busy, ack_err, done
);

reg scl_t = 0;
reg sda_t = 0;

parameter sys_freq = 40000000;
parameter i2c_freq = 100000;

parameter clk_count4 = (sys_freq/i2c_freq); // 400 cycles per SCL period
parameter clk_count1 = clk_count4/4;        // 100 cycles per quarter-period

integer count1 = 0;
reg i2c_clk = 0;

// 4-phase pulse generator
// Divides each SCL period into 4 equal phases (0-3)
// FSM uses pulse value to time SCL/SDA transitions
reg [1:0] pulse = 0;
always@(posedge clk)
begin
      if(rst)
       begin
       pulse <= 0;
       count1 <= 0;
       end
       else if (busy == 1'b0)
        begin
        pulse <= 0;
        count1 <= 0;
        end
      else if(count1  == clk_count1 - 1)
       begin
       pulse <= 1;
       count1 <= count1 + 1;
       end
      else if(count1  == clk_count1*2 - 1)
       begin
       pulse <= 2;
       count1 <= count1 + 1;
       end
      else if(count1  == clk_count1*3 - 1)
       begin
       pulse <= 3;
       count1 <= count1 + 1;
       end
      else if(count1  == clk_count1*4 - 1)
       begin
       pulse <= 0;
       count1 <= 0;
       end
      else
       begin
       count1 <= count1 + 1;
       end
end

reg [3:0] bitcount = 0;
reg [7:0] data_addr   = 0, data_tx = 0;
reg r_ack = 0;
reg [7:0] rx_data = 0;
reg sda_en = 0;

typedef enum logic [3:0] {idle = 0, start = 1, write_addr = 2, ack_1 = 3, write_data = 4, read_data = 5, stop = 6, ack_2 =7, master_ack = 8} state_type;
state_type state = idle;

always@(posedge clk)
begin
 if(rst)
   begin
    bitcount   <= 0;
    data_addr  <= 0;
    data_tx    <= 0;
    scl_t <= 1;
    sda_t <= 1;
    state <= idle;
    busy  <= 1'b0;
    ack_err <= 1'b0;
    done    <= 1'b0;
   end
else
   begin
                case(state)
                
                      idle:
                      begin
                            done  <= 1'b0;
                            if(newd == 1'b1)
                               begin
                               data_addr  <= {addr,op};
                               data_tx    <= din;
                               busy  <= 1'b1;
                               state <= start;
                               ack_err <= 1'b0;
                               end
                            else
                               begin
                               data_addr  <= 0;
                               data_tx    <= 0;
                               busy  <= 1'b0;
                               state <= idle;
                               ack_err <= 1'b0;
                               end
                      end
                  
                  // START: SDA falls while SCL high — signals start to all slaves
                     start: 
                     begin
                         sda_en <= 1'b1;
                         case(pulse)
                         0: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                         1: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                         2: begin scl_t <= 1'b1; sda_t <= 1'b0; end // SDA pulled low
                         3: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                         endcase
                         
                             if(count1  == clk_count1*4 - 1)
                             begin
                                state <= write_addr;
                                scl_t <= 1'b0;
                             end
                             else
                                state <= start;
                     end
                 
                 // WRITE_ADDR: shift out {addr[6:0], op} MSB first
                 // SDA set at pulse 1 (SCL low), slave reads at pulse 2 (SCL high)
                   write_addr: 
                   begin
                      sda_en <= 1'b1;
                      if(bitcount <= 7)
                         begin
                                 case(pulse)
                                 0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 1: begin scl_t <= 1'b0; sda_t <= data_addr[7 - bitcount]; end
                                 2: begin scl_t <= 1'b1;  end
                                 3: begin scl_t <= 1'b1;  end
                                 endcase
                                 if(count1  == clk_count1*4 - 1)
                                 begin
                                    state <= write_addr;
                                    scl_t <= 1'b0;
                                    bitcount <= bitcount + 1;
                                 end
                                 else
                                 begin
                                    state <= write_addr;
                                 end
                             
                         end
                      else
                        begin
                        state <= ack_1;
                        bitcount <= 0;
                        sda_en <= 1'b0; // release SDA for slave to drive ACK
                        end
                   end   
                   
                   // ACK_1: receive ACK from slave after address frame
                   // SDA sampled at pulse 2 (SCL high); r_ack=0 means ACK
                   // Branch to write_data or read_data based on op bit
                   ack_1 : 
                   begin
                        sda_en <= 1'b0;
                                case(pulse)
                                 0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 1: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 2: begin scl_t <= 1'b1; sda_t <= 1'b0; r_ack <= sda; end
                                 3: begin scl_t <= 1'b1;  end
                                 endcase
                   
                       if(count1  == clk_count1*4 - 1)
                                  begin
                                      if(r_ack == 1'b0 && data_addr[0] == 1'b0)
                                        begin
                                        state <= write_data;
                                        sda_t <= 1'b0;
                                        sda_en <= 1'b1;
                                        bitcount <= 0;
                                        end
                                      else if (r_ack == 1'b0 && data_addr[0] == 1'b1)
                                      begin
                                        state <= read_data;
                                        sda_t <= 1'b1;
                                        sda_en <= 1'b0;
                                        bitcount <= 0;
                                      end
                                      else
                                      begin
                                        state <= stop;
                                        sda_en <= 1'b1;
                                        ack_err <= 1'b1; // NACK received — abort
                                      end
                                  end
                                 else
                                  begin
                                    state <= ack_1;
                                  end
                     
                   end
                   
                 // WRITE_DATA: shift out data byte MSB first
                 // SDA placed at pulse 1 (SCL low), slave reads at pulse 2 (SCL high)
                 write_data: 
                 begin
                  if(bitcount <= 7)
                         begin
                                 case(pulse)
                                 0: begin scl_t <= 1'b0;   end
                                 1: begin scl_t <= 1'b0;sda_en <= 1'b1; sda_t <= data_tx[7 - bitcount]; end
                                 2: begin scl_t <= 1'b1;  end
                                 3: begin scl_t <= 1'b1;  end
                                 endcase
                                 if(count1  == clk_count1*4 - 1)
                                 begin
                                    state <= write_data;
                                    scl_t <= 1'b0;
                                    bitcount <= bitcount + 1;
                                 end
                                 else
                                 begin
                                    state <= write_data;
                                 end
                             
                         end
                      else
                        begin
                        state <= ack_2;
                        bitcount <= 0;
                        sda_en <= 1'b0; // release SDA for slave ACK
                        end
                 
                 end 
                 
                 // READ_DATA: shift in data byte from slave MSB first
                 // SDA sampled at count1==200 (midpoint of SCL high) to avoid edge glitches
                 // Shift into rx_data: {rx_data[6:0], sda}
                 read_data: 
                 begin
                 sda_en <= 1'b0; // slave drives SDA
                 if(bitcount <= 7)
                         begin
                                 case(pulse)
                                 0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 1: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 2: begin scl_t <= 1'b1; rx_data[7:0] <= (count1 == 200) ? {rx_data[6:0],sda} : rx_data; end
                                 3: begin scl_t <= 1'b1;  end
                                 endcase
                                 if(count1  == clk_count1*4 - 1)
                                 begin
                                    state <= read_data;
                                    scl_t <= 1'b0;
                                    bitcount <= bitcount + 1;
                                 end
                                 else
                                 begin
                                    state <= read_data;
                                 end
                             
                         end
                      else
                        begin
                        state <= master_ack;
                        bitcount <= 0;
                        sda_en <= 1'b1; // master reclaims SDA to send NACK
                        end
                 
                 end
                 
                 // MASTER_ACK: master sends NACK (SDA=1) to signal end of read
                 // SDA pulled low after period ends to prepare for STOP condition
                 master_ack : 
                   begin
                      sda_en <= 1'b1;
                      
                                case(pulse)
                                 0: begin scl_t <= 1'b0; sda_t <= 1'b1; end
                                 1: begin scl_t <= 1'b0; sda_t <= 1'b1; end
                                 2: begin scl_t <= 1'b1; sda_t <= 1'b1; end // slave reads NACK here
                                 3: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                                 endcase
                   
                       if(count1  == clk_count1*4 - 1)
                                  begin
                                      sda_t <= 1'b0; // pull low ready for STOP
                                      state <= stop;
                                      sda_en <= 1'b1;
                                      
                                  end
                                 else
                                  begin
                                    state <= master_ack;
                                  end
                     
                   end
                 
                 // ACK_2: receive ACK from slave after write_data
                 // Same mechanism as ack_1; ack_err flagged on NACK
                  ack_2 : 
                   begin
                     sda_en <= 1'b0;
                                case(pulse)
                                 0: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 1: begin scl_t <= 1'b0; sda_t <= 1'b0; end
                                 2: begin scl_t <= 1'b1; sda_t <= 1'b0; r_ack <= sda; end
                                 3: begin scl_t <= 1'b1;  end
                                 endcase
                   
                       if(count1  == clk_count1*4 - 1)
                                  begin
                                      sda_t <= 1'b0;
                                      sda_en <= 1'b1;
                                      if(r_ack == 1'b0 )
                                        begin
                                        state <= stop;
                                        ack_err <= 1'b0;
                                        end
                                      else
                                        begin
                                        state <= stop;
                                        ack_err <= 1'b1;
                                        end
                                  end
                                 else
                                  begin
                                    state <= ack_2;
                                  end
                     
                   end

                // STOP: SDA rises while SCL high — signals stop to all slaves
                // Returns to idle; asserts done for one cycle
                   stop: 
                     begin
                     sda_en <= 1'b1;
                         case(pulse)
                         0: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                         1: begin scl_t <= 1'b1; sda_t <= 1'b0; end
                         2: begin scl_t <= 1'b1; sda_t <= 1'b1; end // SDA rises — STOP
                         3: begin scl_t <= 1'b1; sda_t <= 1'b1; end
                         endcase
                         
                             if(count1  == clk_count1*4 - 1)
                             begin
                                state <= idle;
                                scl_t <= 1'b0;
                                busy <= 1'b0;
                                sda_en <= 1'b1;
                                done   <= 1'b1;
                             end
                             else
                                state <= stop;
                     end
                     
                 default : state <= idle;
               endcase
   end
end

// SDA tri-state driver
// sda_en=1: master drives sda_t onto the bus
// sda_en=0: Hi-Z — slave drives or pull-up holds line high
assign sda = (sda_en == 1) ? (sda_t == 0) ? 1'b0 : 1'b1 : 1'bz;
assign scl = scl_t;
assign dout = rx_data;
endmodule


///////////////////// Slave
`timescale 1ns / 1ps

module i2c_Slave(
input scl,clk,rst,
inout sda,
output reg ack_err, done
    );
  
typedef enum logic [3:0] {idle = 0, read_addr = 1, send_ack1 = 2, send_data = 3, master_ack = 4, read_data = 5, send_ack2 = 6, wait_p = 7, detect_stop = 8} state_type;
state_type state = idle;    

// 128-byte internal memory; initialized to mem[i]=i on reset
reg [7:0] mem [128];
reg [7:0] r_addr;
reg [6:0] addr;
reg r_mem = 0;
reg w_mem = 0;
reg [7:0] dout;
reg [7:0] din;
reg sda_t;
reg sda_en;
reg [3:0] bitcnt = 0;

// Memory controller: handles reset init, read (r_mem), and write (w_mem)
always@(posedge clk)
begin
  if(rst)
  begin
      for(int i = 0 ; i < 128; i++)
        begin
        mem[i] = i;
        end
      dout <= 8'h0;
  end
  else if (r_mem == 1'b1)
   begin
      dout <= mem[addr];
   end
  else if (w_mem == 1'b1)
   begin
      mem[addr] <= din;
   end 
   
end

parameter sys_freq = 40000000;
parameter i2c_freq = 100000;

parameter clk_count4 = (sys_freq/i2c_freq); // 400 cycles per SCL period
parameter clk_count1 = clk_count4/4;        // 100 cycles per quarter-period
integer count1 = 0;
reg i2c_clk = 0;

// 4-phase pulse generator — mirrors master timing
// When idle, pre-loaded to (pulse=2, count1=202) for phase alignment with master
reg [1:0] pulse = 0;
reg busy;
always@(posedge clk)
begin
      if(rst)
      begin
        pulse <= 0;
        count1 <= 0;
      end
      else if(busy == 1'b0)
       begin
       pulse <= 2;
       count1 <= 202;
       end
      else if(count1  == clk_count1 - 1)
       begin
       pulse <= 1;
       count1 <= count1 + 1;
       end
      else if(count1  == clk_count1*2 - 1)
       begin
       pulse <= 2;
       count1 <= count1 + 1;
       end
      else if(count1  == clk_count1*3 - 1)
       begin
       pulse <= 3;
       count1 <= count1 + 1;
       end
      else if(count1  == clk_count1*4 - 1)
       begin
       pulse <= 0;
       count1 <= 0;
       end
      else
       begin
       count1 <= count1 + 1;
       end
end

// START detector: captures falling edge of SCL after SDA goes low
// start = SCL was high last cycle and is low now
reg scl_t;
wire start;
always@(posedge clk)
begin
scl_t <= scl;
end

assign start = ~scl & scl_t; 

reg r_ack;

always@(posedge clk)
begin
if(rst)
 begin
                  bitcnt <= 0;
                  state  <= idle;
                  r_addr <= 7'b0000000;
                  sda_en <= 1'b0;
                  sda_t <= 1'b0;
                  addr  <= 0;
                  r_mem <= 0;
                  din   <= 8'h00; 
                  ack_err <= 0;
                  done    <= 1'b0;
                  busy <= 1'b0;
 end
 
 else
    begin
      case(state)
      
               // IDLE: detect START condition (SCL high, SDA low)
               idle: begin
                   if(scl == 1'b1 && sda == 1'b0)
                    begin
                    busy <= 1'b1;
                    state <= wait_p; 
                    end
                   else
                    begin
                    state <= idle;
                    end
               end
               
               // WAIT_P: wait for pulse generator to reach end of first SCL period
               // ensures slave FSM is phase-aligned with master before reading bits
               wait_p :  
               begin
                if (pulse == 2'b11 && count1 == 399)
                    state <= read_addr;
                else
                    state <= wait_p;
               
               end
               
               // READ_ADDR: shift in 8-bit address frame from master MSB first
               // SDA sampled at count1==200 (midpoint of SCL high)
               // After 8 bits: extract addr[6:0] = r_addr[7:1], go to send_ack1
               read_addr: 
               begin
                         sda_en <= 1'b0;
                              if(bitcnt <= 7)
                                 begin
                                         case(pulse)
                                         0: begin  end
                                         1: begin  end
                                         2: begin   r_addr <= (count1 == 200) ? {r_addr[6:0],sda} : r_addr; end 
                                         3: begin  end
                                         endcase
                                         if(count1  == clk_count1*4 - 1)
                                         begin
                                            state <= read_addr;
                                            bitcnt <= bitcnt + 1;
                                         end
                                         else
                                         begin
                                            state <= read_addr;
                                         end
                                     
                                 end
                              else
                                begin
                                state  <= send_ack1;
                                bitcnt <= 0;
                                sda_en <= 1'b1;
                                addr <= r_addr[7:1];
                                end
                       
                      end
                      
                      // SEND_ACK1: slave pulls SDA low to ACK address frame
                      // op bit (r_addr[0]): 1=read → send_data, 0=write → read_data
                      send_ack1: 
                      begin
                                    case(pulse)
                                         0: begin  sda_t <= 1'b0; end
                                         1: begin  end
                                         2: begin  end 
                                         3: begin  end
                                     endcase
                                  if(count1  == clk_count1*4 - 1)
                                       begin
                                          if(r_addr[0] == 1'b1)
                                            begin
                                            state <= send_data;
                                            r_mem <= 1'b1;
                                            end
                                          else
                                            begin
                                             state <= read_data;
                                             r_mem <= 1'b0;
                                            end
                                         end
                                  else
                                       begin
                                       state <= send_ack1;
                                       end
                                    
                                    
                      end
                      
                      // READ_DATA: shift in 8-bit data byte from master MSB first
                      // After 8 bits: trigger memory write (w_mem=1), go to send_ack2
                       read_data: 
                        begin
                          sda_en <= 1'b0;
                              if(bitcnt <= 7)
                                 begin
                                         case(pulse)
                                         0: begin  end
                                         1: begin  end
                                         2: begin   din <= (count1 == 200) ? {din[6:0],sda} : din; end 
                                         3: begin  end
                                         endcase
                                         if(count1  == clk_count1*4 - 1)
                                         begin
                                            state <= read_data;
                                            bitcnt <= bitcnt + 1;
                                         end
                                         else
                                         begin
                                            state <= read_data;
                                         end
                                     
                                 end
                              else
                                begin
                                state  <= send_ack2;
                                bitcnt <= 0;
                                sda_en <= 1'b1;
                                w_mem  <= 1'b1;
                                end
                       
                      end
                      
                      // SEND_ACK2: slave ACKs received data byte
                      // w_mem cleared at pulse 1 — one-cycle write pulse is sufficient
                      send_ack2: 
                      begin
                                   
                                   case(pulse)
                                         0: begin  sda_t <= 1'b0; end
                                         1: begin  w_mem <= 1'b0; end
                                         2: begin  end 
                                         3: begin  end
                                     endcase
                                  if(count1  == clk_count1*4 - 1)
                                         begin
                                          state <= detect_stop;
                                          sda_en <= 1'b0;
                                         end
                                  else
                                       begin
                                       state <= send_ack2;
                                       end
                      end
                 
                 // SEND_DATA: shift out data byte to master MSB first
                 // sda_t set at count1==100 (midpoint of pulse 1, SCL low)
                 // ensures SDA stable before SCL rises for master to sample
                 send_data : begin
                     sda_en <= 1'b1;
                              if(bitcnt <= 7)
                                 begin
                                         r_mem  <= 1'b0; // one-shot read; clear after first cycle
                                         case(pulse)
                                         0: begin    end
                                         1: begin sda_t <= (count1 == 100) ? dout[7 - bitcnt] : sda_t; end
                                         2: begin    end 
                                         3: begin    end
                                         endcase
                                         if(count1  == clk_count1*4 - 1)
                                         begin
                                            state <= send_data;
                                            bitcnt <= bitcnt + 1;
                                         end
                                         else
                                         begin
                                            state <= send_data;
                                         end
                                     
                                 end
                              else
                                begin
                                state  <= master_ack;
                                bitcnt <= 0;
                                sda_en <= 1'b0; // release SDA for master to send NACK
                                end
                     end  
                   
                   // MASTER_ACK: slave reads NACK/ACK from master after send_data
                   // NACK (r_ack=1): normal end — master has the byte (ack_err=0)
                   // ACK  (r_ack=0): unexpected — flag ack_err
                   master_ack: 
                   begin
                                   case(pulse)
                                         0: begin  end
                                         1: begin  end
                                         2: begin r_ack <= (count1 == 200) ? sda : r_ack; end 
                                         3: begin  end
                                     endcase
                                  if(count1  == clk_count1*4 - 1)
                                         begin
                                               if(r_ack == 1'b1)
                                                   begin
                                                   ack_err <= 1'b0;
                                                   state <= detect_stop;
                                                   sda_en <= 1'b0;
                                                   end
                                               else
                                                    begin
                                                    ack_err <= 1'b1;
                                                    state   <= detect_stop;
                                                    sda_en <= 1'b0;
                                                    end
                                         end
                                  else
                                       begin
                                       state <= master_ack;
                                       end
                      end
                   
                   // DETECT_STOP: wait for master STOP condition
                   // STOP occurs at pulse==3, count==399 (SDA rises while SCL high)
                   // Clears busy, asserts done, returns to idle
                   detect_stop: 
                   begin
                       if(pulse == 2'b11 && count1 == 399)
                           begin
                           state <= idle;
                           busy <= 1'b0;
                           done <= 1'b1;
                          end
                         else
                           state <= detect_stop;
                        
                   end
                   
      default: state <= idle;
      
      endcase
    end
end

// SDA tri-state driver
// sda_en=1: slave drives sda_t; sda_en=0: Hi-Z (master drives or pull-up)
assign sda = (sda_en == 1'b1) ? sda_t : 1'bz;

endmodule

//////////////// Top
`timescale 1ns / 1ps

module i2c_top(
input clk, rst, newd, op,
input [6:0] addr,
input [7:0] din,
output [7:0] dout,
output busy,ack_err,
output done
);
wire sda, scl;
wire ack_errm, ack_errs;

i2c_master master (clk, rst, newd, addr, op, sda, scl, din, dout, busy, ack_errm , done);
i2c_Slave slave (scl, clk, rst, sda, ack_errs, );

// ack_err is asserted if either master or slave reports an ACK error
assign ack_err = ack_errs | ack_errm;

endmodule

///////////////////////////////////////////////////////
interface i2c_if;
  
  logic clk;
  logic rst;
  logic newd;
  logic op;   
  logic [7:0] din;
  logic [6:0] addr;
  logic [7:0] dout;
  logic  done;
  logic busy, ack_err;  
  
endinterface

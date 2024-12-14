/***************************************************************************************

top.sv

Jackson Philion, December 13 2024, jphilion@g.hmc.edu

This file is made for taking the properly-simming modules in aes.sv and reformatting the
top level module to take in a HSOSC on the FPGA and synthesize for real downloading and
testing. See the report below for more:
  * https://jacksonphilion.github.io/hmc-e155-portfolio/labs/lab7/lab7.html

***************************************************************************************/
module top(
  input  logic sck, 
  input  logic sdi,
  output logic sdo,
  input  logic load,
  output logic done);
                    
  logic int_osc, clk;
  HSOSC hf_osc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(int_osc));
  
  always_ff @(posedge int_osc)
	clk <= ~clk;

  aes aesCall(clk, sck, sdi, sdo, load, done);

endmodule
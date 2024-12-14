/////////////////////////////////////////////
//   aes.sv
//   Top level module with SPI interface and SPI core
/////////////////////////////////////////////

module aes(
  input  logic clk,
  input  logic sck, 
  input  logic sdi,
  output logic sdo,
  input  logic load,
  output logic done);
                    
  logic [127:0] key, plaintext, cyphertext;
  
  aes_spi spi(sck, sdi, sdo, done, key, plaintext, cyphertext);   
  aes_core core(clk, load, key, plaintext, done, cyphertext);
endmodule

/////////////////////////////////////////////
// aes_spi
//   SPI interface.  Shifts in key and plaintext
//   Captures ciphertext when done, then shifts it out
//   Tricky cases to properly change sdo on negedge clk
/////////////////////////////////////////////

module aes_spi(
  input  logic sck, 
  input  logic sdi,
  output logic sdo,
  input  logic done,
  output logic [127:0] key, plaintext,
  input  logic [127:0] cyphertext);

  logic         sdodelayed, wasdone;
  logic [127:0] cyphertextcaptured;
              
  // assert load
  // apply 256 sclks to shift in key and plaintext, starting with plaintext[127]
  // then deassert load, wait until done
  // then apply 128 sclks to shift out cyphertext, starting with cyphertext[127]
  // SPI mode is equivalent to cpol = 0, cpha = 0 since data is sampled on first edge and the first
  // edge is a rising edge (clock going from low in the idle state to high).
  always_ff @(posedge sck)
    if (!wasdone)  {cyphertextcaptured, plaintext, key} = {cyphertext, plaintext[126:0], key, sdi};
    else           {cyphertextcaptured, plaintext, key} = {cyphertextcaptured[126:0], plaintext, key, sdi}; 
  
  // sdo should change on the negative edge of sck
  always_ff @(negedge sck) begin
    wasdone = done;
    sdodelayed = cyphertextcaptured[126];
  end
  
  // when done is first asserted, shift out msb before clock edge
  assign sdo = (done & !wasdone) ? cyphertext[127] : sdodelayed;
endmodule

/////////////////////////////////////////////
// aes_core
//   top level AES encryption module
//   when load is asserted, takes the current key and plaintext
//   generates cyphertext and asserts done when complete 11 cycles later
// 
//   See FIPS-197 with Nk = 4, Nb = 4, Nr = 10
//
//   The key and message are 128-bit values packed into an array of 16 bytes as
//   shown below
//        [127:120] [95:88] [63:56] [31:24]     S0,0    S0,1    S0,2    S0,3
//        [119:112] [87:80] [55:48] [23:16]     S1,0    S1,1    S1,2    S1,3
//        [111:104] [79:72] [47:40] [15:8]      S2,0    S2,1    S2,2    S2,3
//        [103:96]  [71:64] [39:32] [7:0]       S3,0    S3,1    S3,2    S3,3
//
//   Equivalently, the values are packed into four words as given
//        [127:96]  [95:64] [63:32] [31:0]      w[0]    w[1]    w[2]    w[3]
/////////////////////////////////////////////

module aes_core(
  input  logic         clk, 
  input  logic         load,
  input  logic [127:0] key, 
  input  logic [127:0] plaintext, 
  output logic         done, 
  output logic [127:0] cyphertext);

  // create internal variables
  logic [127:0] stateOut, stateIn;
  logic [127:0] addKeyOut, mixColOut, shiftRowOut, subByteOut;
  logic [2:0] muxNextState;
  logic enState;
  
  logic addroundkeyStart, addroundkeyDone;
  logic [3:0] roundNumber;

  logic reset;
  assign reset = 1;

  // mux before state register
  always_comb
    case (muxNextState)
      3'b000:   stateIn = plaintext;
      3'b001:   stateIn = addKeyOut;
      3'b010:   stateIn = mixColOut;
      3'b011:   stateIn = shiftRowOut;
      3'b100:   stateIn = subByteOut;
      default:  stateIn = plaintext;
    endcase

  // state Register
  always_ff @(posedge clk)
    if (enState)
      stateOut <= stateIn;

  // Main Function Block Calls and Output
  shiftrows shiftRowsCall(stateOut, shiftRowOut);
  mixcolumns mixColCall(stateOut, mixColOut);
  sub_byte subByteCall(clk, reset, stateOut, subByteOut);
  addroundkey addKeyCall(clk, reset, addroundkeyStart, key, roundNumber, stateOut, addKeyOut, addroundkeyDone);
  assign cyphertext = stateOut;
  
  // core_fsm
  core_fsm coreFSMcall(clk, reset, load, addroundkeyDone, addroundkeyStart, done, roundNumber, muxNextState, enState);
endmodule

/////////////////////////////////////////////
// core_fsm
//   controls the mux and enable variables which
//   drive the aes core, dictating the order of
//   operations and tracking the round number.
/////////////////////////////////////////////

module core_fsm(
  input logic clk, reset,
  input logic load,
  input logic addroundkeyDone,
  output logic addroundkeyStart,
  output logic done,
  output logic [3:0] roundNumber,
  output logic [2:0] muxNextState,
  output logic enState
);

  // Create the state and nextstate variables
  typedef enum logic [3:0] {core_idle, core_storeState, core_firstKey,
    core_subBytes, core_shiftRows, core_mixCols, core_addKey,
    core_lastSub, core_lastShift, core_lastKey, core_finish} core_fsm_statetype;
  core_fsm_statetype state_core, nextstate_core;

  logic firstCycle, lastLoad;

  ////////////////////////  Registers  //////////////////////////////////
  always_ff @(posedge clk) begin
    if (reset) //Active low reset, so if no reset
      state_core <= nextstate_core;
    else
      state_core <= core_idle;
  
    if (nextstate_core==core_storeState) 
      roundNumber <= 0;
    
    if (state_core!==nextstate_core) begin
      firstCycle <= 1;
      if ((nextstate_core==core_addKey)|(nextstate_core==core_lastKey)) begin
        addroundkeyStart <= 1;
        roundNumber <= roundNumber + 1; end
      if (nextstate_core==core_firstKey)
        addroundkeyStart <= 1; end
    else begin
      addroundkeyStart <= 0;
      firstCycle <= 0; end

    lastLoad <= load;
  end

  ////////////////////////  Next State Logic  ////////////////////////////
  always_comb
    case (state_core)
      core_idle:        if ((!load)&(lastLoad)) nextstate_core = core_storeState;
                        else nextstate_core = core_idle;
      core_storeState:  nextstate_core = core_firstKey;
      core_firstKey:    if (enState) nextstate_core = core_subBytes;
                        else nextstate_core = core_firstKey;
      core_subBytes:    if (firstCycle) nextstate_core = core_subBytes;
                        else nextstate_core = core_shiftRows;
      core_shiftRows:   nextstate_core = core_mixCols;
      core_mixCols:     nextstate_core = core_addKey;
      core_addKey:      if (enState)
                          if (roundNumber<9) nextstate_core = core_subBytes;
                          else nextstate_core = core_lastSub;
                        else nextstate_core = core_addKey;
      core_lastSub:     if (firstCycle) nextstate_core = core_lastSub;
                        else nextstate_core = core_lastShift;
      core_lastShift:   nextstate_core = core_lastKey;
      core_lastKey:     if (enState) nextstate_core = core_finish;
                        else nextstate_core = core_lastKey;
      core_finish:      nextstate_core = core_finish;
      default:          nextstate_core = core_idle;
    endcase

  ////////////////////////  Output Logic  ////////////////////////////
  always_comb
    case (state_core)
      core_idle:        begin done = 0; muxNextState = 3'b000; enState = 0; end
      core_storeState:  begin done = 0; muxNextState = 3'b000; enState = 1; end
      core_firstKey:    begin done = 0; muxNextState = 3'b001; if (addroundkeyDone) enState=1; else enState=0; end
      core_subBytes:    begin done = 0; muxNextState = 3'b100; if (firstCycle) enState=0; else enState=1; end
      core_shiftRows:   begin done = 0; muxNextState = 3'b011; enState = 1; end
      core_mixCols:     begin done = 0; muxNextState = 3'b010; enState = 1; end
      core_addKey:      begin done = 0; muxNextState = 3'b001; if (addroundkeyDone) enState=1; else enState=0; end
      core_lastSub:     begin done = 0; muxNextState = 3'b100; if (firstCycle) enState=0; else enState=1; end
      core_lastShift:   begin done = 0; muxNextState = 3'b011; enState = 1; end
      core_lastKey:     begin done = 0; muxNextState = 3'b001; if (addroundkeyDone) enState=1; else enState=0; end
      core_finish:      begin done = 1; muxNextState = 3'b000; enState = 0; end
      default:          begin done = 0; muxNextState = 3'b000; enState = 0; end
    endcase
endmodule

/////////////////////////////////////////////
// sub_bytes
//   takes in the 16 bytes of current state and subs
//   each byte out for its substitute at the same time.
//   Should be a delay cycle between in and out 
/////////////////////////////////////////////

`define a0 a[127:120]
`define a1 a[119:112]
`define a2 a[111:104]
`define a3 a[103:96]
`define a4 a[95:88]
`define a5 a[87:80]
`define a6 a[79:72]
`define a7 a[71:64]
`define a8 a[63:56]
`define a9 a[55:48]
`define a10 a[47:40]
`define a11 a[39:32]
`define a12 a[31:24]
`define a13 a[23:16]
`define a14 a[15:8]
`define a15 a[7:0]

`define y0 y[127:120]
`define y1 y[119:112]
`define y2 y[111:104]
`define y3 y[103:96]
`define y4 y[95:88]
`define y5 y[87:80]
`define y6 y[79:72]
`define y7 y[71:64]
`define y8 y[63:56]
`define y9 y[55:48]
`define y10 y[47:40]
`define y11 y[39:32]
`define y12 y[31:24]
`define y13 y[23:16]
`define y14 y[15:8]
`define y15 y[7:0]

module sub_byte(
  input logic clk, reset,
  input logic [127:0] a,
  output logic [127:0] y);

  sbox_sync sbox0Call(`a0, clk, `y0);
  sbox_sync sbox1Call(`a1, clk, `y1);
  sbox_sync sbox2Call(`a2, clk, `y2);
  sbox_sync sbox3Call(`a3, clk, `y3);

  sbox_sync sbox4Call(`a4, clk, `y4);
  sbox_sync sbox5Call(`a5, clk, `y5);
  sbox_sync sbox6Call(`a6, clk, `y6);
  sbox_sync sbox7Call(`a7, clk, `y7);

  sbox_sync sbox8Call(`a8, clk, `y8);
  sbox_sync sbox9Call(`a9, clk, `y9);
  sbox_sync sbox10Call(`a10, clk, `y10);
  sbox_sync sbox11Call(`a11, clk, `y11);
  
  sbox_sync sbox12Call(`a12, clk, `y12);
  sbox_sync sbox13Call(`a13, clk, `y13);
  sbox_sync sbox14Call(`a14, clk, `y14);
  sbox_sync sbox15Call(`a15, clk, `y15);
endmodule

/////////////////////////////////////////////
// addroundkey
//   Adds Round Key. Uses key scheduler to generate
//   a new key, then xors current state with keyout
/////////////////////////////////////////////

module addroundkey(
  input logic clk, reset,
  input logic addroundkeyStart,
  input logic [127:0] originalKeyIn,
  input logic [3:0] roundNumber,
  input logic [127:0] stateOut,
  output logic [127:0] addKeyOut,
  output logic addroundkeyDone);

  logic [127:0] keyOut;
  logic generatedKey;

  // Add one cycle delay between key being generated and addroundkey being considered done
  always_ff @(posedge clk)
    addroundkeyDone <= generatedKey;

  // Call to key_schedule module
  key_schedule  key_schedule_Call(clk, reset, originalKeyIn, roundNumber, addroundkeyStart, keyOut, generatedKey);

  // bitwise xor that adds the generated round key
  assign addKeyOut = stateOut ^ keyOut;
endmodule

/////////////////////////////////////////////
// key_schedule
//   Key Scheduler. Takes in the original key and iterates
//   upon it to create the subsequent round keys.
//   Requires key_fsm to operate the control signals.
/////////////////////////////////////////////

module key_schedule(input logic clk, reset,
                    input logic [127:0] originalKeyIn,
                    input logic [3:0] roundNumber,
                    input logic genKey,
                    output  logic [127:0] currentKeyOut,
                    output logic generatedKey);

  logic [127:0] nextKey, currentKeyIn;
  logic [31:0] nextWord0in, nextWord0out, nextWord1, nextWord2, nextWord3, rotWordOut, xor3out, subWordOut;
  logic [7:0] subw0, subw1, subw2, subw3;

  logic muxCurrentKey, enCurrentKey, enNextWord0;
  logic [1:0] muxNextWord0;

  // Separate key_fsm Module
  key_fsm keyFSMcall(clk, reset, genKey, roundNumber, enCurrentKey, enNextWord0, muxCurrentKey, muxNextWord0, generatedKey);

  // CL block which combines all the next words into the next key
  assign nextKey = {nextWord0out, nextWord1, nextWord2, nextWord3};

  // Mux heading into currentKey register
  always_comb
    case (muxCurrentKey)
      1'b0:  currentKeyIn = originalKeyIn;
      1'b1:  currentKeyIn = nextKey;
      default: currentKeyIn = originalKeyIn;
    endcase

  // currentKey Register
  always_ff @(posedge clk)
    if (enCurrentKey)
      currentKeyOut <= currentKeyIn;

  // mux before nextWord0 Register
  logic [31:0] currentLowWord;
  assign currentLowWord = currentKeyOut[31:0];
  always_comb
    case (muxNextWord0)
      2'b00:    nextWord0in = currentLowWord;
      2'b01:    nextWord0in = rotWordOut;
      2'b10:    nextWord0in = xor3out;
      2'b11:    nextWord0in = subWordOut;
      default:  nextWord0in = currentLowWord;
    endcase

  // nextWord0 Register
  always_ff @(posedge clk)
    if (enNextWord0)
      nextWord0out <= nextWord0in;

  // rotWord CL block
  assign rotWordOut = { nextWord0out[23:16], nextWord0out[15:8], nextWord0out[7:0], nextWord0out[31:24]};

  // Call to the xor3out module (as seen below)
  xor3_module xor3call(roundNumber, nextWord0out, currentKeyOut[127:96], xor3out);

  // sbox Logic
  sbox_sync sbox0(nextWord0out[31:24], clk, subw0);
  sbox_sync sbox1(nextWord0out[23:16], clk, subw1);
  sbox_sync sbox2(nextWord0out[15:8], clk, subw2);
  sbox_sync sbox3(nextWord0out[7:0], clk, subw3);

  // combine subbed bytes into subWordOut
  assign subWordOut = {subw0, subw1, subw2, subw3};

  // CL blocks to now do words 1-3
  assign nextWord1 = nextWord0out ^ currentKeyOut[95:64];
  assign nextWord2 = nextWord1 ^ currentKeyOut[63:32];
  assign nextWord3 = nextWord2 ^ currentKeyOut[31:0];
endmodule

module xor3_module(
  input logic [3:0] roundNumber,
  input logic [31:0] nextWord0out,
  input logic [31:0] partialCurrentKeyOut,
  output logic [31:0] xor3out);

  logic [31:0] rconhex;
  logic [7:0] k;

  assign rconhex = {k,8'h00,8'h00,8'h00};

  always_comb
    case (roundNumber)
      4'd0:     k = 8'h00;
      4'd1:     k = 8'h01;
      4'd2:     k = 8'h02;
      4'd3:     k = 8'h04;
      4'd4:     k = 8'h08;
      4'd5:     k = 8'h10;
      4'd6:     k = 8'h20;
      4'd7:     k = 8'h40;
      4'd8:     k = 8'h80;
      4'd9:     k = 8'h1b;
      4'd10:    k = 8'h36;
      default:  k = 8'h00;
    endcase

  assign xor3out = nextWord0out ^ partialCurrentKeyOut ^ rconhex;
endmodule

module key_fsm(
  input logic clk,
  input logic reset,
  input logic genKey,
  input logic [3:0] roundNumber,
  output logic enCurrentKey,
  output logic enNextWord0,
  output logic muxCurrentKey,
  output logic [1:0] muxNextWord0,
  output logic generatedKey);

  // Create the state and nextstate variables
  typedef enum logic [3:0] {key_idle,
  key_sendOriginal, key_finished, key_rotWord, key_startSub,
  key_storeSub, key_xor, key_delay, key_sendNext} key_fsm_statetype;

  key_fsm_statetype state_key, nextstate_key;

  ////////////////////////  State Registers  ////////////////////////////
  always_ff @(posedge clk)
    if (reset) //Active low reset, so if no reset
      state_key <= nextstate_key;
    else
      state_key <= key_idle;

  ////////////////////////  Next State Logic  ////////////////////////////
  always_comb
    case (state_key)
      key_idle:         if (genKey) begin
                          if (!roundNumber) nextstate_key = key_sendOriginal;
                          else nextstate_key = key_rotWord; 
                        end
                        else nextstate_key = key_idle;
      key_rotWord:      nextstate_key = key_startSub;
      key_startSub:     nextstate_key = key_storeSub;
      key_storeSub:     nextstate_key = key_xor;
      key_xor:          nextstate_key = key_delay;
      key_delay:        nextstate_key = key_sendNext;
      key_sendNext:     nextstate_key = key_finished;
      key_sendOriginal: nextstate_key = key_finished;
      key_finished:     nextstate_key = key_idle;
      default:          nextstate_key = key_idle;
    endcase

  ////////////////////////  Output Logic  ////////////////////////////
  always_comb
    case (state_key)
      key_idle:         begin enCurrentKey = 0; enNextWord0 = 0; muxCurrentKey = 0; muxNextWord0 = 2'b00; generatedKey = 0; end
      key_rotWord:      begin enCurrentKey = 0; enNextWord0 = 1; muxCurrentKey = 0; muxNextWord0 = 2'b01; generatedKey = 0; end
      key_startSub:     begin enCurrentKey = 0; enNextWord0 = 0; muxCurrentKey = 0; muxNextWord0 = 2'b11; generatedKey = 0; end
      key_storeSub:     begin enCurrentKey = 0; enNextWord0 = 1; muxCurrentKey = 0; muxNextWord0 = 2'b11; generatedKey = 0; end
      key_xor:          begin enCurrentKey = 0; enNextWord0 = 1; muxCurrentKey = 0; muxNextWord0 = 2'b10; generatedKey = 0; end
      key_delay:        begin enCurrentKey = 0; enNextWord0 = 0; muxCurrentKey = 0; muxNextWord0 = 2'b00; generatedKey = 0; end
      key_sendNext:     begin enCurrentKey = 1; enNextWord0 = 0; muxCurrentKey = 1; muxNextWord0 = 2'b00; generatedKey = 0; end
      key_sendOriginal: begin enCurrentKey = 1; enNextWord0 = 0; muxCurrentKey = 0; muxNextWord0 = 2'b00; generatedKey = 0; end
      key_finished:     begin enCurrentKey = 0; enNextWord0 = 1; muxCurrentKey = 0; muxNextWord0 = 2'b00; generatedKey = 1; end
      default:          begin enCurrentKey = 0; enNextWord0 = 0; muxCurrentKey = 0; muxNextWord0 = 2'b00; generatedKey = 0; end
    endcase
endmodule

/////////////////////////////////////////////
// sbox
//   Infamous AES byte substitutions with magic numbers
//   Combinational version which is mapped to LUTs (logic cells)
//   Section 5.1.1, Figure 7
/////////////////////////////////////////////

module sbox(input  logic [7:0] a,
            output logic [7:0] y);
            
  // sbox implemented as a ROM
  // This module is combinational and will be inferred using LUTs (logic cells)
  logic [7:0] sbox[0:255];

  initial   $readmemh("sbox.txt", sbox);
  assign y = sbox[a];
endmodule

/////////////////////////////////////////////
// sbox
//   Infamous AES byte substitutions with magic numbers
//   Synchronous version which is mapped to embedded block RAMs (EBR)
//   Section 5.1.1, Figure 7
/////////////////////////////////////////////

module sbox_sync(
	input		logic [7:0] a,
	input	 	logic 			clk,
	output 	logic [7:0] y);
            
  // sbox implemented as a ROM
  // This module is synchronous and will be inferred using BRAMs (Block RAMs)
  logic [7:0] sbox [0:255];

  initial   $readmemh("sbox.txt", sbox);
	
	// Synchronous version
	always_ff @(posedge clk) begin
		y <= sbox[a];
	end
endmodule

/////////////////////////////////////////////
// shiftrows
//   rotate each row according to the state matrix
//   Section 5.1.2
/////////////////////////////////////////////

module shiftrows(input logic [127:0] a,
                output logic [127:0] y);
  // see above for define statements
  assign y = {`a0, `a5, `a10, `a15, `a4, `a9, `a14, `a3, `a8, `a13, `a2, `a7, `a12, `a1, `a6, `a11};
endmodule

/////////////////////////////////////////////
// mixcolumns
//   Even funkier action on columns
//   Section 5.1.3, Figure 9
//   Same operation performed on each of four columns
/////////////////////////////////////////////

module mixcolumns(input  logic [127:0] a,
                  output logic [127:0] y);

  mixcolumn mc0(a[127:96], y[127:96]);
  mixcolumn mc1(a[95:64],  y[95:64]);
  mixcolumn mc2(a[63:32],  y[63:32]);
  mixcolumn mc3(a[31:0],   y[31:0]);
endmodule

/////////////////////////////////////////////
// mixcolumn
//   Perform Galois field operations on bytes in a column
//   See EQ(4) from E. Ahmed et al, Lightweight Mix Columns Implementation for AES, AIC09
//   for this hardware implementation
/////////////////////////////////////////////

module mixcolumn(input  logic [31:0] a,
                 output logic [31:0] y);
                      
        logic [7:0] a0, a1, a2, a3, y0, y1, y2, y3, t0, t1, t2, t3, tmp;
        
        assign {a0, a1, a2, a3} = a;
        assign tmp = a0 ^ a1 ^ a2 ^ a3;
    
        galoismult gm0(a0^a1, t0);
        galoismult gm1(a1^a2, t1);
        galoismult gm2(a2^a3, t2);
        galoismult gm3(a3^a0, t3);
        
        assign y0 = a0 ^ tmp ^ t0;
        assign y1 = a1 ^ tmp ^ t1;
        assign y2 = a2 ^ tmp ^ t2;
        assign y3 = a3 ^ tmp ^ t3;
        assign y = {y0, y1, y2, y3};    
endmodule

/////////////////////////////////////////////
// galoismult
//   Multiply by x in GF(2^8) is a left shift
//   followed by an XOR if the result overflows
//   Uses irreducible polynomial x^8+x^4+x^3+x+1 = 00011011
/////////////////////////////////////////////

module galoismult(input  logic [7:0] a,
                  output logic [7:0] y);

    logic [7:0] ashift;
    
    assign ashift = {a[6:0], 1'b0};
    assign y = a[7] ? (ashift ^ 8'b00011011) : ashift;
endmodule
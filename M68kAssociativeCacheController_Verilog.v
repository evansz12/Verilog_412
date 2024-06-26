///////////////////////////////////////////////////////////////////////////////////////
// Simple Associative Cache controller
//
// designed to work with TG68 (68000 based) cpu with 16 bit data bus and 32 bit address bus
// separate upper and lowe data stobes for individual byte and also 16 bit word access
//
// Copyright PJ Davies August 2017
///////////////////////////////////////////////////////////////////////////////////////


module M68kAssociativeCacheController_Verilog (
		input Clock,															// used to drive the state machine - state changes occur on positive edge
		input Reset_L,    													// active low reset 

		// signals to 68k
		
		input DramSelect68k_H, 												// active high signal indicating Dram is being addressed by 68000
		input unsigned [31:0] AddressBusInFrom68k,					// address bus from 68000
		input unsigned [15:0] DataBusInFrom68k,  						// data bus in from 68000
		output reg unsigned [15:0] DataBusOutTo68k,  				// data bus out from Cache controller back to 68000 (during read)
		input UDS_L,	   													// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
		input LDS_L,	   													// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
		input WE_L, 															// active low write signal, otherwise assumed to be read
		input AS_L,									
		input DtackFromDram_L,												// dtack back from Dram
		input CAS_Dram_L,														// cas to Dram so we can count 2 clock delays before 1st data
		input RAS_Dram_L,														// so we can detect difference between a read and a refresh command

		input unsigned [15:0] DataBusInFromDram, 						// data bus in from Dram
		output reg unsigned [15:0] DataBusOutToDramController,	// data bus out to Dram (during write)
		input unsigned [15:0] DataBusInFromCache,						// data bus in from Cache
		
		output reg UDS_DramController_L,									// active low signal driven by 68000 when 68000 transferring data over data bit 7-0
		output reg LDS_DramController_L,									// active low signal driven by 68000 when 68000 transferring data over data bit 15-8
		output reg DramSelectFromCache_L,	
		output reg WE_DramController_L,									// active low Dram controller write signal
		output reg AS_DramController_L,
		output reg DtackTo68k_L,											// Dtack back to 68k at end of operation
		
		// Cache memory write signals
		output reg unsigned [7:0] TagCache_WE_L,						// 8 bits for 8 blocks to store an address in Cache
		output reg unsigned [7:0] DataCache_WE_L,						// 8 bits for 8 blocks to store data in Cache
		output reg unsigned [7:0] ValidBit_WE_L,						// 8 bits for 8 blocks to store a valid bit
		
		output reg unsigned [31:0] AddressBusOutToDramController,	// address bus from Cache to Dram controller
		output reg unsigned [20:0] TagDataOut,								// 21 bit address to store in the tag Cache
		output reg unsigned [2:0] WordAddress,								// upto 8 words in a Cache line
		output reg ValidBitOut_H,												// indicates the cache line is valid
		output reg unsigned [6:0] Index,										// 3 bit Line for 8 
	
		input unsigned [7:0] ValidHit_H,									// indicates if any block in valid and a hit for the set
		input unsigned [7:0] Valid_H,										// indicates if any block in valid
		input unsigned [6:0] LRUBits_In,	
		output reg unsigned [6:0] LRUBits_Out,	
		output reg LRU_WE_L,

		// debugging only
		output unsigned [4:0] CacheState	
	);



/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// States
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	parameter	Reset								= 5'b00000;								
	parameter	InvalidateCache 				= 5'b00001;
	parameter 	Idle 								= 5'b00010;
	parameter	CheckForCacheHit 				= 5'b00011;	
	parameter	ReadDataFromDramIntoCache	= 5'b00100;
	parameter	CASDelay1 						= 5'b00101;
	parameter	CASDelay2 						= 5'b00110;
	parameter	BurstFill 						= 5'b00111;
	parameter	EndBurstFill 					= 5'b01000;
	parameter	WriteDataToDram 				= 5'b01001;
	parameter	WaitForEndOfCacheRead		= 5'b01010;
	
	// 5 bit variables to hold current and next state of the state machine
	reg unsigned [4:0] CurrentState;					// holds the current state of the Cache controller
	reg unsigned [4:0] NextState; 						// holds the next state of the Cache controller
	
	// counter for the read burst fill
	reg unsigned [15:0] BurstCounter;					// counts for at least 8 during a burst Dram read also counts lines when flusing the cache
	reg BurstCounterReset_L;								// reset for the above counter
	
	// 2 bit register to hold the block number and a signla to store it 
	reg unsigned [2:0] ReplaceBlockNumber;				// register to hold the number of the block/way where new cache data will be loaded
	reg unsigned [2:0] ReplaceBlockNumberData;		// data to store in the above register
	reg LoadReplacementBlockNumber_H;					// signal to load the replceblocknumber with the new data above
	
	// signals for the least recently used bits utilised in cache replacement policy
	reg  LRUBits_Load_H;
	reg  unsigned [6:0]  LRUBits;

	
	
	// start
	assign CacheState = CurrentState;								// for debugging purposes only

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// concurrent process state registers
// this process RECORDS the current state of the system.
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
   always@(posedge Clock, negedge Reset_L)
	begin
		if(Reset_L == 0)
			CurrentState <= Reset ;
		else
			CurrentState <= NextState;	
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Burst read counter: Used to provide a 3 bit address to the Data in the Cache during burst reads from Dram
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always@(posedge Clock)
	begin
		if(BurstCounterReset_L == 0) 						// synchronous reset
			BurstCounter <= 16'b0000000000000000 ;
		else
			BurstCounter <= BurstCounter + 1;			// else count
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// register to store the Set Replacement Number/Block: Used to provide a 2 bit address to select a way/block
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

	always@(posedge Clock)
	begin
		if(LoadReplacementBlockNumber_H == 1) 
			ReplaceBlockNumber <= ReplaceBlockNumberData;			// store the chosen block number
	end
	
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// register to store the LRU block bits:
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	

	always@(posedge Clock)
	begin
		if(LRUBits_Load_H == 1)
			LRUBits	<= LRUBits_In;			// store the chosen block number
	end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// next state and output logic
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////	
	
	always@(*)
	begin
		// start with default inactive values for everything and override as necessary, so we do not infer storage for signals inside this process
	
		DataBusOutTo68k 					<= DataBusInFromCache;
		DataBusOutToDramController 	<= DataBusInFrom68k;

		// default is to give the Dram the 68k's signals directly (unless we want to change something)	
		
		AddressBusOutToDramController[31:4]	<= AddressBusInFrom68k[31:4];
		AddressBusOutToDramController[3:1]	<= 3'b000;								// all reads to Dram have lower 3 address lines set to 0 for a Cache line regardless of 68k address
		AddressBusOutToDramController[0] 	<= 0;										// to avoid inferring a latch for this bit
		
		TagDataOut							<= AddressBusInFrom68k[31:11];				// tag is 21 bits
		Index									<= AddressBusInFrom68k[10:4];				// cache Line is 7 bits for 128 Lines 4 way cache
		
		UDS_DramController_L				<= UDS_L;
		LDS_DramController_L	   		<= LDS_L;
		WE_DramController_L 				<= WE_L;
		AS_DramController_L				<= AS_L;
		
		DtackTo68k_L						<= 1;												// don't supply until we are ready
		TagCache_WE_L 						<= 8'b11111111;										// don't write Cache address to any block
		DataCache_WE_L 					<= 8'b11111111;										// don't write Cache data to any block
		ValidBit_WE_L						<= 8'b11111111;										// don't write valid data to any block
		ValidBitOut_H						<= 0;												// line invalid
		DramSelectFromCache_L 			<= 1;												// don't give the Dram controller a select signal since we might not always want to cycle the Dram if we have a hit during a read
		WordAddress							<= 3'b000;										// default is byte 0 in 8 byte Cache line	
		
		BurstCounterReset_L 				<= 1;												// default is that burst counter can run (and wrap around if needed), we'll control when to reset it		
		
		ReplaceBlockNumberData 			<= 3'b000;			
		LoadReplacementBlockNumber_H 	<= 0 ;											// don't latch by default
		LRUBits_Out							<= 7'b0000000;
		LRU_WE_L								<= 1;												// dont write	
		LRUBits_Load_H						<= 0;
		
		NextState 							<= Idle ;										// default is to go to this state
			
//////////////////////////////////////////////////////////////////
// Initial State following a reset
//////////////////////////////////////////////////////////////////
		
		if(CurrentState == Reset) 	begin	  												// if we are in the Reset state				
			BurstCounterReset_L 	<= 0;														// reset the burst counter (synchronously)
			NextState				<= InvalidateCache;									// go invalidate the cache
		end

///////////////////////////////////////////////////////////////////////////////////////////////////////////
// This state will invalidate the cache before entering idle state and go through each set clearing each block
///////////////////////////////////////////////////////////////////////////////////////////////////////////	

		else if(CurrentState == InvalidateCache) begin	  						
			
			// burst counter should now be 0 when we first enter this state, as it was reset in state above
			if(BurstCounter == 128) 														// if we have done all cache lines
				NextState 						<= Idle;
			
			else begin
				NextState						<= InvalidateCache;					// assume we stay here
				Index	 							<= BurstCounter[6:0];				// 7 bit Line address for Index for 128 set/lines of cache
				
				// clear the validity bits for each cache
				ValidBitOut_H 					<=	0;		
				ValidBit_WE_L					<= 8'b00000000;
				
				// clear the address tags for each cache set
				TagDataOut						<= 21'b000000000000000000000;	
				TagCache_WE_L					<= 8'b00000000;							// clear all tag bits in each Line
				
				// clear the LRU bits for each cache Line
				LRUBits_Out						<= 7'b0000000;
				LRU_WE_L							<= 0;
			end
		end

///////////////////////////////////////////////
// Main IDLE state: 
///////////////////////////////////////////////

		else if(CurrentState == Idle) begin									// if we are in the idle state				
			if (AS_L == 0 && DramSelect68k_H == 1) begin
				LRUBits_Load_H <= 1;
				if (WE_L == 1) begin //read
					UDS_DramController_L <= 0;
					LDS_DramController_L <= 0;
					NextState <= CheckForCacheHit;
				end
				else begin 				//write
					ValidBitOut_H <= 0;
					if (ValidHit_H > 0) begin	//if any bits are 1, write 0 to corresponding ValidBit_WE_L bit; 	
						ValidBit_WE_L <= {~ValidHit_H[7], ~ValidHit_H[6], ~ValidHit_H[5], ~ValidHit_H[4], ~ValidHit_H[3], ~ValidHit_H[2], ~ValidHit_H[1], ~ValidHit_H[0]};
					end
					DramSelectFromCache_L <= 0;
					NextState <= WriteDataToDram;
				end
			end
		end
		
////////////////////////////////////////////////////////////////////////////////////////////////////
// Check if we have a Cache HIT. If so give data to 68k or if not, go generate a burst fill
// update the Least Recently Used Bits (LRUBits)
////////////////////////////////////////////////////////////////////////////////////////////////////

		else if(CurrentState == CheckForCacheHit) begin				// we are looking for a Cache hit			
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			LRU_WE_L <= 0;
			if (ValidHit_H > 0) begin   //valid hit, get from cache, and update LRU
				WordAddress <= AddressBusInFrom68k[3:1];
				DtackTo68k_L <= 0;
				NextState <= WaitForEndOfCacheRead;
				if (LRUBits[2:0] == 3'b000) begin  //block 0. xxxx000
					LRUBits_Out <= {LRUBits[6:3], 3'b111};
				end 
				else if (LRUBits[2:0] == 3'b100)begin  //block 1, xxxx100
					LRUBits_Out <= {LRUBits[6:3], 3'b011};
				end
				else if (LRUBits[1:0] == 2'b10 && LRUBits[3] == 0)begin //block 2, xxx0x10
					LRUBits_Out <= {LRUBits[6:4], 1'b1, LRUBits[2], 2'b01};	
				end
				else if (LRUBits[1:0] == 2'b10 && LRUBits[3] == 1)begin //block 3, xxx1x10
					LRUBits_Out <= {LRUBits[6:4], 1'b0, LRUBits[2], 2'b01};	
				end
				else if (LRUBits[5:4] == 2'b00 && LRUBits[0] == 1)begin //block 4, x00xxx1
					LRUBits_Out <= {LRUBits[6], 2'b11, LRUBits[3:1], 1'b0};	
				end
				else if (LRUBits[5:4] == 2'b10 && LRUBits[0] == 1)begin //block 5, x10xxx1
					LRUBits_Out <= {LRUBits[6], 3'b01, LRUBits[3:1], 1'b0};	
				end
				else if (LRUBits[6] == 0 && LRUBits[4] == 1 && LRUBits[0] == 1)begin //block 6, 0x1xxx1
					LRUBits_Out <= {1'b1, LRUBits[5], 1'b0, LRUBits[3:1], 1'b0};	
				end
				else begin																//block 7, 1x1xxx1
					LRUBits_Out <= {1'b0, LRUBits[5], 1'b0, LRUBits[3:1], 1'b0};	
				end				
			end
			else begin 			//no hit, get from dram, and update LRU 
				DramSelectFromCache_L <= 0;
				if (LRUBits[2:0] == 3'b000) begin  //block 0. xxxx000
					LRUBits_Out <= {LRUBits[6:3], 3'b111};
					ReplaceBlockNumberData <= 3'b00;
				end 
				else if (LRUBits[2:0] == 3'b100)begin  //block 1, xxxx100
					LRUBits_Out <= {LRUBits[6:3], 3'b011};
					ReplaceBlockNumberData <= 3'b001;
				end
				else if (LRUBits[1:0] == 2'b10 && LRUBits[3] == 0)begin //block 2, xxx0x10
					LRUBits_Out <= {LRUBits[6:4], 1'b1, LRUBits[2], 2'b01};	
					ReplaceBlockNumberData <= 3'b010;
				end
				else if (LRUBits[1:0] == 2'b10 && LRUBits[3] == 1)begin //block 3, xxx1x10
					LRUBits_Out <= {LRUBits[6:4], 1'b0, LRUBits[2], 2'b01};	
					ReplaceBlockNumberData <= 3'b011;
				end
				else if (LRUBits[5:4] == 2'b00 && LRUBits[0] == 1)begin //block 4, x00xxx1
					LRUBits_Out <= {LRUBits[6], 2'b11, LRUBits[3:1], 1'b0};	
					ReplaceBlockNumberData <= 3'b100;
				end
				else if (LRUBits[5:4] == 2'b10 && LRUBits[0] == 1)begin //block 5, x10xxx1
					LRUBits_Out <= {LRUBits[6], 3'b01, LRUBits[3:1], 1'b0};	
					ReplaceBlockNumberData <= 3'b101;
				end
				else if (LRUBits[6] == 0 && LRUBits[4] == 1 && LRUBits[0] == 1)begin //block 6, 0x1xxx1
					LRUBits_Out <= {1'b1, LRUBits[5], 1'b0, LRUBits[3:1], 1'b0};	
					ReplaceBlockNumberData <= 3'b110;
				end
				else begin																//block 7, 1x1xxx1
					LRUBits_Out <= {1'b0, LRUBits[5], 1'b0, LRUBits[3:1], 1'b0};	
					ReplaceBlockNumberData <= 3'b111;
				end					
				LoadReplacementBlockNumber_H <= 1;
				NextState <= ReadDataFromDramIntoCache;
			end
		end

///////////////////////////////////////////////////////////////////////////////////////////////
// Got a Cache hit, so give the 68k the Cache data now then wait for the 68k to end bus cycle 
///////////////////////////////////////////////////////////////////////////////////////////////

		else if(CurrentState == WaitForEndOfCacheRead) begin		
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			WordAddress <= AddressBusInFrom68k[3:1];
			DtackTo68k_L <= 0;
			if (AS_L == 0) 
				NextState <= WaitForEndOfCacheRead;
		end
			
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Didn't get a cache hit during read so
// Start of operation to Read from Dram State : Remember that CAS latency is 2 clocks before 1st item of burst data appears
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

		else if(CurrentState == ReadDataFromDramIntoCache) begin
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			DramSelectFromCache_L <= 0;
			NextState <= ReadDataFromDramIntoCache;
			if (CAS_Dram_L == 0 && RAS_Dram_L == 1) 
				NextState <= CASDelay1;
			ValidBitOut_H <= 1;
			if (ReplaceBlockNumber == 3'b000) begin	//block 0
				TagCache_WE_L <= 8'b11111110;				//write enabled for tag block 0
				ValidBit_WE_L <= 8'b11111110;				//write enabled for valid block 0
			end
			else if (ReplaceBlockNumber == 3'b001) begin  //block 1
				TagCache_WE_L <= 8'b11111101;
				ValidBit_WE_L <= 8'b11111101;
			end
			else if (ReplaceBlockNumber == 3'b010) begin  //block 2
				TagCache_WE_L <= 8'b11111011;
				ValidBit_WE_L <= 8'b11111011;
			end
			else if (ReplaceBlockNumber == 3'b011) begin  //block 3
				TagCache_WE_L <= 8'b11110111;
				ValidBit_WE_L <= 8'b11110111;
			end
			else if (ReplaceBlockNumber == 3'b100) begin  //block 4
				TagCache_WE_L <= 8'b11101111;
				ValidBit_WE_L <= 8'b11101111;
			end
			else if (ReplaceBlockNumber == 3'b101) begin  //block 5
				TagCache_WE_L <= 8'b11011111;
				ValidBit_WE_L <= 8'b11011111;
			end
			else if (ReplaceBlockNumber == 3'b110) begin  //block 6
				TagCache_WE_L <= 8'b10111111;
				ValidBit_WE_L <= 8'b10111111;
			end
			else begin												//block 7
				TagCache_WE_L <= 8'b01111111;
				ValidBit_WE_L <= 8'b01111111;
			end
		end
						
///////////////////////////////////////////////////////////////////////////////////////
// Wait for 1st CAS clock (latency)
///////////////////////////////////////////////////////////////////////////////////////
			
		else if(CurrentState == CASDelay1) begin						
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			DramSelectFromCache_L <= 0;
			NextState <= CASDelay2;
		end
		
///////////////////////////////////////////////////////////////////////////////////////
// Wait for 2nd CAS Clock Latency
///////////////////////////////////////////////////////////////////////////////////////
			
		else if(CurrentState == CASDelay2) begin						
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			DramSelectFromCache_L <= 0;
			BurstCounterReset_L <= 0;
			NextState <= BurstFill;
		end

/////////////////////////////////////////////////////////////////////////////////////////////
// Start of burst fill from Dram into Cache (data should be available at Dram in this  state)
/////////////////////////////////////////////////////////////////////////////////////////////
		
		else if(CurrentState == BurstFill) begin
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			DramSelectFromCache_L <= 0;
			NextState <= BurstFill;
			if (BurstCounter == 8) begin
				NextState <= EndBurstFill;
			end
			else begin
				WordAddress <= BurstCounter[2:0];
				
				if (ReplaceBlockNumber == 3'b000) begin	//block 0
					DataCache_WE_L <= 8'b11111110;				//write enabled for data block 0
				end
				else if (ReplaceBlockNumber == 3'b001) begin  //block 1
					DataCache_WE_L <= 8'b11111101;
				end
				else if (ReplaceBlockNumber == 3'b010) begin  //block 2
					DataCache_WE_L <= 8'b11111011;
				end
				else if (ReplaceBlockNumber == 3'b011) begin  //block 3
					DataCache_WE_L <= 8'b11110111;
				end
				else if (ReplaceBlockNumber == 3'b100) begin  //block 4
					DataCache_WE_L <= 8'b11101111;
				end
				else if (ReplaceBlockNumber == 3'b101) begin  //block 5
					DataCache_WE_L <= 8'b11011111;
				end
				else if (ReplaceBlockNumber == 3'b110) begin  //block 6
					DataCache_WE_L <= 8'b10111111;
				end
				else begin												//block 7
					DataCache_WE_L <= 8'b01111111;
				end
			end
		end
			
///////////////////////////////////////////////////////////////////////////////////////
// End Burst fill and give the CPU the data from the cache
///////////////////////////////////////////////////////////////////////////////////////
		else if(CurrentState == EndBurstFill) begin							// wait for Dram case signal to go low
			UDS_DramController_L <= 0;
			LDS_DramController_L <= 0;
			DramSelectFromCache_L <= 1;
			DtackTo68k_L <= 0;
			WordAddress <= AddressBusInFrom68k[3:1];
			DataBusOutTo68k <= DataBusInFromCache;
			if (AS_L == 1 || DramSelect68k_H == 0) 
				NextState <= Idle;
			else
				NextState <= EndBurstFill;
		end
		
///////////////////////////////////////////////
// Write Data to Dram State (no Burst)
///////////////////////////////////////////////
		else if(CurrentState == WriteDataToDram) begin	  					// if we are writing data to Dram
			AddressBusOutToDramController <= AddressBusInFrom68k;
			DramSelectFromCache_L <= 0;
			DtackTo68k_L <= DtackFromDram_L;
			if (AS_L == 1 || DramSelect68k_H == 0) 
				NextState <= Idle;
			else
				NextState <= WriteDataToDram;
		end		
	end
endmodule

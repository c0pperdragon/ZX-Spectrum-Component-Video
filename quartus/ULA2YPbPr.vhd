library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

entity ULA2YPbPr is	
	port (
--		-- external oscillator
		CLKREF : in std_logic;
				
		-- digital YPbPr output
		Y: out std_logic_vector(5 downto 0);
		Pb: out std_logic_vector(4 downto 0);
		Pr: out std_logic_vector(4 downto 0);

		-- sniffing ULA pins
		D : in std_logic_vector(7 downto 0);
		CAS : in std_logic;
		IOREQ : in std_logic;
		WR : in std_logic;
		
		-- configuration pins
		SDTVMODE : in std_logic;
		YPBPRMODE : in std_logic
	);	
end entity;


architecture immediate of ULA2YPbPr is

--	signal CLK224 : std_logic;
	signal CLK112A : std_logic;
	signal CLK112B : std_logic;
	signal CLK112C : std_logic;
	signal CLK112D : std_logic;
	signal CLK112TUNABLE : std_logic;
	
	signal CLK14   : std_logic;	
	-- when toggled, trigger a CLK122/8 slowdown or speedup 
	signal speedup14mhz : std_logic;
	signal slowdown14mhz : std_logic;
	-- number of speedups or slowdowns to do during half a frame (2*448*312/2 ticks of CLK14)
	signal speedadjustment : integer range -1048576 to 1048575; 
	
	signal vram_data       : STD_LOGIC_VECTOR (15 DOWNTO 0);
	signal vram_rdaddress0 : STD_LOGIC_VECTOR (6 DOWNTO 0);
	signal vram_wraddress  : STD_LOGIC_VECTOR (6 DOWNTO 0);
	signal vram_wren		  : STD_LOGIC;
	signal vram_q0		     : STD_LOGIC_VECTOR (15 DOWNTO 0);
				
	signal BORDER : std_logic_vector(2 downto 0);
	signal inframetrigger : std_logic;
	
	
	component PLL4PHASES IS
	PORT
	(
		inclk0		: IN STD_LOGIC  := '0';
		c0		: OUT STD_LOGIC ;
		c1		: OUT STD_LOGIC ;
		c2		: OUT STD_LOGIC ;
		c3		: OUT STD_LOGIC 
	);
	end component;
	
	
	component ZXVideoRAM is
	PORT
	(
		data		: IN STD_LOGIC_VECTOR (15 DOWNTO 0);
		rdaddress		: IN STD_LOGIC_VECTOR (6 DOWNTO 0);
		rdclock		: IN STD_LOGIC ;
		wraddress		: IN STD_LOGIC_VECTOR (6 DOWNTO 0);
		wrclock		: IN STD_LOGIC  := '1';
		wren		: IN STD_LOGIC  := '0';
		q		: OUT STD_LOGIC_VECTOR (15 DOWNTO 0)
	);
	end component;
	

	
begin		
	clock4phases: PLL4PHASES port map ( CLKREF, CLK112A, CLK112B, CLK112C, CLK112D );
	videoram0: ZXVideoRAM port map (vram_data, vram_rdaddress0, CLK14, vram_wraddress, CLK112A, vram_wren, vram_q0);

	
	------------- generate 112MHz output clock with the possibility to fine-tune the speed -----------------
	process (CLK112A,CLK112B,CLK112C,CLK112D) 
		variable phase : integer range 0 to 7 := 0;	            -- current output phase
		variable transitioninhibit : integer range 0 to 3 := 0;  -- transitions take some minimum time
		variable phaseenablerequested : std_logic_vector(7 downto 0) := "00000001";	
		variable phaseenable : std_logic_vector(7 downto 0) := "00000001";
	
		variable in_speedup : std_logic;
		variable previn_speedup : std_logic;
		variable in_slowdown : std_logic;
		variable previn_slowdown : std_logic;	
	begin
		-- asynchronously generate the output clock with the enabled phases
		CLK112TUNABLE <= 
				(CLK112A and phaseenable(0))
		   or (CLK112B and phaseenable(1))
		   or (CLK112C and phaseenable(2))
		   or (CLK112D and phaseenable(3))
		   or ((not CLK112A) and phaseenable(4))
		   or ((not CLK112B) and phaseenable(5))
		   or ((not CLK112C) and phaseenable(6))
		   or ((not CLK112D) and phaseenable(7));
			
		-- choose correct time to actually switch the enabled phases to avoid glitches
		if falling_edge(CLK112B) then phaseenable(0) := phaseenablerequested(0); end if;
		if falling_edge(CLK112C) then	phaseenable(1) := phaseenablerequested(1); end if;
		if falling_edge(CLK112D) then	phaseenable(2) := phaseenablerequested(2); end if;
		if rising_edge (CLK112A) then	phaseenable(3) := phaseenablerequested(3); end if;
		if rising_edge (CLK112B) then	phaseenable(4) := phaseenablerequested(4); end if;
		if rising_edge (CLK112C) then	phaseenable(5) := phaseenablerequested(5); end if;
		if rising_edge (CLK112D) then	phaseenable(6) := phaseenablerequested(6); end if;
		if falling_edge(CLK112A) then	phaseenable(7) := phaseenablerequested(7); end if;		
			
		-- sense the incomming speedup / slowdown requests and try to change phase
		if rising_edge(CLK112A) then
			if (in_speedup /= previn_speedup) and transitioninhibit=0 then
				phase := phase-1;
				phaseenablerequested(phase) := '1';
				transitioninhibit:=3;			
			elsif (in_slowdown /= previn_slowdown) and transitioninhibit=0 then
				phase := phase+1;
				phaseenablerequested(phase) := '1';
				transitioninhibit:=3;
			elsif transitioninhibit=0 then
				phaseenablerequested := "00000000";
				phaseenablerequested(phase) := '1';									
			else
				if transitioninhibit=2 then
					phaseenablerequested := "00000000";
					phaseenablerequested(phase) := '1';					
				end if;
				transitioninhibit := transitioninhibit-1;
			end if;			
		
			previn_speedup := in_speedup;
			in_speedup := speedup14mhz;
			previn_slowdown := in_slowdown;
			in_slowdown := slowdown14mhz;			
		end if;	
	end process;
	
	-- divide down the tuneable 112 Mhz to a tunable 14 Mhz
	process (CLK112TUNABLE)
		variable cnt: integer range 0 to 7 := 0;
		variable tmp_cnt: std_logic_vector(2 downto 0);
	begin
		if rising_edge(CLK112TUNABLE) then
			cnt := cnt+1;
		end if;			
		tmp_cnt := std_logic_vector(to_unsigned(cnt,3));
		CLK14 <= tmp_cnt(2);		
	end process;
	
	
	------------------- listening to the ULA and reading data into video ram ---------------------
	process (CLK112A) 
	
		-- variables for understanding the ULA signals
		variable in_cas:  std_logic_vector(4 downto 0) := "00000";		
		variable cas_islow : boolean := false;
		variable cas_falling : boolean := false;
	
		variable firstedgedetected : boolean := false;
		variable timesincefallingedge : integer range 0 to 255;
		variable timesincedata: integer range 0 to 16383;
	
		-- writing into the video ram
		variable wren : std_logic := '0';
		variable writecursor : integer range 0 to 8191 := 0;
		variable firstbyte : std_logic_vector(7 downto 0) := "00000000";
		variable secondbyte : std_logic_vector(7 downto 0) := "00000000";	
	
		-- signals to sync the output image generator
		variable out_inframe : std_logic := '0';
	
	begin
		if rising_edge(CLK112A) then	
			wren := '0';			
		
			-- detect edges of CAS and remove possible glitches 
			cas_falling := false;
			if in_cas="11111" then
				cas_islow := false;
			elsif in_cas="00000" then
				if not cas_islow then
					cas_falling := true;
				end if;
				cas_islow := true;
			end if;
			in_cas := in_cas(3 downto 0) & CAS;
			
			
			-- process glitch-free edges (with a 35ns delay)
			if cas_falling then
				
				-- ULA will make CAS access with 300ns intervall (use anything betweem 200ns and 400ns here)
				if firstedgedetected and timesincefallingedge > 22 and timesincefallingedge < 45 then
					firstedgedetected := false;
					
					if timesincedata<16383 then						
						writecursor := writecursor+1;
					else
						writecursor := 0;
					end if;
					wren := '1';
					
					timesincedata := 0;
				else
					firstedgedetected := true;
				end if;				
				
				timesincefallingedge := 0;
				
			else
		
				-- ram content should be here 35+150ns after falling edge of CAS
				if cas_islow and timesincefallingedge=10 then
					if firstedgedetected then
						firstbyte := D;
					else
						secondbyte := D;
						wren := '1';
						
						-- signal to output signal generator that the frame end is detected
						if writecursor=0 then
							out_inframe := '1';
						elsif writecursor=32*156 then
							out_inframe := '0';
						end if;

					end if;
				end if;
			 
				if timesincefallingedge<255 then
					timesincefallingedge := timesincefallingedge+1;
				end if;
			end if;
			
			-- measure data flow to detect start of frame
			if timesincedata<16383 then
				timesincedata := timesincedata+1;
			end if;
			
		end if;
		
		-- write to internal video ram
		vram_data <= secondbyte & firstbyte;
		vram_wraddress <= std_logic_vector(to_unsigned(writecursor mod 128,7));		
		vram_wren <= wren;

		inframetrigger <= out_inframe;
	end process;
	
	
	------- listening to the CPU if it sets the border color 
	process (CLK112A)
	
		variable in_wr: std_logic := '0';
		variable timedown: integer range 0 to 255 := 0;
		variable isiowrite : boolean;
	
		variable out_border: std_logic_vector(2 downto 0) := "111";
	begin
		if rising_edge(CLK112A) then
		
			-- check what happens on any wr request
			if in_wr='0' then
			   if timedown=5 then
					if IOREQ='0' then
						isiowrite := true;
					end if;
				end if;
				if timedown<255 then
					timedown:=timedown+1;
				end if;
			-- after rising wr may take the data from the bus
			else
				if isiowrite then  -- check if iowrite was detected previously				
					out_border := D(2 downto 0);
				end if;				
				timedown := 0;
				isiowrite := false;
			end if;
			
			in_wr := WR;
		end if;
	
		BORDER <= out_border;
	end process;
		
	
	------------------- generate the YPbPr signal from the video ram image -----------------
	-- while image generation is running, fine-tune the clock to match the incomming image frequency
	process (CLK14,inframetrigger,SDTVMODE,YPBPRMODE)

		type T_zxpalette is array (0 to 15) of integer range 0 to 32767;
		constant zxpalette_ypbpr : T_zxpalette := (
			-- black -- blue  -- red   -- purple - green -- cyan  -- yellow - white
			16#0210#,16#176d#,16#2d9b#,16#3ab8#,16#3d66#,16#4684#,16#58f1#,16#6610#,   -- dim
			16#0210#,16#1bac#,16#357d#,16#46fa#,16#4d23#,16#5aa1#,16#7092#,16#7e10#    -- bright
		);
		constant zxpalette_rgb : T_zxpalette := (
			-- black -- blue  -- red   -- purple - green -- cyan  -- yellow - white
			16#0000#,16#1300#,16#145a#,16#1b1a#,16#6080#,16#6320#,16#64b9#,16#6739#,   -- dim
			16#0000#,16#17e0#,16#187f#,16#23ff#,16#7ca0#,16#7fe0#,16#7cdf#,16#7fff#    -- bright
		);
		
		constant w: integer := 448;    -- (64.00 microseconds -> 15.625kHz)
		constant h: integer := 312;      -- (19968 microseconds -> 50.0801Hz)
		constant vheight: integer := 192;
		constant vstart:  integer := 72;
		constant hstart: integer := 127;
		constant borderthickness: integer := 48;
	
		variable cxhi: integer range 0 to 1023 := 0;
		variable cx: integer range 0 to 511 := 0;
		variable cy: integer range 0 to 511 := 0;	
		variable frame: integer range 0 to 31 := 0;
		
		variable px: integer range 0 to 7;
		variable foreground: integer range 0 to 7;
		variable background: integer range 0 to 7;
		variable bright: integer range 0 to 1;
		
		variable out_rdaddress0 : integer range 0 to 127;
		variable out_ypbpr: integer range 0 to 32767 := 0;
		variable out_sync : integer range 0 to 1 := 0;
		variable out_speedadjustment : integer range -1048576 to 1048575 := 0;
		variable out_outframetrigger : std_logic := '0';

		variable f1: std_logic := '0';
		variable f2: std_logic := '0';
	
		variable tmp_col:std_logic_vector(15 downto 0);
		variable outofsync : integer range -1048576 to 1048575;		
		variable palette : T_zxpalette;
		
		variable VISIBLEBORDER_PREPARE : std_logic_vector(2 downto 0);
		variable VISIBLEBORDER : std_logic_vector(2 downto 0);
	begin
		
		if rising_edge(CLK14) then
			-- select palette
			palette := zxpalette_ypbpr;
			if YPBPRMODE='0' then
				palette := zxpalette_rgb;
			end if;
		
			-- idle black, no sync
			out_ypbpr := palette(0);
			out_sync := 1;
			
			-- generate video signal for low-res mode
			if SDTVMODE='1' then  
				-- simple vsync pattern 
				if cy>=0 and cy<3 then                                  -- vsync
					if cxhi<w-33 or (cxhi>=w and cxhi<2*w-33) then
						out_sync := 0;
					end if;
				else
					if cxhi<66 then                                     -- normal syncs
						out_sync := 0;
					end if;
				end if;
				
				cx := cxhi/2;  -- 7Mhz horizontal pixel
			
				-- determine from where to read next video data word
				out_rdaddress0 := ((cy-vstart) mod 4)*32 + (cxhi+3-2*hstart) / 16;
				
			-- generate video signal for high-res mode
			else
				-- compute highres sync pulses
				if cy>=0 and cy<3 then			  
					if cxhi<w-32 or (cxhi>=w and cxhi<2*w-32) then            -- two EDTV vsyncs per lowres line
						out_sync := 0;
					end if;
				else
					if cxhi<32 or (cxhi>=w and cxhi<w+32) then                -- two EDTV syncs
						out_sync := 0;
					end if;				
				end if;
				-- traverse every line twice
				if cxhi<=w then	
					cx := cxhi;
				else
					cx := cxhi - w;
				end if;
				-- determine from where to read next video data word
				out_rdaddress0 := ((cy-vstart) mod 4)*32 + (cx+3-hstart) / 8;
			end if;
			
			-- compute image (with border)
			if cx>=hstart and cx<hstart+256 and cy>=vstart and cy<vstart+vheight then
				px := (cx-hstart) mod 8;				
				foreground := to_integer(unsigned(vram_q0(10 downto 8)));
				background := to_integer(unsigned(vram_q0(13 downto 11)));
				bright := to_integer(unsigned(vram_q0(14 downto 14)));
				if vram_q0(15)='1' and frame>=16 then
					foreground := to_integer(unsigned(vram_q0(13 downto 11)));
					background := to_integer(unsigned(vram_q0(10 downto 8)));
				end if;					
				if vram_q0(7-px)='1' then
					out_ypbpr := palette(foreground+bright*8);
				else
					out_ypbpr := palette(background+bright*8);
				end if;				
			elsif cx>=hstart-borderthickness and cx<hstart+256+borderthickness 
			  and cy>=vstart-borderthickness and cy<vstart+vheight+borderthickness then
				out_ypbpr := palette(to_integer(unsigned(VISIBLEBORDER)));
			end if;				
													
			-- detect input screen start or half screen end and bring output to sync
			if f1 /= f2 then
				if f1='1' then   -- start of screen
					outofsync := (vstart-1)*w*2 + 2*hstart;
				else             -- start of second half of screen
					outofsync := (vstart-1+h/2)*w*2 + 2*hstart;					
				end if;
				outofsync := outofsync - cxhi - cy*w*2;   -- how many 14Mhz clocks are needed to catch up?
				
				if outofsync<-w*2*3 or outofsync>w*2*3 then   -- when more than 3 lines out of sync, force immediately
					if f1='1' then
						cy := vstart-1;
					else
						cy := vstart-1+h/2;
					end if;
					cxhi := 2*hstart;
					out_speedadjustment := 0;
				else
					out_speedadjustment := 60*outofsync;   -- 14Mhz clocks -> 8*112 Mhz ticks, slight damping
				end if;
			end if;
			f2 := f1;
			f1 := inframetrigger;	
						
			-- generate debug output signal
			if cxhi=2*hstart and cy=vstart-2 then
				out_outframetrigger := '1';
			elsif cxhi=2*hstart and cy=vstart-2+h/2 then
				out_outframetrigger := '0';
			end if;
			
			-- progress horizontal and vertical counters
			if cxhi<2*w-1 then
				cxhi := cxhi+1;
			else
				VISIBLEBORDER := VISIBLEBORDER_PREPARE;
				VISIBLEBORDER_PREPARE := BORDER;			
				
				cxhi:=0;
				if cy<h-1 then 
					cy:=cy+1;
				else
					cy := 0;
					frame := frame+1;
				end if;
			end if;			
			
		end if;
		
		-- send output signal to lines
		tmp_col(15 downto 15) := std_logic_vector(to_unsigned(out_sync,1));
		tmp_col(14 downto 0) := std_logic_vector(to_unsigned(out_ypbpr, 15));
		Y  <= tmp_col(15 downto 10);
		Pb <= tmp_col(9 downto 5);
		Pr <= tmp_col(4 downto 0);
		
		-- fetch data for next pixel
		vram_rdaddress0 <= std_logic_vector(to_unsigned(out_rdaddress0, 7));			
		
		-- configure the speed regulator
		speedadjustment <= out_speedadjustment;		
	end process;
	

	-- process the speedadjustment setting to emmit correct speedup and slowdown toggle pulses
	process (CLK14)
		constant halfframe : integer := 2*448*312/2;
	
		variable accu : integer range -1048576 to 1048575 := 0;
		variable out_slowdown: std_logic := '0';
		variable out_speedup: std_logic := '0';
	begin 
		if rising_edge(CLK14) then
			accu := accu + speedadjustment;
			if accu >= halfframe then
				accu := accu - halfframe;
				out_speedup := not out_speedup;
			elsif accu <= -halfframe then
				accu := accu + halfframe;
				out_slowdown := not out_slowdown;
			end if;
		end if;
		
		slowdown14mhz <= out_slowdown;
		speedup14mhz <= out_speedup;
	end process;	

end immediate;


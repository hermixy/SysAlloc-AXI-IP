-- RAM-based Buddy Allocator
-- Created by Hilda Xue, 24 Feb 2015
-- This file contains the top level of the buddy allocator

LIBRARY IEEE;
USE IEEE.std_logic_1164.ALL;
USE IEEE.numeric_std.ALL;
USE work.ALL;
USE work.budpack.ALL;

ENTITY rbuddy_top IS
  PORT(
    clk         : IN  std_logic;
    reset       : IN  std_logic;
    start       : IN  std_logic;
    cmd         : IN  std_logic;  -- 0 = alloc, 1 = free; Differ from  marking process 
    size        : IN  std_logic_vector(31 DOWNTO 0);
    free_addr   : IN  std_logic_vector(31 DOWNTO 0);
    done        : OUT std_logic;
    malloc_addr : OUT std_logic_vector(31 DOWNTO 0);
	ddr_command          : out  std_logic;   -- 0 = write, 1 = read
    ddr_start			 : out  std_logic;
    ddr_addr         : out  std_logic_vector(31 downto 0);
    ddr_write_data       : out  std_logic_vector(31 downto 0);
    ddr_read_data        : in std_logic_vector(31 downto 0);
    ddr_done         : in std_logic
    );
END ENTITY rbuddy_top;

ARCHITECTURE synth OF rbuddy_top IS

  ALIAS slv IS std_logic_vector;
  ALIAS usgn IS unsigned;

  TYPE StateType IS (idle,
                     malloc0, malloc1,  -- preprocess info for search in malloc
                     free,              -- preprocess info for free
                     search,            -- search for malloc deciding group
                     track,             -- update tracker
                     downmark,          -- downward marking
                     upmark,            -- upward marking
                     done_state);
  SIGNAL state, nstate : StateType;

  -- ram0
  SIGNAL ram0_we       : std_logic;
  SIGNAL ram0_addr     : std_logic_vector(31 DOWNTO 0);
  SIGNAL ram0_data_in  : std_logic_vector(31 DOWNTO 0);
  SIGNAL ram0_data_out : std_logic_vector(31 DOWNTO 0);

  -- wires connecting ram0 from each modules
  SIGNAL search0_addr     : std_logic_vector(31 DOWNTO 0);
  SIGNAL search0_data_out : std_logic_vector(31 DOWNTO 0);

  SIGNAL down0_we       : std_logic;
  SIGNAL down0_addr     : std_logic_vector(31 DOWNTO 0);
  SIGNAL down0_data_in  : std_logic_vector(31 DOWNTO 0);
  SIGNAL down0_data_out : std_logic_vector(31 DOWNTO 0);

  SIGNAL up0_we       : std_logic;
  SIGNAL up0_addr     : std_logic_vector(31 DOWNTO 0);
  SIGNAL up0_data_in  : std_logic_vector(31 DOWNTO 0);
  SIGNAL up0_data_out : std_logic_vector(31 DOWNTO 0);

  SIGNAL search_start_probe : tree_probe;
  SIGNAL search_done_probe  : tree_probe;
  SIGNAL search_done_bit    : std_logic;
  SIGNAL flag_malloc_failed : std_logic;
  SIGNAL start_search       : std_logic;

  SIGNAL start_dmark        : std_logic;
  SIGNAL flag_alloc         : std_logic;
  SIGNAL dmark_start_probe  : tree_probe;
  SIGNAL dmark_done_bit     : std_logic;
  SIGNAL down_node_out      : std_logic_vector(1 DOWNTO 0);
  SIGNAL up_done_bit        : std_logic;
  SIGNAL start_upmark       : std_logic;
  SIGNAL upmark_start_probe : tree_probe;
  SIGNAL flag_markup        : std_logic;

  SIGNAL start_top_node_size     : std_logic_vector(31 DOWNTO 0);
  SIGNAL start_log2top_node_size : std_logic_vector(6 DOWNTO 0);

  SIGNAL start_free_info     : std_logic;
  SIGNAL free_info_probe_out : tree_probe;
  SIGNAL free_info_done_bit  : std_logic;
  SIGNAL free_tns            : std_logic_vector(31 DOWNTO 0);
  SIGNAL free_log2tns        : std_logic_vector(6 DOWNTO 0);
  SIGNAL free_group_addr     : std_logic_vector(31 DOWNTO 0);

  -- tracker ram
  SIGNAL tracker_we       : std_logic;
  SIGNAL tracker_addr     : integer RANGE 0 TO 31;
  SIGNAL tracker_data_in  : std_logic_vector(31 DOWNTO 0);
  SIGNAL tracker_data_out : std_logic_vector(31 DOWNTO 0);

  SIGNAL group_addr_to_tracker : std_logic_vector(31 DOWNTO 0);
  SIGNAL tracker_func_sel      : std_logic;  -- 0 = update, 1 = make probe_in
  SIGNAL tracker_done          : std_logic;
  SIGNAL tracker_probe_out     : tree_probe;

  SIGNAL start_check_blocking : std_logic;
  SIGNAL flag_blocking        : std_logic;
  SIGNAL cblock_probe_in      : tree_probe;
  SIGNAL cblock_probe_out     : tree_probe;
  SIGNAL cblock_done          : std_logic;
  SIGNAL cblock_ram_addr      : std_logic_vector(31 DOWNTO 0);
  SIGNAL cblock_ram_data_out  : std_logic_vector(31 DOWNTO 0);

  SIGNAL start_tracker : std_logic;

  SIGNAL vg_addr_malloc : std_logic_vector(31 DOWNTO 0);
  SIGNAL vg_addr_free   : std_logic_vector(31 DOWNTO 0);

  -- for ddr/bram partition
  signal search_read_done : std_logic;
  signal search_read_start : std_logic;
  
  signal down_read_done : std_logic;
  signal down_read_start : std_logic;
  signal down_write_done : std_logic;
  
  signal up_read_done : std_logic;
  signal up_read_start : std_logic;
  signal up_write_done : std_logic;
  
  signal cb_read_start : std_logic;
  signal cb_read_done : std_logic;
  
  -- ram control signals
  SIGNAL control_we       : std_logic; -- control_write_start
  SIGNAL control_addr     : std_logic_vector(31 DOWNTO 0);
  SIGNAL control_data_in  : std_logic_vector(31 DOWNTO 0);
  SIGNAL control_data_out : std_logic_vector(31 DOWNTO 0);
  signal control_write_done : std_logic;
  signal control_read_start : std_logic;
  signal control_read_done : std_logic;
  
  
  
BEGIN

  RAM0 : ENTITY ram
    PORT MAP(
      clk      => clk,
      we       => ram0_we,
      address  => ram0_addr,
      data_in  => ram0_data_in,
      data_out => ram0_data_out
      );
	  
  SEARCHER : ENTITY locator
    PORT MAP(
      clk             => clk,
      reset           => reset,
      start           => start_search,
      probe_in        => search_start_probe,
      size            => size,
      direction_in    => '0',           -- start direction is always DOWN
      probe_out       => search_done_probe,
      done_bit        => search_done_bit,
      ram_addr        => search0_addr,
      ram_data_out    => search0_data_out,
      flag_failed_out => flag_malloc_failed,
      vg_addr         => vg_addr_malloc,
	  read_start => search_read_start,
	  read_done => search_read_done
      );

  dmark : ENTITY down_marker
    PORT MAP(
      clk          => clk,
      reset        => reset,
      start        => start_dmark,
      flag_alloc   => flag_alloc,
      probe_in     => dmark_start_probe,
      reqsize      => size,
      done_bit     => dmark_done_bit,
      ram_we       => down0_we,
      ram_addr     => down0_addr,
      ram_data_in  => down0_data_in,
      ram_data_out => down0_data_out,
      node_out     => down_node_out,
      flag_markup  => flag_markup,
	  read_start => down_read_start,
	  read_done => down_read_done,
	  write_done => down_write_done
      );

  upmarker : ENTITY up_marker
    PORT MAP(
      clk          => clk,
      reset        => reset,
      start        => start_upmark,
      probe_in     => upmark_start_probe,
      node_in      => down_node_out,
      done_bit     => up_done_bit,
      ram_we       => up0_we,
      ram_addr     => up0_addr,
      ram_data_in  => up0_data_in,
      ram_data_out => up0_data_out,
	  read_start => up_read_star,
	  read_done => up_read_done,
	  write_done => up_write_done
      );

  free_info_calc : ENTITY free_info
    PORT MAP(
      clk                   => clk,
      reset                 => reset,
      start                 => start_free_info,
      address               => free_addr,
      size                  => size,
      probe_out             => free_info_probe_out,
      done_bit              => free_info_done_bit,
      top_node_size_out     => free_tns,
      log2top_node_size_out => free_log2tns,
      group_addr_out        => free_group_addr,
      vg_addr               => vg_addr_free
      );

  tracker_ram0 : ENTITY tracker_ram
    PORT MAP (
      clk      => clk,
      we       => tracker_we,
      address  => tracker_addr,
      data_in  => tracker_data_in,
      data_out => tracker_data_out
      );

  tracker0 : ENTITY tracker
    PORT MAP(
      clk           => clk,
      reset         => reset,
      start         => start_tracker,
      group_addr_in => group_addr_to_tracker,
      size          => size,
      flag_alloc    => flag_alloc,
      func_sel      => tracker_func_sel,
      done_bit      => tracker_done,
      probe_out     => tracker_probe_out,
      ram_we        => tracker_we,
      ram_addr      => tracker_addr,
      ram_data_in   => tracker_data_in,
      ram_data_out  => tracker_data_out
      );

  cblock : ENTITY check_blocking
    PORT MAP(
      clk               => clk,
      reset             => reset,
      start             => start_check_blocking,
      flag_blocking_out => flag_blocking,
      probe_in          => cblock_probe_in,
      probe_out         => cblock_probe_out,
      done_bit          => cblock_done,
      ram_addr          => cblock_ram_addr,
      ram_data_out      => cblock_ram_data_out,
	  read_start => cb_read_start,
	  read_done => cb_read_done
      );

  
  P0 : PROCESS(state, up_done_bit)      -- controls FSM, only writes nstate!

  BEGIN

    nstate <= idle;                     -- default value
    done   <= '0';

    CASE state IS
      WHEN idle     => nstate <= idle;
      WHEN malloc0  => nstate <= malloc0;
      WHEN malloc1  => nstate <= malloc1;
      WHEN free     => nstate <= free;
      WHEN search   => nstate <= search;
      WHEN track    => nstate <= track;
      WHEN downmark => nstate <= downmark;
      WHEN upmark   => nstate <= upmark;
                       IF up_done_bit = '1' THEN
                         nstate <= done_state;
                       END IF;
      WHEN done_state => nstate <= idle;
                         done <= '1';
      WHEN OTHERS => nstate <= idle;
    END CASE;

  END PROCESS;

  P1 : PROCESS

  BEGIN
    WAIT UNTIL clk'event AND clk = '1';

    state <= nstate;                    -- default

    -- start signals
    start_free_info      <= '0';
    start_tracker        <= '0';
    start_search         <= '0';
    start_check_blocking <= '0';
    start_dmark          <= '0';
    start_upmark         <= '0';

    IF reset = '0' THEN                 -- active low
      state <= idle;
    ELSE

      IF state = idle THEN
        IF start = '1' THEN
          IF cmd = '1' THEN             -- cmd = 1 free
            state           <= free;
            start_free_info <= '1';
          ELSE                          -- cmd = 0 malloc
            state            <= malloc0;
            start_tracker    <= '1';
            tracker_func_sel <= '1';
          END IF;
        END IF;
      END IF;

      IF state = malloc0 THEN
        IF tracker_done = '1' THEN
          IF to_integer(usgn(tracker_probe_out.verti)) = 0 THEN  -- skip cblock
            state              <= search;
            start_search       <= '1';
            search_start_probe <= tracker_probe_out;
          ELSE                                                   -- cblock 
            state                <= malloc1;
            start_check_blocking <= '1';
            cblock_probe_in      <= tracker_probe_out;
          END IF;
        END IF;
        
      END IF;

      IF state = malloc1 THEN
        IF cblock_done = '1' THEN
          state        <= search;
          start_search <= '1';
          IF flag_blocking = '0' THEN  -- no blocking, use the tracker_probe_out
            search_start_probe <= tracker_probe_out;
          ELSE
            search_start_probe <= cblock_probe_out;
          END IF;
        END IF;
      END IF;  -- end malloc1    

      IF state = free THEN

        IF free_info_done_bit = '1' THEN
          state                 <= track;
          start_tracker         <= '1';
          tracker_func_sel      <= '0';
          group_addr_to_tracker <= free_group_addr;  -- group addr  
          IF to_integer(usgn(size)) = 1 AND USE_ALVEC = '1' THEN
            group_addr_to_tracker <= vg_addr_free;
          END IF;
        END IF;
      END IF;  -- end free       

      IF state = search THEN

        IF search_done_bit = '1' THEN
          IF flag_malloc_failed = '0' THEN
            state                 <= track;
            start_tracker         <= '1';
            tracker_func_sel      <= '0';
            group_addr_to_tracker <= search0_addr;  -- group addr   
            IF to_integer(usgn(size)) = 1 AND USE_ALVEC = '1' THEN
              group_addr_to_tracker <= vg_addr_malloc;
            END IF;
          ELSE                          -- if search for allocation failed
            state <= done_state;
          END IF;
        END IF;
      END IF;  -- end search     

      IF state = track THEN

        IF tracker_done = '1' THEN
          state       <= downmark;
          start_dmark <= '1';
          IF flag_alloc = '1' THEN      -- malloc
            dmark_start_probe <= search_done_probe;
          ELSE
            dmark_start_probe <= free_info_probe_out;
          END IF;
        END IF;
      END IF;  -- end track      

      IF state = downmark THEN
        IF dmark_done_bit = '1' THEN
          state <= done_state;
          IF flag_markup = '1' THEN
            state              <= upmark;
            start_upmark       <= '1';
            upmark_start_probe <= search_done_probe;  -- malloc
            IF flag_alloc = '0' THEN                  -- free
              upmark_start_probe <= free_info_probe_out;
            END IF;
          END IF;
        END IF;
      END IF;  -- end downmark           
      
    END IF;  -- end reset
    
  END PROCESS;

  p2 : PROCESS(state,
               search0_addr,
               down0_we, down0_addr, down0_data_in,
               up0_we, up0_addr, up0_data_in,
               control_data_out,
               cblock_ram_addr, cblock_ram_data_out)  -- select ram signals
  BEGIN

    -- default
    --   IF state = downmark THEN
    control_we        <= down0_we;
    control_addr      <= down0_addr;
    control_data_in   <= down0_data_in;
    down0_data_out <= control_data_out;
	down_write_done <= control_write_done;
	down_read_done <= control_read_done;
	control_read_start <= down_read_start;
    --   END IF;

    IF state = malloc1 THEN
      control_addr           <= cblock_ram_addr;
      cblock_ram_data_out <= control_data_out;
	  cb_read_done <= control_read_done;
	  control_read_start <= cb_read_start;
    END IF;

    IF state = search THEN
      control_addr        <= search0_addr;
      search0_data_out <= control_data_out;
	  search_read_done <= control_read_done;
	  control_read_start <= control_read_start;
    END IF;

    IF state = upmark THEN
      control_we      <= up0_we;
      control_addr    <= up0_addr;
      control_data_in <= up0_data_in;
      up0_data_out <= control_data_out;
	  up_read_done <= control_read_done;
	  up_write_done <= control_write_done;
	  control_read_start <= up_read_start;
    END IF;
    
  END PROCESS;
  
  p3 : process -- (control_we, control_addr, control_data_in)
  
  begin
    WAIT UNTIL clk'event AND clk = '1';

	ddr_start <= '0';
	control_read_done <= '0';
	ram0_we <= '0';	
	control_write_done <= '0';
					control_read_done <= '0';
				control_write_done <= '0';
				
	
		if to_integer(usgn(control_addr)) >= to_integer(usgn(ParAddr)) then -- use DDR
		
			-- about done bit
			if ddr_done = '1' then 
				
				-- it's not halmful to set both to 1 now
				-- later, maybe seperate the read_one and write_done in AXI MASTER to avoid this
				control_write_done <= '1';
				
				control_read_done <= '1';
				-- for read
				control_data_out <= ddr_read_data;
				

				
			end if;
			
			-- address
			ddr_addr <= slv(usgn(control_addr) - usgn(ParAddr) + usgn(DDR_TREE_BASE));
			
			if control_read_start = '1' then -- start, command
				ddr_start <= '1';
				ddr_command <= '1'; -- read

			elsif control_write_start = '1' then -- start, command, write_data
				ddr_start <= '1';
				ddr_command <= '0'; -- write
				ddr_write_data <= control_data_out;
			end if;		
			
		else -- use BRAM
			
			ram0_addr <= control_addr;
			
			if control_read_start = '1' then 
			
				control_data_out <= ram0_data_out;
				control_read_done <= '1';
			
			elsif control_write_start = '1' then 
				
				ram0_we <= '1';
				ram0_data_in <= control_data_in;
				control_write_done <= '1'; -- DANGEROUS? IS DATA BEING VALID FOR ENOUGH TIME?			
			
			end if;
		
			
		end if;  
  
  end process;

  malloc_addr <= search_done_probe.saddr;
  flag_alloc  <= NOT cmd;

END ARCHITECTURE synth;




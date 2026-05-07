-- ssm2603_init_tb.vhd
-- Self-checking testbench for ssm2603_init.
-- Tests: all 9 codec registers written in correct order with correct data.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ssm2603_init_tb is
end ssm2603_init_tb;

architecture sim of ssm2603_init_tb is

    -- Low CLK_FREQ to minimize simulation events.
    -- Delays: startup = CLK_FREQ/100 = 10, reset = CLK_FREQ/10 = 100 cycles.
    -- HALF_PER = CLK_FREQ/(2*I2C_FREQ) = 5 (still valid I2C timing).
    constant CLK_FREQ : integer := 1_000;
    constant I2C_FREQ : integer := 100;
    constant CLK_PER  : time    := 1 ms;

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    signal scl_o     : std_logic;
    signal sda_o     : std_logic;
    signal sda_i     : std_logic := '1';
    signal init_done : std_logic;
    signal init_err  : std_logic;

    signal slave_sda : std_logic := '1';
    signal sda_bus   : std_logic;

    signal sim_done : boolean := false;

    -- Capture up to 16 transactions: each is {addr_byte, data_hi, data_lo}
    type byte3 is array(0 to 2) of std_logic_vector(7 downto 0);
    type txn_array is array(0 to 15) of byte3;
    signal captured  : txn_array := (others => (others => x"00"));
    signal txn_count : integer := 0;

    -- Expected register writes (from SSM2603 datasheet)
    type word_array is array(natural range <>) of std_logic_vector(15 downto 0);
    constant EXPECTED : word_array(0 to 8) := (
        x"1E00", x"0C1A", x"0017", x"0217",
        x"0800", x"0A00", x"0E42", x"1001", x"1201"
    );

begin

    sda_bus <= '0' when sda_o = '0' or slave_sda = '0' else '1';
    sda_i   <= sda_bus;
    clk     <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.ssm2603_init
        generic map (CLK_FREQ => CLK_FREQ, I2C_FREQ => I2C_FREQ)
        port map (
            clk => clk, reset => reset,
            scl_o => scl_o, sda_o => sda_o, sda_i => sda_i,
            init_done => init_done, init_err => init_err
        );

    -- I2C slave: captures every 3-byte write, always ACKs
    slave : process
        variable rx  : std_logic_vector(7 downto 0);
        variable idx : integer := 0;
    begin
        slave_sda <= '1';
        while not sim_done loop
            -- Wait for START
            loop
                wait until falling_edge(sda_bus);
                exit when scl_o = '1';
            end loop;

            -- Receive 3 bytes with ACK
            for b in 0 to 2 loop
                rx := (others => '0');
                for i in 7 downto 0 loop
                    wait until rising_edge(scl_o);
                    rx(i) := sda_bus;
                end loop;
                if idx < 16 then
                    captured(idx)(b) <= rx;
                end if;

                wait until falling_edge(scl_o);
                slave_sda <= '0';  -- ACK
                wait until rising_edge(scl_o);
                wait until falling_edge(scl_o);
                slave_sda <= '1';
            end loop;

            idx := idx + 1;
            txn_count <= idx;
        end loop;
        wait;
    end process;

    -- Stimulus and checking
    stim : process
        variable err_count : integer := 0;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                report msg severity error;
                err_count := err_count + 1;
            end if;
        end procedure;

    begin
        reset <= '1'; wait for CLK_PER * 5;
        reset <= '0';

        -- Wait for initialization to complete
        while init_done /= '1' loop
            wait for CLK_PER;
            assert (now < 1000 sec) report "TIMEOUT" severity failure;
        end loop;

        report "Test 1: init_done and init_err status";
        check(init_done = '1', "init_done should be asserted");
        check(init_err = '0',  "init_err should be low");

        report "Test 2: correct number of I2C transactions";
        check(txn_count = 9,   "expected 9 transactions, got " & integer'image(txn_count));

        report "Test 3: all 9 register writes match expected data";
        for i in 0 to 8 loop
            check(captured(i)(0) = x"34",
                  "Txn " & integer'image(i) & ": addr should be 0x34");
            check(captured(i)(1) = EXPECTED(i)(15 downto 8),
                  "Txn " & integer'image(i) & ": data_hi mismatch");
            check(captured(i)(2) = EXPECTED(i)(7 downto 0),
                  "Txn " & integer'image(i) & ": data_lo mismatch");
        end loop;

        -- Summary
        if err_count = 0 then
            report "*** SSM2603 INIT: ALL TESTS PASSED ***" severity note;
        else
            report "*** SSM2603 INIT: FAILED " & integer'image(err_count) & " check(s) ***" severity error;
        end if;
        sim_done <= true;
        wait for 5 ns;
        if err_count = 0 then
            assert false report "*** SSM2603 INIT: SIMULATION PASSED ***" severity failure;
        else
            assert false report "*** SSM2603 INIT: SIMULATION FAILED: " &
                integer'image(err_count) & " error(s) ***" severity failure;
        end if;
        wait;
    end process;

end sim;
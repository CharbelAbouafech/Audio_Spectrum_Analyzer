-- i2c_master_tb.vhd
-- Self-checking testbench for i2c_master.
-- Tests: normal write with ACKs, NACK detection.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.FINISH;

entity i2c_master_tb is
end i2c_master_tb;

architecture sim of i2c_master_tb is

    constant CLK_FREQ : integer := 1_000_000;
    constant I2C_FREQ : integer := 100_000;
    constant CLK_PER  : time    := 1 us;

    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal start   : std_logic := '0';
    signal addr    : std_logic_vector(6 downto 0) := (others => '0');
    signal data    : std_logic_vector(15 downto 0) := (others => '0');
    signal busy    : std_logic;
    signal done    : std_logic;
    signal ack_err : std_logic;
    signal scl_o   : std_logic;
    signal sda_o   : std_logic;
    signal sda_i   : std_logic := '1';

    -- Slave drives this; open-drain AND with master
    signal slave_sda : std_logic := '1';
    signal sda_bus   : std_logic;

    -- Slave captures 3 bytes per transaction
    type byte_array is array(0 to 2) of std_logic_vector(7 downto 0);
    signal captured : byte_array := (others => x"00");

    -- '0' = ACK, '1' = NACK for each of the 3 bytes
    signal slave_ack : std_logic_vector(2 downto 0) := "000";

    signal sim_done : boolean := false;

begin

    sda_bus <= '0' when sda_o = '0' or slave_sda = '0' else '1';
    sda_i   <= sda_bus;
    clk     <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.i2c_master
        generic map (CLK_FREQ => CLK_FREQ, I2C_FREQ => I2C_FREQ)
        port map (
            clk => clk, reset => reset, start => start,
            addr => addr, data => data,
            busy => busy, done => done, ack_err => ack_err,
            scl_o => scl_o, sda_o => sda_o, sda_i => sda_i
        );

    -- I2C slave: waits for START, receives 3 bytes, drives ACK/NACK
    slave : process
        variable rx : std_logic_vector(7 downto 0);
    begin
        slave_sda <= '1';
        while not sim_done loop
            -- Wait for START (SDA falls while SCL high)
            loop
                wait until falling_edge(sda_bus);
                exit when scl_o = '1';
            end loop;

            -- Receive 3 bytes
            for b in 0 to 2 loop
                rx := (others => '0');
                for i in 7 downto 0 loop
                    wait until rising_edge(scl_o);
                    rx(i) := sda_bus;
                end loop;
                captured(b) <= rx;

                -- Drive ACK/NACK
                wait until falling_edge(scl_o);
                slave_sda <= slave_ack(b);
                wait until rising_edge(scl_o);
                wait until falling_edge(scl_o);
                slave_sda <= '1';
            end loop;
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

        procedure send(
            a : std_logic_vector(6 downto 0);
            d : std_logic_vector(15 downto 0)
        ) is
        begin
            addr <= a; data <= d;
            start <= '1'; wait for CLK_PER; start <= '0';
        end procedure;

        procedure wait_done is
            variable t : integer := 0;
        begin
            while done /= '1' loop
                wait for CLK_PER;
                t := t + 1;
                assert t < 10000 report "TIMEOUT" severity failure;
            end loop;
            wait for CLK_PER;
        end procedure;

    begin
        reset <= '1'; wait for CLK_PER * 5;
        reset <= '0'; wait for CLK_PER * 2;

        -- Test 1: Normal write, all ACKs
        report "Test 1: Normal write (addr=0x1A, data=0xABCD)";
        slave_ack <= "000";
        send("0011010", x"ABCD");
        check(busy = '1', "T1: busy should be high");
        wait_done;
        check(ack_err = '0', "T1: no ack error expected");
        check(busy = '0',    "T1: busy should be low after done");
        check(captured(0) = x"34", "T1: byte 0 should be 0x34");  -- 0x1A<<1|0
        check(captured(1) = x"AB", "T1: byte 1 should be 0xAB");
        check(captured(2) = x"CD", "T1: byte 2 should be 0xCD");
        wait for CLK_PER * 10;

        -- Test 2: NACK on byte 1
        report "Test 2: NACK on second byte";
        slave_ack <= "010";
        send("0011010", x"1234");
        wait_done;
        check(ack_err = '1', "T2: ack_err should be set");
        wait for CLK_PER * 10;

        -- Test 3: Second address/data to verify generality
        report "Test 3: Different address and data";
        slave_ack <= "000";
        send("1010101", x"5678");
        wait_done;
        check(ack_err = '0', "T3: no ack error expected");
        check(captured(0) = x"AA", "T3: byte 0 should be 0xAA");  -- 0x55<<1|0
        check(captured(1) = x"56", "T3: byte 1 should be 0x56");
        check(captured(2) = x"78", "T3: byte 2 should be 0x78");

        -- Summary
        if err_count = 0 then
            report "*** I2C MASTER: ALL TESTS PASSED ***" severity note;
        else
            report "*** I2C MASTER: FAILED " & integer'image(err_count) & " check(s) ***" severity error;
        end if;
        sim_done <= true;
        wait for 5 ns;
        if err_count = 0 then
            assert false report "*** I2C MASTER: SIMULATION PASSED ***" severity failure;
        else
            assert false report "*** I2C MASTER: SIMULATION FAILED: " &
                integer'image(err_count) & " error(s) ***" severity failure;
        end if;
        wait;
    end process;

end sim;
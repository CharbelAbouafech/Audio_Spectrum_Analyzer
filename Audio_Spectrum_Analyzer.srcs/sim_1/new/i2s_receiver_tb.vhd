-- i2s_receiver_tb.vhd
-- Self-checking testbench for i2s_receiver.
-- Tests: deserialize known stereo frames, verify left/right output.
--
-- RTL timing: after a LRCLK transition is detected on a BCLK rising edge,
-- the receiver skips one additional BCLK (bit_cnt=0) before shifting data.
-- So MSB appears on the 3rd BCLK after LRCLK edge:
--   BCLK 0: LRCLK transition detected, bit_cnt set to 0
--   BCLK 1: bit_cnt=0 skipped (I2S dummy bit), bit_cnt becomes 1
--   BCLK 2: bit_cnt=1, MSB shifted in

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.FINISH;

entity i2s_receiver_tb is
end i2s_receiver_tb;

architecture sim of i2s_receiver_tb is

    constant DATA_WIDTH : integer := 16;
    constant CLK_PER    : time := 100 ns;   -- 10 MHz system clock
    constant BCLK_PER   : time := 5 us;     -- 200 kHz bit clock

    signal clk        : std_logic := '0';
    signal reset      : std_logic := '1';
    signal bclk       : std_logic := '0';
    signal lrclk      : std_logic := '0';
    signal sdata      : std_logic := '0';
    signal left_data  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal right_data : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal valid      : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.i2s_receiver
        generic map (DATA_WIDTH => DATA_WIDTH)
        port map (
            clk => clk, reset => reset,
            bclk => bclk, lrclk => lrclk, sdata => sdata,
            left_data => left_data, right_data => right_data, valid => valid
        );

    stim : process
        variable err_count : integer := 0;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                report msg severity error;
                err_count := err_count + 1;
            end if;
        end procedure;

        -- One BCLK pulse helper
        procedure bclk_pulse is
        begin
            wait for BCLK_PER / 2; bclk <= '1';
            wait for BCLK_PER / 2; bclk <= '0';
        end procedure;

        -- Send one I2S stereo frame (32 BCLKs per channel).
        -- Data placed at BCLK index 2..17 to match RTL's 2-BCLK offset.
        procedure send_frame(
            left_val  : std_logic_vector(DATA_WIDTH - 1 downto 0);
            right_val : std_logic_vector(DATA_WIDTH - 1 downto 0)
        ) is
        begin
            lrclk <= '0';  -- left channel
            for i in 0 to 31 loop
                if i >= 2 and i <= DATA_WIDTH + 1 then
                    sdata <= left_val(DATA_WIDTH + 1 - i);
                else
                    sdata <= '0';
                end if;
                bclk_pulse;
            end loop;

            lrclk <= '1';  -- right channel
            for i in 0 to 31 loop
                if i >= 2 and i <= DATA_WIDTH + 1 then
                    sdata <= right_val(DATA_WIDTH + 1 - i);
                else
                    sdata <= '0';
                end if;
                bclk_pulse;
            end loop;
        end procedure;

        -- Trigger LRCLK falling edge to latch right channel and fire valid.
        -- Uses event-based wait to catch single-cycle valid pulse.
        procedure flush_and_wait is
        begin
            lrclk <= '0'; sdata <= '0';
            wait for BCLK_PER / 2;
            bclk <= '1';
            wait until valid = '1' for 100 us;
            assert valid = '1' report "TIMEOUT waiting for valid" severity failure;
            wait for BCLK_PER / 2;
            bclk <= '0';
        end procedure;

        -- Send one BCLK with LRCLK='1' so receiver's lrclk_prev='1',
        -- ensuring next frame's LRCLK='0' is detected as a transition.
        -- Call AFTER checking data (overwrites left_reg with zeros).
        procedure prep_next is
        begin
            lrclk <= '1';
            bclk_pulse;
        end procedure;

    begin
        reset <= '1'; wait for CLK_PER * 10;
        reset <= '0'; wait for CLK_PER * 5;

        -- Dummy frame to establish LRCLK tracking
        send_frame(x"0000", x"0000");

        -- Test 1
        report "Test 1: L=0xA5A5, R=0x5A5A";
        send_frame(x"A5A5", x"5A5A");
        flush_and_wait;
        check(left_data = x"A5A5",  "T1: left should be 0xA5A5");
        check(right_data = x"5A5A", "T1: right should be 0x5A5A");
        prep_next;

        -- Test 2
        report "Test 2: L=0xFFFF, R=0x0000";
        send_frame(x"FFFF", x"0000");
        flush_and_wait;
        check(left_data = x"FFFF",  "T2: left should be 0xFFFF");
        check(right_data = x"0000", "T2: right should be 0x0000");
        prep_next;

        -- Test 3
        report "Test 3: L=0x1234, R=0xABCD";
        send_frame(x"1234", x"ABCD");
        flush_and_wait;
        check(left_data = x"1234",  "T3: left should be 0x1234");
        check(right_data = x"ABCD", "T3: right should be 0xABCD");

        -- Summary
        if err_count = 0 then
            report "*** I2S RECEIVER: ALL TESTS PASSED ***" severity note;
        else
            report "*** I2S RECEIVER: FAILED " & integer'image(err_count) & " check(s) ***" severity error;
        end if;
        sim_done <= true;
        wait for 5 ns;
        if err_count = 0 then
            assert false report "*** I2S RECEIVER: SIMULATION PASSED ***" severity failure;
        else
            assert false report "*** I2S RECEIVER: SIMULATION FAILED: " &
                integer'image(err_count) & " error(s) ***" severity failure;
        end if;
        wait;
    end process;

end sim;
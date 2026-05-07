-- uart_tb.vhd
-- Self-checking testbench for uart_tx.
--
-- uart_streamer no longer exists as a standalone module — the packet FSM
-- is embedded in spectrum_uart_top and is verified on hardware.
--
-- Tests:
--   T1: Idle TX line is high
--   T2-T5: Send known bytes, decode from TX line, verify value
--   T6: busy asserts during transmit, done pulses on completion

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tb is
end uart_tb;

architecture sim of uart_tb is

    constant CLK_FREQ : integer := 1_000_000;
    constant BAUD_RATE: integer := 100_000;
    constant CLK_PER  : time   := 1 ns;
    constant BAUD_PER : time   := 10 ns;  -- CLK_FREQ/BAUD_RATE * CLK_PER

    signal clk   : std_logic := '0';
    signal rst   : std_logic := '1';

    signal tx_start : std_logic := '0';
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_line  : std_logic;
    signal tx_busy  : std_logic;
    signal tx_done  : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.uart_tx
        generic map (CLK_FREQ => CLK_FREQ, BAUD_RATE => BAUD_RATE)
        port map (
            clk     => clk,
            rst     => rst,
            start   => tx_start,
            data_in => tx_data,
            tx      => tx_line,
            busy    => tx_busy,
            done    => tx_done
        );

    stim : process
        variable err_count : integer := 0;
        variable rx_byte   : std_logic_vector(7 downto 0);

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                report "FAIL: " & msg severity error;
                err_count := err_count + 1;
            end if;
        end procedure;

        -- Decode one 8N1 byte from the TX line.
        -- Waits for start bit, samples centre of each data bit.
        procedure decode_byte(variable result : out std_logic_vector(7 downto 0)) is
        begin
            wait until falling_edge(tx_line);       -- start bit
            wait for BAUD_PER + BAUD_PER / 2;       -- skip to centre of bit 0
            for i in 0 to 7 loop
                result(i) := tx_line;
                wait for BAUD_PER;
            end loop;
        end procedure;

        procedure send_and_check(
            byte_val : std_logic_vector(7 downto 0);
            tag      : string
        ) is
        begin
            if tx_busy = '1' then
                wait until tx_busy = '0';
            end if;
            tx_data  <= byte_val;
            tx_start <= '1';
            wait until rising_edge(clk);
            tx_start <= '0';
            decode_byte(rx_byte);
            check(rx_byte = byte_val,
                  tag & ": decoded 0x" &
                  integer'image(to_integer(unsigned(rx_byte))) &
                  " expected 0x" &
                  integer'image(to_integer(unsigned(byte_val))));
        end procedure;

    begin
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        -- T1: idle line should be high
        wait for CLK_PER * 5;
        check(tx_line = '1', "T1: idle TX line not high");

        -- T2-T5: known byte values
        send_and_check(x"A5", "T2 0xA5");
        send_and_check(x"00", "T3 0x00");
        send_and_check(x"FF", "T4 0xFF");
        send_and_check(x"12", "T5a 0x12");
        send_and_check(x"34", "T5b 0x34");

        -- T6: busy/done handshake
        if tx_busy = '1' then wait until tx_busy = '0'; end if;
        tx_data  <= x"55";
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        wait for CLK_PER * 2;
        check(tx_busy = '1', "T6: busy not asserted during transmit");
        wait until tx_done = '1' for 1 ms;
        check(tx_done = '1', "T6: done never asserted");
        wait until rising_edge(clk);
        check(tx_busy = '0', "T6: busy not deasserted after done");

        -- T7: back-to-back bytes — start second byte the cycle after first completes
        if tx_busy = '1' then wait until tx_busy = '0'; end if;
        tx_data  <= x"AA";
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        wait until tx_done = '1' for 1 ms;
        check(tx_done = '1', "T7: done on first byte never fired");
        tx_data  <= x"BB";
        tx_start <= '1';
        wait until rising_edge(clk);
        tx_start <= '0';
        wait until tx_done = '1' for 1 ms;
        check(tx_done = '1', "T7: done on second byte never fired");

        if err_count = 0 then
            report "*** uart_tx: ALL TESTS PASSED ***" severity note;
        else
            report "*** uart_tx: FAILED " &
                   integer'image(err_count) & " check(s) ***" severity error;
        end if;

        sim_done <= true;
        wait for 5 ns;
        if err_count = 0 then
            assert false report "*** uart_tx: SIMULATION PASSED ***" severity failure;
        else
            assert false report "*** uart_tx: SIMULATION FAILED: " &
                integer'image(err_count) & " error(s) ***" severity failure;
        end if;
        wait;
    end process;

end sim;

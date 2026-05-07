-- bin_buffer_tb.vhd
-- Self-checking testbench for bin_buffer (double-buffer interface).
--
-- Port map:
--   mag_in/mag_valid/mag_last  -> write side
--   read_addr/read_data        -> read side (combinational)
--   frame_available            -> DUT asserts when a frame is ready to read
--   frame_ack                  -> testbench pulses to release the frame
--   overflow                   -> asserts if a new frame finishes before ack
--   write_count                -> current write index (0..511)
--
-- Tests:
--   T1: frame_available low at startup
--   T2: Write 512 values with mag_last on last; frame_available asserts
--   T3: Read back spot-check addresses 0, 1, 128, 511
--   T4: frame_available deasserts after frame_ack pulse
--   T5: No overflow on first frame (reader was fast)
--   T6: Write a second frame while reader is slow -> overflow asserts
--   T7: Reset clears state

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
-- STD.ENV.FINISH not used; xsim is stopped via assert false severity failure

entity bin_buffer_tb is
end bin_buffer_tb;

architecture sim of bin_buffer_tb is

    constant CLK_PER : time := 10 ns;

    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal mag_in          : unsigned(24 downto 0) := (others => '0');
    signal mag_valid       : std_logic := '0';
    signal mag_last        : std_logic := '0';
    signal read_addr       : unsigned(9 downto 0)  := (others => '0');
    signal read_data       : unsigned(24 downto 0);
    signal frame_available : std_logic;
    signal frame_ack       : std_logic := '0';
    signal overflow        : std_logic;
    signal write_count     : unsigned(9 downto 0);

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.bin_buffer
        port map (
            clk             => clk,
            rst             => rst,
            mag_in          => mag_in,
            mag_valid       => mag_valid,
            mag_last        => mag_last,
            read_addr       => read_addr,
            read_data       => read_data,
            frame_available => frame_available,
            frame_ack       => frame_ack,
            overflow        => overflow,
            write_count     => write_count
        );

    stim : process
        variable err_count : integer := 0;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                report "FAIL: " & msg severity error;
                err_count := err_count + 1;
            end if;
        end procedure;

        -- Write N values starting at base_val, asserting mag_last on the last.
        procedure write_frame(n : integer; base_val : integer) is
        begin
            for i in 0 to n - 1 loop
                mag_in    <= to_unsigned(base_val + i, 25);
                mag_valid <= '1';
                if i = n - 1 then
                    mag_last <= '1';
                else
                    mag_last <= '0';
                end if;
                wait until rising_edge(clk);
            end loop;
            mag_valid <= '0';
            mag_last  <= '0';
        end procedure;

    begin
        -- Release reset
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        -- ============================================================
        -- T1: frame_available low at startup
        -- ============================================================
        report "T1: frame_available low at startup";
        check(frame_available = '0', "T1: frame_available asserted at startup");

        -- ============================================================
        -- T2: Write 512 values; expect frame_available after last write
        -- ============================================================
        report "T2: write 512 values, check frame_available";
        write_frame(512, 0);
        -- Allow one extra clock for the registered output to update
        wait until rising_edge(clk);
        check(frame_available = '1',
              "T2: frame_available not asserted after 512-sample frame");

        -- ============================================================
        -- T3: Read back spot-check addresses (combinational read port)
        -- ============================================================
        report "T3: read-back spot check";
        read_addr <= to_unsigned(0, 10);   wait for 1 ns;
        check(to_integer(read_data) = 0,   "T3: addr 0 mismatch");
        read_addr <= to_unsigned(1, 10);   wait for 1 ns;
        check(to_integer(read_data) = 1,   "T3: addr 1 mismatch");
        read_addr <= to_unsigned(128, 10); wait for 1 ns;
        check(to_integer(read_data) = 128, "T3: addr 128 mismatch");
        read_addr <= to_unsigned(511, 10); wait for 1 ns;
        check(to_integer(read_data) = 511, "T3: addr 511 mismatch");

        -- ============================================================
        -- T4: Pulse frame_ack; frame_available should deassert next cycle
        -- ============================================================
        report "T4: frame_ack deasserts frame_available";
        frame_ack <= '1';
        wait until rising_edge(clk);
        frame_ack <= '0';
        wait until rising_edge(clk);
        check(frame_available = '0',
              "T4: frame_available still asserted after frame_ack");

        -- ============================================================
        -- T5: No overflow on first frame (ack'd before second frame)
        -- ============================================================
        report "T5: no overflow when ack is timely";
        write_frame(512, 1000);
        wait until rising_edge(clk);
        check(overflow = '0', "T5: unexpected overflow on second frame");
        check(frame_available = '1',
              "T5: frame_available not asserted on second frame");
        -- Ack it before writing the next
        frame_ack <= '1';
        wait until rising_edge(clk);
        frame_ack <= '0';
        wait until rising_edge(clk);

        -- ============================================================
        -- T6: Overflow — write two frames without acking
        -- ============================================================
        report "T6: overflow when reader is slow";
        -- First frame: write without acking
        write_frame(512, 2000);
        wait until rising_edge(clk);
        check(frame_available = '1', "T6: frame_available not set before overflow test");
        -- Second frame written before ack -> overflow
        write_frame(512, 3000);
        wait until rising_edge(clk);
        check(overflow = '1', "T6: overflow not asserted when second frame dropped");
        -- Ack to clean up
        frame_ack <= '1';
        wait until rising_edge(clk);
        frame_ack <= '0';
        wait until rising_edge(clk);

        -- ============================================================
        -- T7: Reset clears state
        -- ============================================================
        report "T7: reset clears state";
        rst <= '1';
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);
        check(to_integer(write_count) = 0,
              "T7: write_count not 0 after reset");
        check(frame_available = '0',
              "T7: frame_available asserted after reset");

        -- ============================================================
        -- Result
        -- ============================================================
        if err_count = 0 then
            report "*** bin_buffer: ALL TESTS PASSED ***" severity note;
        else
            report "*** bin_buffer: FAILED " &
                   integer'image(err_count) & " check(s) ***" severity error;
        end if;

        sim_done <= true;
        wait for 5 ns;
        if err_count = 0 then
            assert false report "*** bin_buffer: SIMULATION PASSED ***" severity failure;
        else
            assert false report "*** bin_buffer: SIMULATION FAILED: " &
                integer'image(err_count) & " error(s) ***" severity failure;
        end if;
        wait;
    end process;

end sim;

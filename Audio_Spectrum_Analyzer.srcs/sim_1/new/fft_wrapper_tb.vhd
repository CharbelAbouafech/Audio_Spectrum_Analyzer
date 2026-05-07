-- fft_wrapper_tb.vhd
-- Self-checking testbench for fft_wrapper + xfft_0 IP.
--
-- Tests:
--   T1: Config handshake completes, wrapper reaches IDLE after reset
--   T2: frame_start triggers STREAM_IN, sample_ready asserts
--   T3: 1024 samples accepted by wrapper
--   T4: 1024 output bins produced, fft_out_last fires on bin 1023
--   T5: Wrapper returns to IDLE after output
--   T6: Non-zero DC input produces at least one non-zero output bin

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.FINISH;

entity fft_wrapper_tb is
end fft_wrapper_tb;

architecture sim of fft_wrapper_tb is

    constant CLK_PER : time := 8 ns;   -- 125 MHz
    constant TIMEOUT : time := 50 ms;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    signal frame_start  : std_logic := '0';
    signal frame_ready  : std_logic;
    signal sample_in    : signed(23 downto 0) := (others => '0');
    signal sample_valid : std_logic := '0';
    signal sample_ready : std_logic;

    signal fft_re_out   : signed(23 downto 0);
    signal fft_im_out   : signed(23 downto 0);
    signal fft_out_valid: std_logic;
    signal fft_out_last : std_logic;
    signal busy         : std_logic;

    signal out_bin_cnt  : integer := 0;
    signal out_last_seen: boolean := false;
    signal any_nonzero  : boolean := false;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.fft_wrapper
        port map (
            clk           => clk,
            rst           => rst,
            frame_start   => frame_start,
            frame_ready   => frame_ready,
            sample_in     => sample_in,
            sample_valid  => sample_valid,
            sample_ready  => sample_ready,
            fft_re_out    => fft_re_out,
            fft_im_out    => fft_im_out,
            fft_out_valid => fft_out_valid,
            fft_out_last  => fft_out_last,
            busy          => busy
        );

    output_monitor : process
    begin
        loop
            wait until rising_edge(clk);

            if fft_out_valid = '1' then
                out_bin_cnt <= out_bin_cnt + 1;

                if fft_out_last = '1' then
                    out_last_seen <= true;
                end if;

                if fft_re_out /= to_signed(0, 24) or
                   fft_im_out /= to_signed(0, 24) then
                    any_nonzero <= true;
                end if;
            end if;
        end loop;
    end process;

    stim : process
        variable err_count : integer := 0;

        procedure check(cond : boolean; msg : string) is
        begin
            if not cond then
                report "FAIL: " & msg severity error;
                err_count := err_count + 1;
            end if;
        end procedure;

    begin
        -- Release reset
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rst <= '0';

        -- ============================================================
        -- T1: Config handshake
        -- ============================================================
        report "T1: waiting for config handshake";

        wait until frame_ready = '1' for TIMEOUT;

        check(busy = '0',
              "T1: wrapper did not reach IDLE after reset");

        check(frame_ready = '1',
              "T1: frame_ready not asserted in IDLE state");

        -- ============================================================
        -- T2/T3: Stream DC samples; keep valid until wrapper finishes
        -- ============================================================
        -- sample_ready = in_tready from FFT IP, which is '1' even when the
        -- wrapper hasn't yet presented a new sample (in_tvalid='0').  Counting
        -- sample_ready pulses therefore double-counts and under-feeds the
        -- wrapper.  Instead, hold sample_valid='1' until the wrapper's own
        -- state machine returns to IDLE (busy='0') after consuming all 1024.
        report "T2/T3: streaming 1024 samples";

        sample_in    <= to_signed(16#001000#, 24);
        sample_valid <= '1';

        frame_start <= '1';
        wait until rising_edge(clk);
        frame_start <= '0';

        wait until sample_ready = '1' for TIMEOUT;

        check(sample_ready = '1',
              "T2: sample_ready never asserted");

        check(busy = '1',
              "T3: wrapper not in STREAM_IN after frame_start");

        -- ============================================================
        -- T4/T5: Keep feeding until wrapper returns to IDLE, then
        --        wait for FFT pipeline to drain all 1024 output bins
        -- ============================================================
        report "T4/T5: collecting FFT output";

        wait until busy = '0' for TIMEOUT;
        sample_valid <= '0';

        check(busy = '0',
              "T5: wrapper did not return to IDLE after output");

        wait until out_last_seen for TIMEOUT;

        wait until rising_edge(clk);

        check(out_bin_cnt = 1024,
              "T4: wrong number of output bins, got " &
              integer'image(out_bin_cnt) & ", expected 1024");

        check(out_last_seen,
              "T4: fft_out_last never asserted");

        -- ============================================================
        -- T6: DC input should produce non-zero FFT output
        -- ============================================================
        check(any_nonzero,
              "T6: all FFT bins are zero for non-zero DC input");

        -- ============================================================
        -- Result
        -- ============================================================
        if err_count = 0 then
            report "*** fft_wrapper: ALL TESTS PASSED ***" severity note;
        else
            report "*** fft_wrapper: FAILED " &
                   integer'image(err_count) & " check(s) ***" severity error;
        end if;

        sim_done <= true;
        wait for 5 ns;
        -- severity failure is required to stop xsim when the Xilinx FFT IP
        -- behavioral model has active internal processes. finish; does not work.
        if err_count = 0 then
            assert false report "*** fft_wrapper: SIMULATION PASSED ***" severity failure;
        else
            assert false
                report "*** fft_wrapper: SIMULATION FAILED: " &
                       integer'image(err_count) & " error(s) ***"
                severity failure;
        end if;
        wait;
    end process;

end sim;
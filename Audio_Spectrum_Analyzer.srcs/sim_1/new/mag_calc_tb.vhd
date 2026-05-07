-- mag_calc_tb.vhd
-- Self-checking testbench for magnitude_calc.
-- Tests: positive/negative inputs, zero, last propagation, reset.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.FINISH;

entity mag_calc_tb is
end mag_calc_tb;

architecture sim of mag_calc_tb is

    constant CLK_PER : time := 10 ns;

    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal re_in     : signed(23 downto 0)   := (others => '0');
    signal im_in     : signed(23 downto 0)   := (others => '0');
    signal valid_in  : std_logic := '0';
    signal last_in   : std_logic := '0';
    signal mag_out   : unsigned(24 downto 0);
    signal valid_out : std_logic;
    signal last_out  : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PER / 2 when not sim_done else '0';

    uut : entity work.magnitude_calc
        port map (
            clk       => clk,
            rst       => rst,
            re_in     => re_in,
            im_in     => im_in,
            valid_in  => valid_in,
            last_in   => last_in,
            mag_out   => mag_out,
            valid_out => valid_out,
            last_out  => last_out
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

        -- Drive one input pair and check the registered output one cycle later.
        -- Signals are driven directly (no procedure signal parameters needed).
        procedure apply(re : integer; im : integer; last : std_logic) is
        begin
            re_in    <= to_signed(re, 24);
            im_in    <= to_signed(im, 24);
            valid_in <= '1';
            last_in  <= last;
            wait until rising_edge(clk);
            valid_in <= '0';
            last_in  <= '0';
            wait until rising_edge(clk);
        end procedure;

    begin
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        -- T1: positive Re only
        apply(16#100000#, 0, '0');
        check(valid_out = '1',                                 "T1: valid_out");
        check(mag_out = to_unsigned(16#100000#, 25),           "T1: magnitude");
        check(last_out = '0',                                  "T1: last_out");

        -- T2: positive Im only
        apply(0, 16#100000#, '0');
        check(valid_out = '1',                                 "T2: valid_out");
        check(mag_out = to_unsigned(16#100000#, 25),           "T2: magnitude");

        -- T3: both positive: 0x300000 + 0x400000 = 0x700000
        apply(16#300000#, 16#400000#, '0');
        check(valid_out = '1',                                 "T3: valid_out");
        check(mag_out = to_unsigned(16#700000#, 25),           "T3: magnitude");

        -- T4: negative Re — abs must be taken
        apply(-16#100000#, 0, '0');
        check(valid_out = '1',                                 "T4: valid_out");
        check(mag_out = to_unsigned(16#100000#, 25),           "T4: magnitude");

        -- T5: negative Im
        apply(0, -16#100000#, '0');
        check(valid_out = '1',                                 "T5: valid_out");
        check(mag_out = to_unsigned(16#100000#, 25),           "T5: magnitude");

        -- T6: both negative: abs(−0x200000) + abs(−0x300000) = 0x500000
        apply(-16#200000#, -16#300000#, '0');
        check(valid_out = '1',                                 "T6: valid_out");
        check(mag_out = to_unsigned(16#500000#, 25),           "T6: magnitude");

        -- T7: zero input
        apply(0, 0, '0');
        check(valid_out = '1',                                 "T7: valid_out");
        check(mag_out = to_unsigned(0, 25),                    "T7: magnitude zero");

        -- T8: last_in propagates to last_out
        apply(16#010000#, 16#020000#, '1');
        check(valid_out = '1',                                 "T8: valid_out");
        check(mag_out = to_unsigned(16#030000#, 25),           "T8: magnitude");
        check(last_out = '1',                                  "T8: last_out not propagated");

        -- T9: valid_out deasserted when valid_in=0
        re_in    <= (others => '0');
        im_in    <= (others => '0');
        valid_in <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check(valid_out = '0', "T9: valid_out high with no input");

        -- T10: reset clears all outputs
        re_in    <= to_signed(16#100000#, 24);
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0';
        rst      <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        check(valid_out = '0',              "T10: valid_out not cleared by reset");
        check(mag_out = to_unsigned(0, 25), "T10: mag_out not cleared by reset");
        rst <= '0';

        if err_count = 0 then
            report "*** magnitude_calc: ALL TESTS PASSED ***" severity note;
        else
            report "*** magnitude_calc: FAILED " &
                   integer'image(err_count) & " check(s) ***" severity error;
        end if;

        sim_done <= true;
        wait for 5 ns;
        if err_count = 0 then
            assert false report "*** magnitude_calc: SIMULATION PASSED ***" severity failure;
        else
            assert false report "*** magnitude_calc: SIMULATION FAILED: " &
                integer'image(err_count) & " error(s) ***" severity failure;
        end if;
        wait;
    end process;

end sim;

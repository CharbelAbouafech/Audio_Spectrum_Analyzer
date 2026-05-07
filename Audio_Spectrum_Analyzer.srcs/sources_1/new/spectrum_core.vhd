library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spectrum_core is
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- sample input stream
        frame_start  : in  std_logic;
        frame_ready  : out std_logic;
        sample_in    : in  signed(23 downto 0);
        sample_valid : in  std_logic;
        sample_ready : out std_logic;

        -- magnitude output stream
        mag_out      : out unsigned(24 downto 0);
        mag_valid    : out std_logic;
        mag_last     : out std_logic;

        fft_busy     : out std_logic
    );
end entity;

architecture rtl of spectrum_core is

    signal fft_re    : signed(23 downto 0);
    signal fft_im    : signed(23 downto 0);
    signal fft_valid : std_logic;
    signal fft_last  : std_logic;

begin

    u_fft : entity work.fft_wrapper
        port map (
            clk           => clk,
            rst           => rst,
            frame_start   => frame_start,
            frame_ready   => frame_ready,
            sample_in     => sample_in,
            sample_valid  => sample_valid,
            sample_ready  => sample_ready,
            fft_re_out    => fft_re,
            fft_im_out    => fft_im,
            fft_out_valid => fft_valid,
            fft_out_last  => fft_last,
            busy          => fft_busy
        );

    u_mag : entity work.magnitude_calc
        port map (
            clk       => clk,
            rst       => rst,
            re_in     => fft_re,
            im_in     => fft_im,
            valid_in  => fft_valid,
            last_in   => fft_last,
            mag_out   => mag_out,
            valid_out => mag_valid,
            last_out  => mag_last
        );

end architecture;

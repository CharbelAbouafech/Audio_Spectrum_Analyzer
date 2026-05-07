library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity magnitude_calc is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        re_in     : in  signed(23 downto 0);
        im_in     : in  signed(23 downto 0);
        valid_in  : in  std_logic;
        last_in   : in  std_logic;

        mag_out   : out unsigned(24 downto 0);
        valid_out : out std_logic;
        last_out  : out std_logic
    );
end entity;

architecture rtl of magnitude_calc is

    function abs_signed(x : signed) return unsigned is
    begin
        if x(x'left) = '1' then
            return unsigned(-x);
        else
            return unsigned(x);
        end if;
    end function;

begin

    process(clk)
        variable re_abs : unsigned(23 downto 0);
        variable im_abs : unsigned(23 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                mag_out   <= (others => '0');
                valid_out <= '0';
                last_out  <= '0';
            else
                if valid_in = '1' then
                    re_abs := abs_signed(re_in);
                    im_abs := abs_signed(im_in);

                    mag_out   <= ('0' & re_abs) + ('0' & im_abs);
                    valid_out <= '1';
                    last_out  <= last_in;
                else
                    valid_out <= '0';
                    last_out  <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture;
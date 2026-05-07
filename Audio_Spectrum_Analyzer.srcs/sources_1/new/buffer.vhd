library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bin_buffer is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- write side from magnitude block
        mag_in          : in  unsigned(24 downto 0);
        mag_valid       : in  std_logic;
        mag_last        : in  std_logic;

        -- read side for UART
        read_addr       : in  unsigned(9 downto 0);  -- 0 to 1023
        read_data       : out unsigned(24 downto 0);

        -- frame handshake
        frame_available : out std_logic;
        frame_ack       : in  std_logic;

        -- status
        overflow        : out std_logic;
        write_count     : out unsigned(9 downto 0)
    );
end entity;

architecture rtl of bin_buffer is

    type ram_t is array (0 to 1023) of unsigned(24 downto 0);
    signal ram0 : ram_t := (others => (others => '0'));
    signal ram1 : ram_t := (others => (others => '0'));

    signal wr_idx            : integer range 0 to 1023 := 0;
    signal write_bank        : std_logic := '0';
    signal read_bank         : std_logic := '0';
    signal frame_available_s : std_logic := '0';
    signal overflow_s        : std_logic := '0';

begin

    read_data <= ram0(to_integer(read_addr)) when read_bank = '0' else
                 ram1(to_integer(read_addr));

    frame_available <= frame_available_s;
    overflow        <= overflow_s;
    write_count     <= to_unsigned(wr_idx, 10);

    process(clk)
        variable avail_v      : std_logic;
        variable read_bank_v  : std_logic;
        variable write_bank_v : std_logic;
        variable wr_idx_v     : integer range 0 to 1023;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                wr_idx            <= 0;
                write_bank        <= '0';
                read_bank         <= '0';
                frame_available_s <= '0';
                overflow_s        <= '0';

            else
                avail_v      := frame_available_s;
                read_bank_v  := read_bank;
                write_bank_v := write_bank;
                wr_idx_v     := wr_idx;

                overflow_s <= '0';

                if frame_ack = '1' then
                    avail_v := '0';
                end if;

                if mag_valid = '1' then
                    if write_bank = '0' then
                        ram0(wr_idx) <= mag_in;
                    else
                        ram1(wr_idx) <= mag_in;
                    end if;

                    if mag_last = '1' then
                        -- Full frame complete: swap banks if the UART has consumed the previous one.
                        if avail_v = '0' then
                            read_bank_v := write_bank;
                            avail_v     := '1';

                            if write_bank = '0' then
                                write_bank_v := '1';
                            else
                                write_bank_v := '0';
                            end if;
                        else
                            -- UART side has not consumed the previous frame yet; drop this one.
                            overflow_s <= '1';
                        end if;

                        wr_idx_v := 0;
                    else
                        if wr_idx_v < 1023 then
                            wr_idx_v := wr_idx + 1;
                        end if;
                    end if;
                end if;

                frame_available_s <= avail_v;
                read_bank         <= read_bank_v;
                write_bank        <= write_bank_v;
                wr_idx            <= wr_idx_v;
            end if;
        end if;
    end process;

end architecture;

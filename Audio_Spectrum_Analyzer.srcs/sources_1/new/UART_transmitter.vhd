library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLK_FREQ  : integer := 100000000;
        BAUD_RATE : integer := 115200
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        start    : in  std_logic;
        data_in  : in  std_logic_vector(7 downto 0);
        tx       : out std_logic;
        busy     : out std_logic;
        done     : out std_logic
    );
end entity;

architecture rtl of uart_tx is

    constant BAUD_TICK_COUNT : integer := CLK_FREQ / BAUD_RATE;

    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state : state_t := IDLE;

    signal baud_cnt  : integer range 0 to BAUD_TICK_COUNT := 0;
    signal bit_cnt   : integer range 0 to 7 := 0;
    signal shreg     : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_reg    : std_logic := '1';
    signal busy_reg  : std_logic := '0';
    signal done_reg  : std_logic := '0';

begin

    tx   <= tx_reg;
    busy <= busy_reg;
    done <= done_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state    <= IDLE;
                baud_cnt <= 0;
                bit_cnt  <= 0;
                shreg    <= (others => '0');
                tx_reg   <= '1';
                busy_reg <= '0';
                done_reg <= '0';

            else
                done_reg <= '0';

                case state is

                    when IDLE =>
                        tx_reg   <= '1';
                        busy_reg <= '0';
                        baud_cnt <= 0;
                        bit_cnt  <= 0;

                        if start = '1' then
                            shreg    <= data_in;
                            busy_reg <= '1';
                            state    <= START_BIT;
                        end if;

                    when START_BIT =>
                        tx_reg <= '0';
                        if baud_cnt = BAUD_TICK_COUNT - 1 then
                            baud_cnt <= 0;
                            state    <= DATA_BITS;
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;

                    when DATA_BITS =>
                        tx_reg <= shreg(bit_cnt);
                        if baud_cnt = BAUD_TICK_COUNT - 1 then
                            baud_cnt <= 0;
                            if bit_cnt = 7 then
                                bit_cnt <= 0;
                                state   <= STOP_BIT;
                            else
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;

                    when STOP_BIT =>
                        tx_reg <= '1';
                        if baud_cnt = BAUD_TICK_COUNT - 1 then
                            baud_cnt <= 0;
                            busy_reg <= '0';
                            done_reg <= '1';
                            state    <= IDLE;
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;
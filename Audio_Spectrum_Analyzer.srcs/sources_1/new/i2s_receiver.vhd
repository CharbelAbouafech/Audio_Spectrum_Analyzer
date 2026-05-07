-- i2s_receiver.vhd
-- Deserializes I2S audio data from the SSM2603 codec operating in master mode.
-- The codec drives BCLK, LRCLK, and SDATA; this module samples them
-- synchronously to the FPGA system clock.
--
-- I2S format: MSB-first, data delayed by 1 BCLK after LRCLK edge.
-- LRCLK low = left channel, LRCLK high = right channel.
-- Valid pulses once per sample period when both L+R are ready.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2s_receiver is
    generic (
        DATA_WIDTH : integer := 16
    );
    port (
        clk        : in  std_logic;  -- System clock (125 MHz)
        reset      : in  std_logic;
        -- I2S interface (directly from codec pins)
        bclk       : in  std_logic;  -- Bit clock
        lrclk      : in  std_logic;  -- Left/right word clock
        sdata      : in  std_logic;  -- Serial data
        -- Parallel output
        left_data  : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        right_data : out std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid      : out std_logic   -- Pulse: new L+R pair ready
    );
end i2s_receiver;

architecture rtl of i2s_receiver is

    -- 2/3-stage synchronizers for async codec signals
    signal bclk_sync  : std_logic_vector(2 downto 0) := "000";
    signal lrclk_sync : std_logic_vector(1 downto 0) := "00";
    signal sdata_sync : std_logic_vector(1 downto 0) := "00";

    -- Edge detection
    signal bclk_rise  : std_logic;

    -- Deserialization state
    signal lrclk_prev : std_logic := '0';
    signal bit_cnt    : integer range 0 to 63 := 0;
    signal shift      : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');

    -- Output registers
    signal left_reg   : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal right_reg  : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
    signal valid_r    : std_logic := '0';

begin

    -- Synchronize codec signals into system clock domain
    process(clk)
    begin
        if rising_edge(clk) then
            bclk_sync  <= bclk_sync(1 downto 0) & bclk;
            lrclk_sync <= lrclk_sync(0) & lrclk;
            sdata_sync <= sdata_sync(0) & sdata;
        end if;
    end process;

    -- Rising edge of BCLK (3-stage: 2 for sync + 1 for edge detect)
    bclk_rise <= '1' when bclk_sync(2 downto 1) = "01" else '0';

    -- I2S deserialization, clocked by detected BCLK rising edges
    process(clk)
    begin
        if rising_edge(clk) then
            valid_r <= '0';

            if reset = '1' then
                lrclk_prev <= '0';
                bit_cnt    <= 0;
                shift      <= (others => '0');
                left_reg   <= (others => '0');
                right_reg  <= (others => '0');

            elsif bclk_rise = '1' then
                -- Track LRCLK transitions on BCLK rising edges
                lrclk_prev <= lrclk_sync(1);

                if lrclk_sync(1) /= lrclk_prev then
                    -- LRCLK edge detected: latch the completed channel
                    if lrclk_sync(1) = '1' then
                        -- Rising: left channel just finished
                        left_reg <= shift;
                    else
                        -- Falling: right channel just finished, pair is ready
                        right_reg <= shift;
                        valid_r   <= '1';
                    end if;
                    -- Reset for new channel; this BCLK is the I2S dummy bit
                    bit_cnt <= 0;
                    shift   <= (others => '0');
                else
                    -- Shift in data bits (skip bit_cnt 0 = I2S one-clock delay)
                    if bit_cnt >= 1 and bit_cnt <= DATA_WIDTH then
                        shift <= shift(DATA_WIDTH - 2 downto 0) & sdata_sync(1);
                    end if;
                    if bit_cnt < 63 then
                        bit_cnt <= bit_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    left_data  <= left_reg;
    right_data <= right_reg;
    valid      <= valid_r;

end rtl;
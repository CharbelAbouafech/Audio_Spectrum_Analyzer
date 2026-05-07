-- ssm2603_init.vhd
-- Configures the SSM2603 audio codec over I2C for line-in capture.
-- Instantiates i2c_master internally and sequences through a register
-- configuration table at startup.
--
-- Configuration:
--   line-in -> ADC
--   I2S format
--   16-bit samples
--   codec master mode
--   USB mode, 48 kHz sample rate
--
-- NOTE:
--   Your current top-level supplies 12.5 MHz MCLK.
--   This file was originally commented for 12 MHz USB-mode MCLK.
--   We are only fixing the analog input path here first.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ssm2603_init is
    generic (
        CLK_FREQ : integer := 125_000_000;
        I2C_FREQ : integer := 100_000
    );
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;

        -- I2C bus drive signals.
        -- scl_o and sda_o are open-drain style drive controls:
        --   '0' = pull bus low
        --   '1' = release bus high-Z in top-level
        scl_o     : out std_logic;
        sda_o     : out std_logic;
        sda_i     : in  std_logic;

        -- Status
        init_done : out std_logic;
        init_err  : out std_logic
    );
end ssm2603_init;

architecture rtl of ssm2603_init is

    --------------------------------------------------------------------
    -- SSM2603 I2C address
    --------------------------------------------------------------------
    constant CODEC_ADDR : std_logic_vector(6 downto 0) := "0011010";

    --------------------------------------------------------------------
    -- Register configuration table
    --
    -- Each entry is:
    --   { reg_addr[6:0], reg_data[8:0] } = 16 bits
    --
    -- SSM2603 I2C format:
    --   first data byte  = { register_address[6:0], data_bit_8 }
    --   second data byte = data_bits[7:0]
    --------------------------------------------------------------------
    type reg_table_type is array(natural range <>) of std_logic_vector(15 downto 0);

    constant NUM_REGS : integer := 9;

    constant REG_TABLE : reg_table_type(0 to NUM_REGS - 1) := (

        ----------------------------------------------------------------
        -- R15 = 0x000 : Software reset
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#1E00#, 16)),

        ----------------------------------------------------------------
        -- R6 = 0x01A : Power-down control
        --
        -- Bit meanings, low value usually means powered up:
        --   LINEINPD = 0  line input powered
        --   MICPD    = 1  microphone path powered down
        --   ADCPD    = 0  ADC powered
        --   DACPD    = 1  DAC powered down
        --   OUTPD    = 1  output path powered down
        --   OSCPD    = 0  oscillator active
        --   CLKOUTPD = 0  clock output active
        --   PWROFF   = 0  chip powered
        --
        -- This is okay for line-in ADC capture.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#0C1A#, 16)),

        ----------------------------------------------------------------
        -- R0 = 0x017 : Left line-in volume
        --
        -- 0 dB-ish line input level, unmuted.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#0017#, 16)),

        ----------------------------------------------------------------
        -- R1 = 0x017 : Right line-in volume
        --
        -- 0 dB-ish line input level, unmuted.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#0217#, 16)),

        ----------------------------------------------------------------
        -- R4 = 0x000 : Analog audio path control
        --
        -- Important fix:
        --   INSEL   = 0  select line input, not microphone
        --   MICMUTE = 0  not important because mic is not selected
        --   MICBOOST= 0  mic boost off
        --
        -- Your old value was 0x005, which selected microphone input
        -- while R6 powered the microphone path down. That was inconsistent
        -- with line-in capture.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#0800#, 16)),

        ----------------------------------------------------------------
        -- R5 = 0x000 : Digital audio path control
        --
        -- ADC high-pass filter enabled by default behavior, no de-emphasis.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#0A00#, 16)),

        ----------------------------------------------------------------
        -- R7 = 0x042 : Digital audio interface format
        --
        -- I2S format, 16-bit word length, codec master mode.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#0E42#, 16)),

        ----------------------------------------------------------------
        -- R8 = 0x001 : Sampling control
        --
        -- USB mode, 48 kHz setting.
        --
        -- Note:
        --   This was your existing setting. If LRCLK still does not appear,
        --   the next thing to fix is MCLK/sample-rate clocking.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#1001#, 16)),

        ----------------------------------------------------------------
        -- R9 = 0x001 : Active control
        --
        -- Activate digital audio interface.
        ----------------------------------------------------------------
        std_logic_vector(to_unsigned(16#1201#, 16))
    );

    --------------------------------------------------------------------
    -- Delays
    --------------------------------------------------------------------
    constant STARTUP_DELAY : integer := CLK_FREQ / 100;  -- 10 ms
    constant RESET_DELAY   : integer := CLK_FREQ / 10;   -- 100 ms

    --------------------------------------------------------------------
    -- FSM
    --------------------------------------------------------------------
    type state_type is (
        ST_DELAY,
        ST_SEND,
        ST_WAIT_I2C,
        ST_DONE
    );

    signal state : state_type := ST_DELAY;

    signal reg_idx     : integer range 0 to NUM_REGS - 1 := 0;
    signal delay_cnt   : integer range 0 to RESET_DELAY := 0;
    signal delay_tgt   : integer range 0 to RESET_DELAY := STARTUP_DELAY;

    signal done_flag   : std_logic := '0';
    signal err_flag    : std_logic := '0';

    --------------------------------------------------------------------
    -- I2C master interface
    --------------------------------------------------------------------
    signal i2c_start   : std_logic := '0';
    signal i2c_busy    : std_logic;
    signal i2c_done    : std_logic;
    signal i2c_ack_err : std_logic;

begin

    init_done <= done_flag;
    init_err  <= err_flag;

    --------------------------------------------------------------------
    -- I2C master instance
    --------------------------------------------------------------------
    u_i2c : entity work.i2c_master
        generic map (
            CLK_FREQ => CLK_FREQ,
            I2C_FREQ => I2C_FREQ
        )
        port map (
            clk     => clk,
            reset   => reset,
            start   => i2c_start,
            addr    => CODEC_ADDR,
            data    => REG_TABLE(reg_idx),
            busy    => i2c_busy,
            done    => i2c_done,
            ack_err => i2c_ack_err,
            scl_o   => scl_o,
            sda_o   => sda_o,
            sda_i   => sda_i
        );

    --------------------------------------------------------------------
    -- Configuration sequencer
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            i2c_start <= '0';

            if reset = '1' then
                state     <= ST_DELAY;
                reg_idx   <= 0;
                delay_cnt <= 0;
                delay_tgt <= STARTUP_DELAY;
                done_flag <= '0';
                err_flag  <= '0';

            else
                case state is

                    ----------------------------------------------------
                    -- Wait for either startup delay or post-reset delay
                    ----------------------------------------------------
                    when ST_DELAY =>
                        if delay_cnt = delay_tgt then
                            delay_cnt <= 0;
                            state     <= ST_SEND;
                        else
                            delay_cnt <= delay_cnt + 1;
                        end if;

                    ----------------------------------------------------
                    -- Pulse i2c_start for one clk cycle
                    ----------------------------------------------------
                    when ST_SEND =>
                        i2c_start <= '1';
                        state     <= ST_WAIT_I2C;

                    ----------------------------------------------------
                    -- Wait for I2C transaction completion
                    ----------------------------------------------------
                    when ST_WAIT_I2C =>
                        if i2c_done = '1' then

                            if i2c_ack_err = '1' then
                                err_flag <= '1';
                            end if;

                            if reg_idx = 0 then
                                -- Just sent software reset.
                                -- Give the codec time to recover.
                                delay_tgt <= RESET_DELAY;
                                delay_cnt <= 0;
                                reg_idx   <= 1;
                                state     <= ST_DELAY;

                            elsif reg_idx = NUM_REGS - 1 then
                                -- All registers written.
                                done_flag <= '1';
                                state     <= ST_DONE;

                            else
                                reg_idx <= reg_idx + 1;
                                state   <= ST_SEND;
                            end if;
                        end if;

                    ----------------------------------------------------
                    -- Finished
                    ----------------------------------------------------
                    when ST_DONE =>
                        null;

                end case;
            end if;
        end if;
    end process;

end rtl;
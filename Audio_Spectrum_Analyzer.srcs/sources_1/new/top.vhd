library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top is
    generic (
        CLK_FREQ   : integer := 125_000_000;
        I2C_FREQ   : integer := 100_000;
        DATA_WIDTH : integer := 16;
        BAUD_RATE  : integer := 312_500
    );
    port (
        clk_125     : in    std_logic;

        -- SSM2603 I2C
        ac_scl      : out   std_logic;
        ac_sda      : inout std_logic;

        -- SSM2603 I2S, codec master mode
        ac_mclk     : out   std_logic;
        ac_bclk     : in    std_logic;
        ac_lrclk    : in    std_logic;
        ac_recdat   : in    std_logic;

        -- UART on Pmod USBUART
        uart_tx     : out   std_logic;
        uart_rx     : in    std_logic;
        uart_rts    : in    std_logic;
        uart_cts    : out   std_logic;

        -- Status LEDs
        led         : out   std_logic_vector(3 downto 0)
    );
end top;

architecture rtl of top is

    --------------------------------------------------------------------
    -- Reset
    --------------------------------------------------------------------
    signal reset      : std_logic := '1';
    signal reset_cnt  : integer range 0 to CLK_FREQ / 100 := 0;

    --------------------------------------------------------------------
    -- MCLK: 12.5 MHz from 125 MHz / 10
    --------------------------------------------------------------------
    constant MCLK_DIV : integer := 5;
    signal mclk_cnt   : integer range 0 to MCLK_DIV - 1 := 0;
    signal mclk_r     : std_logic := '0';

    --------------------------------------------------------------------
    -- Heartbeat
    --------------------------------------------------------------------
    signal hb_cnt : unsigned(25 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- I2C open-drain drive signals
    --------------------------------------------------------------------
    signal scl_drive : std_logic;
    signal sda_drive : std_logic;
    signal sda_in    : std_logic;

    --------------------------------------------------------------------
    -- Codec init status
    --------------------------------------------------------------------
    signal init_done : std_logic;
    signal init_err  : std_logic;

    --------------------------------------------------------------------
    -- I2S receiver outputs
    --------------------------------------------------------------------
    signal i2s_left  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal i2s_right : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal i2s_valid : std_logic;

    --------------------------------------------------------------------
    -- One-sample staging register
    --------------------------------------------------------------------
    signal pending_sample : signed(23 downto 0) := (others => '0');
    signal pending_valid  : std_logic := '0';

    --------------------------------------------------------------------
    -- Frame control FSM
    --------------------------------------------------------------------
    type frm_state_t is (WAIT_INIT, WAIT_FRAME_READY, STREAM);
    signal frm_state  : frm_state_t := WAIT_INIT;
    signal sample_cnt : integer range 0 to 1023 := 0;

    --------------------------------------------------------------------
    -- FFT pipeline interface
    --------------------------------------------------------------------
    signal frame_start      : std_logic := '0';
    signal fft_valid        : std_logic := '0';
    signal fft_sample_ready : std_logic;
    signal fft_frame_ready  : std_logic;

    --------------------------------------------------------------------
    -- Debug from spectrum pipeline
    --------------------------------------------------------------------
    signal dbg_mag_valid    : std_logic;
    signal dbg_uart_start   : std_logic;
    signal dbg_frame_done   : std_logic;

    --------------------------------------------------------------------
    -- LED pulse stretchers
    --------------------------------------------------------------------
    signal mag_led_hold         : integer range 0 to CLK_FREQ / 4 := 0;
    signal uart_start_led_hold  : integer range 0 to CLK_FREQ / 4 := 0;
    signal uart_done_led_hold   : integer range 0 to CLK_FREQ / 4 := 0;

begin

    --------------------------------------------------------------------
    -- MCLK generation
    --------------------------------------------------------------------
    process(clk_125)
    begin
        if rising_edge(clk_125) then
            if mclk_cnt = MCLK_DIV - 1 then
                mclk_cnt <= 0;
                mclk_r   <= not mclk_r;
            else
                mclk_cnt <= mclk_cnt + 1;
            end if;
        end if;
    end process;

    ac_mclk <= mclk_r;

    --------------------------------------------------------------------
    -- Power-on reset: about 10 ms
    --------------------------------------------------------------------
    process(clk_125)
    begin
        if rising_edge(clk_125) then
            if reset_cnt = CLK_FREQ / 100 then
                reset <= '0';
            else
                reset_cnt <= reset_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Heartbeat
    --------------------------------------------------------------------
    process(clk_125)
    begin
        if rising_edge(clk_125) then
            if reset = '1' then
                hb_cnt <= (others => '0');
            else
                hb_cnt <= hb_cnt + 1;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- I2C open-drain bus drivers
    --------------------------------------------------------------------
    ac_scl <= '0' when scl_drive = '0' else 'Z';
    ac_sda <= '0' when sda_drive = '0' else 'Z';
    sda_in <= ac_sda;

    --------------------------------------------------------------------
    -- UART flow-control default
    --------------------------------------------------------------------
    uart_cts <= '0';

    --------------------------------------------------------------------
    -- SSM2603 I2C initializer
    --------------------------------------------------------------------
    u_codec_init : entity work.ssm2603_init
        generic map (
            CLK_FREQ => CLK_FREQ,
            I2C_FREQ => I2C_FREQ
        )
        port map (
            clk       => clk_125,
            reset     => reset,
            scl_o     => scl_drive,
            sda_o     => sda_drive,
            sda_i     => sda_in,
            init_done => init_done,
            init_err  => init_err
        );

    --------------------------------------------------------------------
    -- I2S receiver
    --------------------------------------------------------------------
    u_i2s : entity work.i2s_receiver
        generic map (
            DATA_WIDTH => DATA_WIDTH
        )
        port map (
            clk        => clk_125,
            reset      => reset,
            bclk       => ac_bclk,
            lrclk      => ac_lrclk,
            sdata      => ac_recdat,
            left_data  => i2s_left,
            right_data => i2s_right,
            valid      => i2s_valid
        );

    --------------------------------------------------------------------
    -- Frame accumulator and sample staging
    --------------------------------------------------------------------
    process(clk_125)
        variable consume_v        : boolean;
        variable pending_valid_v  : std_logic;
        variable pending_sample_v : signed(23 downto 0);
    begin
        if rising_edge(clk_125) then
            frame_start <= '0';
            fft_valid   <= '0';

            if reset = '1' then
                pending_sample <= (others => '0');
                pending_valid  <= '0';
                frm_state      <= WAIT_INIT;
                sample_cnt     <= 0;

            else
                consume_v        := false;
                pending_valid_v  := pending_valid;
                pending_sample_v := pending_sample;

                case frm_state is

                    when WAIT_INIT =>
                        sample_cnt <= 0;

                        if init_done = '1' then
                            frm_state <= WAIT_FRAME_READY;
                        end if;

                    when WAIT_FRAME_READY =>
                        sample_cnt <= 0;

                        if fft_frame_ready = '1' then
                            frame_start <= '1';
                            frm_state   <= STREAM;
                        end if;

                    when STREAM =>
                        if pending_valid = '1' and fft_sample_ready = '1' then
                            fft_valid <= '1';
                            consume_v := true;

                            if sample_cnt = 1023 then
                                sample_cnt <= 0;
                                frm_state  <= WAIT_FRAME_READY;
                            else
                                sample_cnt <= sample_cnt + 1;
                            end if;
                        end if;

                end case;

                -- Latch new I2S sample, left channel, sign-extended to 24 bits.
                if i2s_valid = '1' then
                    if pending_valid_v = '0' or consume_v then
                        pending_sample_v := resize(signed(i2s_left), 24);
                        pending_valid_v  := '1';
                    end if;

                elsif consume_v then
                    pending_valid_v := '0';
                end if;

                pending_sample <= pending_sample_v;
                pending_valid  <= pending_valid_v;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- FFT + magnitude + buffer + packetized UART pipeline
    --------------------------------------------------------------------
    u_spectrum : entity work.spectrum_uart_top
        generic map (
            CLK_FREQ    => CLK_FREQ,
            BAUD_RATE   => BAUD_RATE,
            TOTAL_BINS  => 1024,
            SEND_BINS   => 256,
            BIN_STRIDE  => 2,
            FRAME_DECIM => 1,
            SCALE_SHIFT => 4
        )
        port map (
            clk              => clk_125,
            rst              => reset,

            frame_start      => frame_start,
            frame_ready      => fft_frame_ready,

            sample_in        => pending_sample,
            sample_valid     => fft_valid,
            sample_ready     => fft_sample_ready,

            uart_tx_o        => uart_tx,

            debug_mag_valid  => dbg_mag_valid,
            debug_uart_start => dbg_uart_start,
            debug_frame_done => dbg_frame_done
        );

    --------------------------------------------------------------------
    -- LED pulse stretchers
    --------------------------------------------------------------------
    process(clk_125)
    begin
        if rising_edge(clk_125) then
            if reset = '1' then
                mag_led_hold        <= 0;
                uart_start_led_hold <= 0;
                uart_done_led_hold  <= 0;

            else
                -- LED1: FFT/magnitude output exists
                if dbg_mag_valid = '1' then
                    mag_led_hold <= CLK_FREQ / 4;
                elsif mag_led_hold > 0 then
                    mag_led_hold <= mag_led_hold - 1;
                end if;

                -- LED2: UART byte transmission started
                if dbg_uart_start = '1' then
                    uart_start_led_hold <= CLK_FREQ / 4;
                elsif uart_start_led_hold > 0 then
                    uart_start_led_hold <= uart_start_led_hold - 1;
                end if;

                -- LED3: UART packet completed
                if dbg_frame_done = '1' then
                    uart_done_led_hold <= CLK_FREQ / 4;
                elsif uart_done_led_hold > 0 then
                    uart_done_led_hold <= uart_done_led_hold - 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- LEDs
    --------------------------------------------------------------------
    led(0) <= hb_cnt(25);                                           -- heartbeat
    led(1) <= '1' when mag_led_hold > 0 else '0';                   -- FFT/magnitude output
    led(2) <= '1' when uart_start_led_hold > 0 else '0';            -- UART byte started
    led(3) <= '1' when uart_done_led_hold > 0 else '0';             -- UART packet completed

end rtl;
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spectrum_uart_top is
    generic (
        CLK_FREQ    : integer := 125_000_000;
        BAUD_RATE   : integer := 115_200;
        TOTAL_BINS  : integer := 1024;
        SEND_BINS   : integer := 256;
        BIN_STRIDE  : integer := 2;
        FRAME_DECIM : integer := 1;
        SCALE_SHIFT : integer := 4
    );
    port (
        clk              : in  std_logic;
        rst              : in  std_logic;

        -- input frame/sample stream toward FFT
        frame_start      : in  std_logic;
        frame_ready      : out std_logic;
        sample_in        : in  signed(23 downto 0);
        sample_valid     : in  std_logic;
        sample_ready     : out std_logic;

        -- physical UART TX output
        uart_tx_o        : out std_logic;

        -- debug
        debug_mag_valid  : out std_logic;
        debug_uart_start : out std_logic;
        debug_frame_done : out std_logic
    );
end entity;

architecture rtl of spectrum_uart_top is

    --------------------------------------------------------------------
    -- Spectrum core outputs
    --------------------------------------------------------------------
    signal mag_out   : unsigned(24 downto 0);
    signal mag_valid : std_logic;
    signal mag_last  : std_logic;

    --------------------------------------------------------------------
    -- Bin buffer interface
    --------------------------------------------------------------------
    signal buf_frame_available : std_logic;
    signal buf_frame_ack       : std_logic := '0';
    signal buf_rd_index        : unsigned(9 downto 0) := (others => '0');
    signal buf_rd_data         : unsigned(24 downto 0);

    --------------------------------------------------------------------
    -- UART transmitter interface
    --------------------------------------------------------------------
    signal uart_busy  : std_logic;
    signal uart_done  : std_logic;
    signal uart_start : std_logic := '0';
    signal uart_data  : std_logic_vector(7 downto 0) := (others => '0');

    --------------------------------------------------------------------
    -- Packet transmitter state machine
    --------------------------------------------------------------------
    type tx_state_t is (
        TX_WAIT_FRAME,

        TX_SEND_HDR1,
        TX_WAIT_HDR1,

        TX_SEND_HDR2,
        TX_WAIT_HDR2,

        TX_SEND_SEQ,
        TX_WAIT_SEQ,

        TX_SEND_COUNT_HI,
        TX_WAIT_COUNT_HI,

        TX_SEND_COUNT_LO,
        TX_WAIT_COUNT_LO,

        TX_SET_BIN_ADDR,
        TX_WAIT_BIN_DATA,

        TX_SEND_BIN_HI,
        TX_WAIT_BIN_HI,

        TX_SEND_BIN_LO,
        TX_WAIT_BIN_LO,

        TX_SEND_CHECKSUM,
        TX_WAIT_CHECKSUM,

        TX_ACK_FRAME
    );

    signal tx_state : tx_state_t := TX_WAIT_FRAME;

    signal seq_reg      : unsigned(7 downto 0) := (others => '0');
    signal checksum_reg : std_logic_vector(7 downto 0) := (others => '0');

    signal rd_send_idx  : integer range 0 to 255 := 0;
    signal scaled_reg   : std_logic_vector(15 downto 0) := (others => '0');

    signal packet_done_pulse : std_logic := '0';

    --------------------------------------------------------------------
    -- Constants
    --------------------------------------------------------------------
    constant SEND_BINS_U : unsigned(15 downto 0) := to_unsigned(SEND_BINS, 16);

    --------------------------------------------------------------------
    -- Magnitude scaling helper
    --------------------------------------------------------------------
    function scale_mag(x : unsigned(24 downto 0)) return std_logic_vector is
        variable shifted : unsigned(24 downto 0);
        variable result  : unsigned(15 downto 0);
    begin
        shifted := shift_right(x, SCALE_SHIFT);

        if shifted(24 downto 16) /= 0 then
            result := (others => '1');
        else
            result := shifted(15 downto 0);
        end if;

        return std_logic_vector(result);
    end function;

begin

    --------------------------------------------------------------------
    -- FFT + magnitude core
    --------------------------------------------------------------------
    u_core : entity work.spectrum_core
        port map (
            clk          => clk,
            rst          => rst,

            frame_start  => frame_start,
            frame_ready  => frame_ready,

            sample_in    => sample_in,
            sample_valid => sample_valid,
            sample_ready => sample_ready,

            mag_out      => mag_out,
            mag_valid    => mag_valid,
            mag_last     => mag_last
        );

    --------------------------------------------------------------------
    -- Completed-spectrum buffer
    --------------------------------------------------------------------
    u_buffer : entity work.bin_buffer
        port map (
            clk             => clk,
            rst             => rst,

            mag_in          => mag_out,
            mag_valid       => mag_valid,
            mag_last        => mag_last,

            read_addr       => buf_rd_index,
            read_data       => buf_rd_data,

            frame_available => buf_frame_available,
            frame_ack       => buf_frame_ack,

            overflow        => open,
            write_count     => open
        );

    --------------------------------------------------------------------
    -- Byte-level UART transmitter
    --------------------------------------------------------------------
    u_uart_tx : entity work.uart_tx
        generic map (
            CLK_FREQ  => CLK_FREQ,
            BAUD_RATE => BAUD_RATE
        )
        port map (
            clk     => clk,
            rst     => rst,

            start   => uart_start,
            data_in => uart_data,

            tx      => uart_tx_o,
            busy    => uart_busy,
            done    => uart_done
        );

    --------------------------------------------------------------------
    -- Direct packet transmitter
    --------------------------------------------------------------------
    process(clk)
        variable src_idx_v : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tx_state          <= TX_WAIT_FRAME;

                uart_start        <= '0';
                uart_data         <= (others => '0');

                buf_frame_ack     <= '0';
                buf_rd_index      <= (others => '0');

                seq_reg           <= (others => '0');
                checksum_reg      <= (others => '0');

                rd_send_idx       <= 0;
                scaled_reg        <= (others => '0');

                packet_done_pulse <= '0';

            else
                uart_start        <= '0';
                buf_frame_ack     <= '0';
                packet_done_pulse <= '0';

                case tx_state is

                    ----------------------------------------------------
                    -- Wait for a completed FFT magnitude frame.
                    ----------------------------------------------------
                    when TX_WAIT_FRAME =>
                        if buf_frame_available = '1' then
                            checksum_reg <= std_logic_vector(seq_reg) xor
                                            std_logic_vector(SEND_BINS_U(15 downto 8)) xor
                                            std_logic_vector(SEND_BINS_U(7 downto 0));

                            rd_send_idx <= 0;
                            tx_state    <= TX_SEND_HDR1;
                        end if;

                    ----------------------------------------------------
                    -- Header byte 1: 0xAA
                    ----------------------------------------------------
                    when TX_SEND_HDR1 =>
                        if uart_busy = '0' then
                            uart_data  <= x"AA";
                            uart_start <= '1';
                            tx_state   <= TX_WAIT_HDR1;
                        end if;

                    when TX_WAIT_HDR1 =>
                        if uart_done = '1' then
                            tx_state <= TX_SEND_HDR2;
                        end if;

                    ----------------------------------------------------
                    -- Header byte 2: 0x55
                    ----------------------------------------------------
                    when TX_SEND_HDR2 =>
                        if uart_busy = '0' then
                            uart_data  <= x"55";
                            uart_start <= '1';
                            tx_state   <= TX_WAIT_HDR2;
                        end if;

                    when TX_WAIT_HDR2 =>
                        if uart_done = '1' then
                            tx_state <= TX_SEND_SEQ;
                        end if;

                    ----------------------------------------------------
                    -- Sequence byte
                    ----------------------------------------------------
                    when TX_SEND_SEQ =>
                        if uart_busy = '0' then
                            uart_data  <= std_logic_vector(seq_reg);
                            uart_start <= '1';
                            tx_state   <= TX_WAIT_SEQ;
                        end if;

                    when TX_WAIT_SEQ =>
                        if uart_done = '1' then
                            tx_state <= TX_SEND_COUNT_HI;
                        end if;

                    ----------------------------------------------------
                    -- Bin count high byte
                    ----------------------------------------------------
                    when TX_SEND_COUNT_HI =>
                        if uart_busy = '0' then
                            uart_data  <= std_logic_vector(SEND_BINS_U(15 downto 8));
                            uart_start <= '1';
                            tx_state   <= TX_WAIT_COUNT_HI;
                        end if;

                    when TX_WAIT_COUNT_HI =>
                        if uart_done = '1' then
                            tx_state <= TX_SEND_COUNT_LO;
                        end if;

                    ----------------------------------------------------
                    -- Bin count low byte
                    ----------------------------------------------------
                    when TX_SEND_COUNT_LO =>
                        if uart_busy = '0' then
                            uart_data  <= std_logic_vector(SEND_BINS_U(7 downto 0));
                            uart_start <= '1';
                            tx_state   <= TX_WAIT_COUNT_LO;
                        end if;

                    when TX_WAIT_COUNT_LO =>
                        if uart_done = '1' then
                            tx_state <= TX_SET_BIN_ADDR;
                        end if;

                    ----------------------------------------------------
                    -- Set buffer read address for selected bin.
                    -- BIN_STRIDE = 4 means send bins 0,4,8,...,508.
                    ----------------------------------------------------
                    when TX_SET_BIN_ADDR =>
                        src_idx_v := rd_send_idx * BIN_STRIDE;

                        if src_idx_v > TOTAL_BINS - 1 then
                            src_idx_v := TOTAL_BINS - 1;
                        end if;

                        buf_rd_index <= to_unsigned(src_idx_v, buf_rd_index'length);
                        tx_state     <= TX_WAIT_BIN_DATA;

                    ----------------------------------------------------
                    -- Allow read address/data to settle and capture scaled value.
                    ----------------------------------------------------
                    when TX_WAIT_BIN_DATA =>
                        scaled_reg <= scale_mag(buf_rd_data);
                        tx_state   <= TX_SEND_BIN_HI;

                    ----------------------------------------------------
                    -- Send magnitude high byte
                    ----------------------------------------------------
                    when TX_SEND_BIN_HI =>
                        if uart_busy = '0' then
                            uart_data    <= scaled_reg(15 downto 8);
                            uart_start   <= '1';
                            checksum_reg <= checksum_reg xor scaled_reg(15 downto 8);
                            tx_state     <= TX_WAIT_BIN_HI;
                        end if;

                    when TX_WAIT_BIN_HI =>
                        if uart_done = '1' then
                            tx_state <= TX_SEND_BIN_LO;
                        end if;

                    ----------------------------------------------------
                    -- Send magnitude low byte
                    ----------------------------------------------------
                    when TX_SEND_BIN_LO =>
                        if uart_busy = '0' then
                            uart_data    <= scaled_reg(7 downto 0);
                            uart_start   <= '1';
                            checksum_reg <= checksum_reg xor scaled_reg(7 downto 0);
                            tx_state     <= TX_WAIT_BIN_LO;
                        end if;

                    when TX_WAIT_BIN_LO =>
                        if uart_done = '1' then
                            if rd_send_idx = SEND_BINS - 1 then
                                tx_state <= TX_SEND_CHECKSUM;
                            else
                                rd_send_idx <= rd_send_idx + 1;
                                tx_state    <= TX_SET_BIN_ADDR;
                            end if;
                        end if;

                    ----------------------------------------------------
                    -- Send checksum byte
                    ----------------------------------------------------
                    when TX_SEND_CHECKSUM =>
                        if uart_busy = '0' then
                            uart_data  <= checksum_reg;
                            uart_start <= '1';
                            tx_state   <= TX_WAIT_CHECKSUM;
                        end if;

                    when TX_WAIT_CHECKSUM =>
                        if uart_done = '1' then
                            packet_done_pulse <= '1';
                            seq_reg           <= seq_reg + 1;
                            tx_state          <= TX_ACK_FRAME;
                        end if;

                    ----------------------------------------------------
                    -- Release consumed buffer frame
                    ----------------------------------------------------
                    when TX_ACK_FRAME =>
                        buf_frame_ack <= '1';
                        tx_state      <= TX_WAIT_FRAME;

                    when others =>
                        tx_state <= TX_WAIT_FRAME;

                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Debug outputs
    --------------------------------------------------------------------
    debug_mag_valid  <= mag_valid;
    debug_uart_start <= uart_start;
    debug_frame_done <= packet_done_pulse;

end architecture;
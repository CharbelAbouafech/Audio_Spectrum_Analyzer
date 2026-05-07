library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fft_wrapper is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        -- input sample stream
        frame_start   : in  std_logic;
        frame_ready   : out std_logic;
        sample_in     : in  signed(23 downto 0);
        sample_valid  : in  std_logic;
        sample_ready  : out std_logic;

        -- FFT output stream (flows freely regardless of input state)
        fft_re_out    : out signed(23 downto 0);
        fft_im_out    : out signed(23 downto 0);
        fft_out_valid : out std_logic;
        fft_out_last  : out std_logic;

        -- status
        busy          : out std_logic
    );
end entity;

architecture rtl of fft_wrapper is

    component xfft_0
      port (
        aclk                        : in  std_logic;
        s_axis_config_tdata         : in  std_logic_vector(15 downto 0);
        s_axis_config_tvalid        : in  std_logic;
        s_axis_config_tready        : out std_logic;
        s_axis_data_tdata           : in  std_logic_vector(47 downto 0);
        s_axis_data_tvalid          : in  std_logic;
        s_axis_data_tready          : out std_logic;
        s_axis_data_tlast           : in  std_logic;
        m_axis_data_tdata           : out std_logic_vector(47 downto 0);
        m_axis_data_tvalid          : out std_logic;
        m_axis_data_tready          : in  std_logic;
        m_axis_data_tlast           : out std_logic;
        event_frame_started         : out std_logic;
        event_tlast_unexpected      : out std_logic;
        event_tlast_missing         : out std_logic;
        event_status_channel_halt   : out std_logic;
        event_data_in_channel_halt  : out std_logic;
        event_data_out_channel_halt : out std_logic
      );
    end component;

    -- Pipelined Streaming IO: READ_OUT state removed.
    -- Output flows continuously; going back to IDLE after the last
    -- input sample lets the next frame start without waiting for output.
    type state_t is (RESET_ST, SEND_CONFIG, IDLE, STREAM_IN);
    signal state : state_t := RESET_ST;

    signal cfg_tdata  : std_logic_vector(15 downto 0) := (others => '0');
    signal cfg_tvalid : std_logic := '0';
    signal cfg_tready : std_logic;

    signal in_tdata   : std_logic_vector(47 downto 0) := (others => '0');
    signal in_tvalid  : std_logic := '0';
    signal in_tready  : std_logic;
    signal in_tlast   : std_logic := '0';

    signal out_tdata  : std_logic_vector(47 downto 0);
    signal out_tvalid : std_logic;
    signal out_tready : std_logic := '1';
    signal out_tlast  : std_logic;

    signal sample_cnt : integer range 0 to 1023 := 0;

begin

    -- XK_RE in bits[23:0], XK_IM in bits[47:24] per Xilinx FFT IP v9.1 AXI4-Stream format.
    fft_re_out    <= signed(out_tdata(23 downto 0));
    fft_im_out    <= signed(out_tdata(47 downto 24));
    fft_out_valid <= out_tvalid;
    fft_out_last  <= out_tlast;

    frame_ready  <= '1' when state = IDLE else '0';
    sample_ready <= in_tready when state = STREAM_IN else '0';
    busy         <= '1' when state = STREAM_IN else '0';

    uut_fft : xfft_0
      port map (
        aclk                        => clk,
        s_axis_config_tdata         => cfg_tdata,
        s_axis_config_tvalid        => cfg_tvalid,
        s_axis_config_tready        => cfg_tready,
        s_axis_data_tdata           => in_tdata,
        s_axis_data_tvalid          => in_tvalid,
        s_axis_data_tready          => in_tready,
        s_axis_data_tlast           => in_tlast,
        m_axis_data_tdata           => out_tdata,
        m_axis_data_tvalid          => out_tvalid,
        m_axis_data_tready          => out_tready,
        m_axis_data_tlast           => out_tlast,
        event_frame_started         => open,
        event_tlast_unexpected      => open,
        event_tlast_missing         => open,
        event_status_channel_halt   => open,
        event_data_in_channel_halt  => open,
        event_data_out_channel_halt => open
      );

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= RESET_ST;
                cfg_tvalid <= '0';
                in_tvalid  <= '0';
                in_tlast   <= '0';
                sample_cnt <= 0;

            else
                case state is

                    when RESET_ST =>
                        -- bit[0]=1: forward FFT. bits[10:1]=0x2AB: safe per-stage scaling
                        -- prevents 24-bit overflow for full-scale input (Xilinx demo TB "DEFAULT").
                        cfg_tdata  <= x"0557";
                        cfg_tvalid <= '1';
                        in_tvalid  <= '0';
                        in_tlast   <= '0';
                        sample_cnt <= 0;
                        state      <= SEND_CONFIG;

                    when SEND_CONFIG =>
                        if cfg_tvalid = '1' and cfg_tready = '1' then
                            cfg_tvalid <= '0';
                            state      <= IDLE;
                        end if;

                    when IDLE =>
                        in_tvalid  <= '0';
                        in_tlast   <= '0';
                        sample_cnt <= 0;

                        if frame_start = '1' then
                            state <= STREAM_IN;
                        end if;

                    when STREAM_IN =>
                        -- Pipelined IO: accept one sample per clock when in_tready='1'.
                        if in_tvalid = '1' and in_tready = '1' then
                            in_tvalid <= '0';
                            in_tlast  <= '0';

                            if sample_cnt = 1023 then
                                sample_cnt <= 0;
                                state      <= IDLE;
                            else
                                sample_cnt <= sample_cnt + 1;
                            end if;

                        elsif sample_valid = '1' and in_tvalid = '0' then
                            in_tdata(23 downto 0)  <= std_logic_vector(sample_in);
                            in_tdata(47 downto 24) <= (others => '0');
                            in_tvalid <= '1';
                            in_tlast  <= '1' when sample_cnt = 1023 else '0';
                        end if;

                    when others =>
                        state <= RESET_ST;

                end case;
            end if;
        end if;
    end process;

end architecture;

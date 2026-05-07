-- i2c_master.vhd
-- Write-only I2C master for SSM2603 codec register configuration.
-- Sends 3-byte write transactions: {slave_addr+W, data_hi, data_lo}.
-- Open-drain outputs: '0' = drive low, '1' = release (external pullup).
-- All I2C standard-mode timing met at 100 kHz with 125 MHz system clock.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_master is
    generic (
        CLK_FREQ : integer := 125_000_000;
        I2C_FREQ : integer := 100_000
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;
        -- Transaction interface
        start   : in  std_logic;                      -- Pulse to begin write
        addr    : in  std_logic_vector(6 downto 0);   -- 7-bit slave address
        data    : in  std_logic_vector(15 downto 0);  -- Two bytes to write
        busy    : out std_logic;
        done    : out std_logic;                      -- One-cycle pulse on completion
        ack_err : out std_logic;                      -- Sticky: set if any NACK received
        -- I2C bus (active-low open-drain)
        scl_o   : out std_logic;
        sda_o   : out std_logic;
        sda_i   : in  std_logic
    );
end i2c_master;

architecture rtl of i2c_master is

    -- Each half-period of SCL = HALF_PER system clocks.
    -- At 125 MHz / 100 kHz: HALF_PER = 625 -> tLOW = tHIGH = 5.0 us.
    constant HALF_PER : integer := CLK_FREQ / (2 * I2C_FREQ);

    type state_type is (ST_IDLE, ST_START, ST_DATA, ST_ACK, ST_STOP);
    signal state    : state_type := ST_IDLE;

    signal timer    : integer range 0 to HALF_PER - 1 := 0;
    signal step     : integer range 0 to 2 := 0;
    signal scl_ph   : std_logic := '0';  -- '0' = low half, '1' = high half
    signal bit_idx  : integer range 0 to 7 := 7;
    signal byte_idx : integer range 0 to 2 := 0;

    signal tx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal addr_r   : std_logic_vector(6 downto 0) := (others => '0');
    signal data_r   : std_logic_vector(15 downto 0) := (others => '0');

    signal scl_r    : std_logic := '1';
    signal sda_r    : std_logic := '1';
    signal ack_r    : std_logic := '0';
    signal done_r   : std_logic := '0';

begin

    scl_o   <= scl_r;
    sda_o   <= sda_r;
    done    <= done_r;
    ack_err <= ack_r;
    busy    <= '0' when state = ST_IDLE else '1';

    process(clk)
        variable tick : boolean;
    begin
        if rising_edge(clk) then
            done_r <= '0';
            tick   := false;

            if reset = '1' then
                state  <= ST_IDLE;
                scl_r  <= '1';
                sda_r  <= '1';
                timer  <= 0;
                ack_r  <= '0';

            else
                -- Half-period timer (runs outside IDLE)
                if state /= ST_IDLE then
                    if timer = HALF_PER - 1 then
                        timer <= 0;
                        tick  := true;
                    else
                        timer <= timer + 1;
                    end if;
                end if;

                case state is
                    -- =========================================================
                    when ST_IDLE =>
                        scl_r <= '1';
                        sda_r <= '1';
                        timer <= 0;
                        if start = '1' then
                            addr_r <= addr;
                            data_r <= data;
                            ack_r  <= '0';
                            state  <= ST_START;
                            step   <= 0;
                        end if;

                    -- =========================================================
                    -- START condition: SDA falls while SCL is high.
                    -- Step 0: bus idle hold  (SDA=1, SCL=1)
                    -- Step 1: START          (SDA=0, SCL=1)  tHD;STA = HALF_PER
                    -- Step 2: prepare data   (SCL=0)
                    when ST_START =>
                        if tick then
                            case step is
                                when 0 =>
                                    sda_r <= '1';
                                    scl_r <= '1';
                                    step  <= 1;
                                when 1 =>
                                    sda_r <= '0';  -- START
                                    step  <= 2;
                                when 2 =>
                                    scl_r    <= '0';
                                    tx_byte  <= addr_r & '0';  -- address + write bit
                                    byte_idx <= 0;
                                    bit_idx  <= 7;
                                    scl_ph   <= '0';
                                    state    <= ST_DATA;
                                when others =>
                                    null;
                            end case;
                        end if;

                    -- =========================================================
                    -- Clock out 8 bits MSB-first.
                    -- scl_ph 0: SCL low  - drive SDA to current bit
                    -- scl_ph 1: SCL high - slave samples
                    when ST_DATA =>
                        if tick then
                            if scl_ph = '0' then
                                scl_r  <= '0';
                                sda_r  <= tx_byte(bit_idx);
                                scl_ph <= '1';
                            else
                                scl_r  <= '1';
                                scl_ph <= '0';
                                if bit_idx = 0 then
                                    state  <= ST_ACK;
                                    scl_ph <= '0';
                                else
                                    bit_idx <= bit_idx - 1;
                                end if;
                            end if;
                        end if;

                    -- =========================================================
                    -- Read ACK from slave (SDA should be pulled low by slave).
                    when ST_ACK =>
                        if tick then
                            if scl_ph = '0' then
                                scl_r  <= '0';
                                sda_r  <= '1';  -- release SDA
                                scl_ph <= '1';
                            else
                                scl_r <= '1';
                                if sda_i = '1' then
                                    ack_r <= '1';  -- NACK
                                end if;
                                scl_ph <= '0';

                                if byte_idx = 2 then
                                    -- All 3 bytes sent
                                    state <= ST_STOP;
                                    step  <= 0;
                                else
                                    -- Load next byte
                                    if byte_idx = 0 then
                                        tx_byte <= data_r(15 downto 8);
                                    else
                                        tx_byte <= data_r(7 downto 0);
                                    end if;
                                    byte_idx <= byte_idx + 1;
                                    bit_idx  <= 7;
                                    state    <= ST_DATA;
                                end if;
                            end if;
                        end if;

                    -- =========================================================
                    -- STOP condition: SDA rises while SCL is high.
                    -- Step 0: SDA=0, SCL=0   (setup)
                    -- Step 1: SDA=0, SCL=1   (tSU;STO = HALF_PER)
                    -- Step 2: SDA=1, SCL=1   (STOP)
                    when ST_STOP =>
                        if tick then
                            case step is
                                when 0 =>
                                    scl_r <= '0';
                                    sda_r <= '0';
                                    step  <= 1;
                                when 1 =>
                                    scl_r <= '1';
                                    step  <= 2;
                                when 2 =>
                                    sda_r  <= '1';  -- STOP
                                    done_r <= '1';
                                    state  <= ST_IDLE;
                                when others =>
                                    null;
                            end case;
                        end if;

                end case;
            end if;
        end if;
    end process;

end rtl;
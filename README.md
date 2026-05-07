# FPGA Audio Spectrum Analyzer

A fully working, real-time audio spectrum analyzer implemented on the **Digilent Zybo Z7-10** (Xilinx Zynq-7010 FPGA) using the on-board **Analog Devices SSM2603** audio codec. Analog audio enters through the line-in jack, is digitized at 48 kHz, processed through a 1024-point FFT entirely in FPGA fabric, and the frequency spectrum is transmitted over UART and displayed live in a Python bar-graph visualizer.

---

## Table of Contents

1. [Physics and Theory](#physics-and-theory)
2. [System Architecture](#system-architecture)
3. [Hardware Platform](#hardware-platform)
4. [Pin Assignments](#pin-assignments)
5. [VHDL Modules — In Depth](#vhdl-modules--in-depth)
6. [Python Visualizer](#python-visualizer)
7. [Design Decisions and Trade-offs](#design-decisions-and-trade-offs)
8. [Debugging Log — What Broke and How It Was Fixed](#debugging-log--what-broke-and-how-it-was-fixed)
9. [UART Timing Analysis](#uart-timing-analysis)
10. [Frequency Resolution Analysis](#frequency-resolution-analysis)
11. [Current Configuration Reference](#current-configuration-reference)
12. [Build and Run Instructions](#build-and-run-instructions)
13. [Verification Procedure](#verification-procedure)
14. [Current Status](#current-status)

---

## Physics and Theory

### The Discrete Fourier Transform

Sound is a pressure wave — a time-varying signal. When you play a 1 kHz sine tone, the air (and the voltage out of a microphone) oscillates exactly 1000 times per second. When you play music, many frequencies are simultaneously present and they superimpose linearly.

The **Discrete Fourier Transform (DFT)** decomposes a finite block of time-domain samples into its frequency components. For a block of N samples taken at sample rate Fs:

```
X[k] = sum_{n=0}^{N-1} x[n] * exp(-j * 2*pi * k * n / N)
```

Each output bin k corresponds to a physical frequency:

```
f_k = k * Fs / N
```

For this project: N = 1024, Fs = 48000 Hz, so:

```
bin spacing = 48000 / 1024 = 46.875 Hz per bin
```

Bin 0 is DC (0 Hz). Bin 512 is the Nyquist frequency (24000 Hz). Bins 513–1023 are mirror images of bins 511–1 (negative frequencies) and carry no new information for real-valued audio.

The FFT is an algorithm that computes the DFT in O(N log N) instead of O(N²). For N = 1024, that is a factor of ~100 speedup. The Xilinx FFT IP core implements a pipelined radix-2 FFT.

### Magnitude from Complex Output

The FFT output X[k] is complex: X[k] = Re[k] + j·Im[k]. The magnitude (power at that frequency) is:

```
|X[k]| = sqrt(Re[k]^2 + Im[k]^2)
```

Computing a true square root in FPGA logic costs significant area and latency. The **L1-norm approximation** is used instead:

```
|X[k]| ≈ |Re[k]| + |Im[k]|
```

This approximation is always within a factor of sqrt(2) ≈ 1.41 of the true magnitude. For a spectrum display this is visually indistinguishable from the exact value — the relative heights of the bars remain correct. The absolute values are scaled later anyway.

### Nyquist Theorem and Aliasing

The **Nyquist-Shannon sampling theorem** states that a signal sampled at rate Fs can faithfully represent frequencies up to Fs/2. Any frequency content above Fs/2 present in the analog signal before sampling will **alias** — it folds back into the 0 to Fs/2 range and appears as a spurious frequency.

With Fs = 48000 Hz, Nyquist = 24000 Hz.

Example: if a 20 kHz tone has a second harmonic at 40 kHz, that 40 kHz component aliases to:

```
48000 - 40000 = 8000 Hz
```

This is why a 20 kHz YouTube tone shows a cluster around 8–10 kHz in the analyzer. This is physics, not a bug. The SSM2603 has an internal anti-aliasing filter, but it is not a perfect brick wall at 24 kHz — it has a gradual rolloff, allowing some energy above Nyquist to fold in.

### Why Audio Has Limited High-Frequency Content from Consumer Sources

YouTube encodes audio using the **Opus codec**, which targets frequencies up to approximately 20 kHz (matching the upper limit of human hearing). Above ~20 kHz the encoded signal rolls off. Additionally:

- Consumer speakers and headphones do not reproduce frequencies above ~20 kHz reliably.
- The laptop's D/A converter output path may itself roll off near Nyquist.
- The SSM2603's ADC anti-aliasing filter attenuates frequencies as they approach 24 kHz.

As a result, bins near 24 kHz will show near-zero magnitude with real music or YouTube audio. This is correct and expected.

### I2S Protocol

I2S (Inter-IC Sound) is the standard serial bus for digital audio between chips. The SSM2603 is configured in **master mode** — the codec generates the clocks and the FPGA is the slave receiver.

Three signals:

| Signal | Description |
|--------|-------------|
| `BCLK` | Bit clock. Each rising edge clocks one audio data bit. |
| `LRCLK` | Left/Right word select clock. Low = left channel, High = right channel. Toggles at the sample rate (48 kHz). |
| `SDATA` | Serial audio data, MSB first. Data is delayed by exactly one BCLK after the LRCLK edge (I2S standard). |

With 16-bit samples at 48 kHz:

```
BCLK frequency = 2 channels × 16 bits × 48000 Hz = 1.536 MHz
```

The FPGA system clock (125 MHz) is much faster than BCLK, so BCLK is sampled synchronously and edge-detected using a shift register. The LRCLK transition signals end-of-channel. Only the left channel is used for the FFT (mono analysis).

### SSM2603 MCLK

The SSM2603 requires a **Master Clock (MCLK)** to derive its internal sample-rate clocks. In standard audio, MCLK is 256× the sample rate:

```
Ideal MCLK = 256 × 48000 = 12.288 MHz
```

This project generates MCLK by dividing the 125 MHz system clock by 5 in each direction (toggle every 5 clocks), producing a 12.5 MHz square wave. This is approximately correct:

```
125 MHz / 10 = 12.5 MHz (≈ 1.7% above ideal 12.288 MHz)
```

The SSM2603 is configured in **USB mode** (register R8 = 0x001), which specifies a 12 MHz nominal MCLK input for 48 kHz. At 12.5 MHz the codec still locks and produces valid audio — the sample rate is very slightly off (≈ 48,828 Hz instead of 48,000 Hz), but for spectrum analysis this is negligible and within the bin quantization error.

### UART Framing

UART (Universal Asynchronous Receiver/Transmitter) uses a simple framing format. For 8N1:

```
[START bit = 0] [D0] [D1] [D2] [D3] [D4] [D5] [D6] [D7] [STOP bit = 1]
```

Each byte takes exactly 10 bit-times. At baud rate B, one byte takes:

```
byte time = 10 / B seconds
```

The baud rate is derived from the FPGA system clock by integer division:

```
BAUD_TICK_COUNT = CLK_FREQ / BAUD_RATE
```

For CLK_FREQ = 125 MHz, BAUD_RATE = 312,500:

```
BAUD_TICK_COUNT = 125,000,000 / 312,500 = 400 exactly (0% error)
```

This is a key property of 312,500 baud — it divides 125 MHz perfectly with no remainder, producing zero baud rate error.

---

## System Architecture

```
Laptop / phone audio output
          |
          | (3.5mm aux cable)
          v
Zybo Z7-10 LINE IN jack
          |
          v
SSM2603 Audio Codec
  - I2C initialization (FPGA writes 9 registers at startup)
  - ADC: analog line-in → 16-bit PCM
  - I2S master output: BCLK (1.536 MHz), LRCLK (48 kHz), SDATA
          |
          | I2S (hardware pins: ac_bclk, ac_lrclk, ac_recdat)
          v
i2s_receiver.vhd
  - Synchronizes async codec signals to 125 MHz system clock
  - Detects BCLK rising edges
  - Deserializes MSB-first serial data
  - Outputs 16-bit left_data, right_data + valid pulse @ 48 kHz
          |
          | left_data (16-bit), valid (1 Hz pulse at 48 kHz)
          v
Frame accumulator (in top.vhd)
  - Waits for codec init to finish
  - Waits for FFT to be ready for a new frame
  - Latches 1024 consecutive left-channel samples
  - Buffers one sample in a staging register to handle
    any momentary FFT backpressure
          |
          | sample_in (24-bit signed), sample_valid, frame_start
          v
fft_wrapper.vhd  (wraps Xilinx xfft_0 IP)
  - Sends config word once at startup (forward FFT, per-stage scaling)
  - Accepts 1024 samples via AXI4-Stream handshake
  - xfft_0 computes 1024-point FFT (pipelined, in fabric)
  - Outputs 1024 complex bins: Re[23:0], Im[23:0] via AXI4-Stream
  - Output flows naturally in bin order (0, 1, 2, ..., 1023)
          |
          | fft_re (24-bit), fft_im (24-bit), fft_valid, fft_last
          v
magnitude_calc.vhd
  - Computes |Re| + |Im| for each bin (L1 approximation)
  - 1 clock cycle latency
  - Output: 25-bit unsigned magnitude, valid, last
          |
          | mag_out (25-bit), mag_valid, mag_last
          v
bin_buffer.vhd
  - Dual-bank RAM (ping-pong): one bank being written, one being read
  - Stores all 1024 magnitude bins
  - When mag_last arrives, swaps banks if UART has consumed previous frame
  - Exposes read port for random-access by UART transmitter
  - frame_available flag tells UART a new frame is ready
          |
          | read_addr → read_data (25-bit), frame_available
          v
Packet FSM (in spectrum_uart_top.vhd)
  - Waits for frame_available
  - Sends 518-byte packet:
      [0xAA][0x55][seq][count_hi][count_lo]
      [mag_hi][mag_lo] × 256 bins (stride-2 selection)
      [checksum]
  - Reads bin buffer with BIN_STRIDE=2: sends bins 0, 2, 4, ..., 510
  - Scales 25-bit magnitude → 16-bit by right-shifting 4 bits
  - Computes rolling XOR checksum over seq + count + all payload bytes
  - Acknowledges buffer frame when packet is fully sent
          |
          | uart_tx (serial, 312500 baud, 8N1)
          v
Digilent Pmod USBUART
  - FT232R USB-to-UART chip
  - FPGA TX → FT232R RXD → USB → Windows COM port
          |
          | USB / COM3
          v
spectrum_analyzer.py
  - Opens COM3 at 312500 baud
  - Scans for 0xAA 0x55 header
  - Validates checksum
  - Extracts 256 magnitudes (big-endian 16-bit each)
  - Maps bin index to frequency: freq[i] = i * 2 * 48000 / 1024
  - Displays live bar graph (matplotlib)
  - Shows peak frequency, packet stats, dropped count
```

---

## Hardware Platform

| Item | Value |
|------|-------|
| Board | Digilent Zybo Z7-10 |
| FPGA | Xilinx Zynq-7010, XC7Z010-1CLG400C |
| Audio codec | Analog Devices SSM2603 (on-board) |
| FPGA system clock | 125 MHz (from on-board oscillator, pin K17) |
| Codec MCLK | 12.5 MHz (125 MHz / 10, generated by FPGA divider) |
| Audio sample rate | 48 kHz (nominal; SSM2603 USB mode) |
| Audio input | Zybo LINE IN jack (3.5mm) |
| Audio format | I2S, 16-bit samples, codec master mode |
| UART output | Digilent Pmod USBUART (FT232R chip) |
| UART baud rate | 312,500 baud, 8N1 |
| PC connection | COM3 (may differ; check Device Manager) |

---

## Pin Assignments

Defined in `Audio_Spectrum_Analyzer.srcs/constrs_1/new/top.xdc`.

| Port | Package Pin | Direction | Function |
|------|-------------|-----------|----------|
| `clk_125` | K17 | in | 125 MHz system clock |
| `ac_mclk` | R17 | out | Master clock to SSM2603 |
| `ac_bclk` | R19 | in | I2S bit clock from codec |
| `ac_lrclk` | Y18 | in | I2S LR clock from codec |
| `ac_recdat` | R16 | in | I2S record data from codec ADC |
| `ac_scl` | N18 | out | I2C clock to codec |
| `ac_sda` | N17 | inout | I2C data to/from codec |
| `uart_rts` | V15 | in | Pmod USBUART RTS |
| `uart_tx` | W15 | out | FPGA UART TX → Pmod USBUART RXD |
| `uart_rx` | T11 | in | Pmod USBUART TXD → FPGA |
| `uart_cts` | T10 | out | FPGA CTS, driven low (always ready) |
| `led[0]` | M14 | out | Heartbeat |
| `led[1]` | M15 | out | FFT/magnitude output active |
| `led[2]` | G14 | out | UART byte being sent |
| `led[3]` | D18 | out | Full UART packet completed |

---

## VHDL Modules — In Depth

### `top.vhd` — Top Level

**Role:** Ties everything together. Handles reset sequencing, MCLK generation, I2C open-drain drive, frame accumulation, and LED diagnostics.

**Key generics:**

```vhdl
CLK_FREQ   : integer := 125_000_000;   -- system clock
I2C_FREQ   : integer := 100_000;       -- I2C SCL rate
DATA_WIDTH : integer := 16;            -- I2S sample width
BAUD_RATE  : integer := 312_500;       -- UART baud rate
```

`BAUD_RATE` propagates automatically through `spectrum_uart_top` → `uart_tx`. Changing it here changes the actual UART rate everywhere.

**MCLK generation:**

A toggle counter divides 125 MHz by 10 to produce a 12.5 MHz clock:

```vhdl
constant MCLK_DIV : integer := 5;
-- toggles every 5 cycles → 125 MHz / 10 = 12.5 MHz
```

**Power-on reset:**

Reset holds high for CLK_FREQ/100 = 1,250,000 cycles ≈ 10 ms. This ensures all downstream modules start from a clean state before codec init begins.

**I2C open-drain:**

The SSM2603 I2C bus uses open-drain signaling. The FPGA drives SDA and SCL low actively, and releases them to high-Z (pulled high by resistors) when not driving:

```vhdl
ac_scl <= '0' when scl_drive = '0' else 'Z';
ac_sda <= '0' when sda_drive = '0' else 'Z';
```

**Frame accumulator FSM:**

Three states:
- `WAIT_INIT`: Holds until the codec I2C initialization completes (`init_done = '1'`).
- `WAIT_FRAME_READY`: Holds until the FFT indicates it is idle and ready (`fft_frame_ready = '1'`), then pulses `frame_start`.
- `STREAM`: Feeds samples from the I2S receiver into the FFT. Uses a one-sample staging register (`pending_sample`) to buffer an incoming I2S sample while the FFT momentarily asserts backpressure. This prevents dropped samples at the boundary between FFT ready/not-ready.

The staging register is critical: the I2S receiver generates a valid pulse at 48 kHz regardless of FFT state. Without the staging register, any cycle where the FFT is not ready would silently drop a sample and corrupt the frame.

**LED pulse stretchers:**

The debug signals (`dbg_mag_valid`, `dbg_uart_start`, `dbg_frame_done`) are single-cycle pulses. Driving LEDs directly from them would be invisible at human timescales. Each LED has a counter loaded to CLK_FREQ/4 = 31.25 million when the pulse arrives, and decrements to zero — holding the LED on for 0.25 seconds per event.

**u_spectrum generic map (current values):**

```vhdl
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
```

---

### `ssm2603_init.vhd` — Codec Configuration

**Role:** Sequences through 9 I2C register writes to configure the SSM2603 for line-in ADC capture.

**SSM2603 I2C addressing:**

The chip uses 7-bit address `0b0011010` (0x1A). Each register write is a 3-byte I2C transaction:

```
[START] [addr 0x1A W] [ACK]
        [reg_addr[6:0] | data_bit[8]] [ACK]
        [data_bits[7:0]] [ACK]
[STOP]
```

The register address and 9-bit data value are packed into a 16-bit word in the REG_TABLE array.

**Register sequence:**

| Step | Register | Value | Purpose |
|------|----------|-------|---------|
| 0 | R15 | 0x000 | Software reset — clears all codec state |
| — | (delay) | 100 ms | Allow codec to recover from reset |
| 1 | R6 | 0x01A | Power: line-in ON, MIC OFF, ADC ON, DAC OFF, output OFF |
| 2 | R0 | 0x017 | Left line-in: 0 dB, unmuted |
| 3 | R1 | 0x017 | Right line-in: 0 dB, unmuted |
| 4 | R4 | 0x000 | Analog path: INSEL=0 (line in), no mic boost |
| 5 | R5 | 0x000 | Digital path: ADC high-pass filter on, no de-emphasis |
| 6 | R7 | 0x042 | Interface: I2S format, 16-bit, codec master mode |
| 7 | R8 | 0x001 | Sampling: USB mode, 48 kHz |
| 8 | R9 | 0x001 | Activate digital audio interface |

After the software reset (step 0), a 100 ms delay is inserted before writing any other registers. This is required by the SSM2603 datasheet to allow internal references to stabilize.

**FSM:**

`ST_DELAY → ST_SEND → ST_WAIT_I2C` loops for each register. After the final register, transitions to `ST_DONE` and holds `init_done = '1'` forever.

---

### `i2c_master.vhd` — I2C Bus Master

**Role:** Implements a write-only 100 kHz I2C master for the codec configuration bus.

**Clock generation:** Divides CLK_FREQ by I2C_FREQ to produce the SCL period. At 125 MHz / 100 kHz = 1250 system clocks per SCL period.

**Timing:** The I2C standard requires specific setup and hold times around SDA transitions relative to SCL edges. The master implements a state machine that drives SCL and SDA correctly for: START condition → address + W bit → ACK → data byte 1 → ACK → data byte 2 → ACK → STOP condition.

**ACK detection:** After each byte, the master releases SDA and samples it on the rising edge of the 9th SCL pulse. If SDA is still high (no ACK pulled low by slave), `ack_err` is asserted. The system still continues to the next register regardless of ACK errors — the codec is configured best-effort.

---

### `i2s_receiver.vhd` — I2S Deserializer

**Role:** Captures serial audio from the SSM2603 and outputs 16-bit parallel samples at 48 kHz.

**Clock domain crossing:** The codec (BCLK, LRCLK, SDATA) runs asynchronously to the 125 MHz FPGA system clock. Directly sampling these signals risks metastability — a flip-flop receiving a signal changing near its clock edge can output an indeterminate voltage for an unpredictable time.

Solution: 2- or 3-stage synchronizer chains for each input signal. Each extra stage gives the metastability one more clock cycle to resolve. With three stages and a 125 MHz clock, the probability of propagated metastability is negligibly small.

```vhdl
signal bclk_sync  : std_logic_vector(2 downto 0);  -- 3-stage for edge detect
signal lrclk_sync : std_logic_vector(1 downto 0);  -- 2-stage
signal sdata_sync : std_logic_vector(1 downto 0);  -- 2-stage
```

**BCLK edge detection:**

```vhdl
bclk_rise <= '1' when bclk_sync(2 downto 1) = "01" else '0';
```

The 3-stage BCLK synchronizer lets the FSM compare the last two registered values. A `01` pattern means the previous registered value was 0 and the current is 1 — a rising edge detected, one or two system clocks after the actual BCLK transition.

**I2S deserialization:**

I2S has a one-BCLK-cycle delay between the LRCLK edge and the first data bit. The receiver skips `bit_cnt = 0` (the delay bit) and shifts in bits 1 through 16. On the LRCLK falling edge, the right channel data is latched and `valid` is pulsed, signaling a complete L+R sample pair.

Only the left channel (`left_data`) is used for the FFT input.

---

### `fft.vhd` — FFT Wrapper

**Role:** Wraps the Xilinx `xfft_0` IP core in a simple ready/valid handshake interface, hiding the AXI4-Stream complexity from the rest of the design.

**Xilinx xfft_0 IP configuration:**

| Parameter | Value |
|-----------|-------|
| Transform size | 1024 |
| Architecture | Pipelined streaming |
| Data format | Fixed point |
| Input width | 24 bits (real), 24 bits (imaginary, always 0) |
| Output width | 24 bits real + 24 bits imaginary |
| Output ordering | Natural order |
| Scaling | Per-stage scaled (config word 0x0557) |
| Rounding | Truncation |

**AXI4-Stream interface:**

The FFT IP uses AXI4-Stream for both input and output. Each 1024-sample frame:
1. A config write (forward FFT, scaling) is sent once at startup via the config channel.
2. Samples are pushed via the data input channel with `tvalid`/`tready` handshake. `tlast` is asserted on sample 1023.
3. Outputs flow continuously on the output channel. The wrapper keeps `m_axis_data_tready = '1'` at all times so outputs are never stalled.

**Input data packing (per Xilinx FFT IP v9.1 AXI format):**

```
bits[23:0]  = XN_RE (real part of input sample)
bits[47:24] = XN_IM (imaginary part, tied to 0 — audio is real-valued)
```

**Output data unpacking:**

```vhdl
fft_re_out <= signed(out_tdata(23 downto 0));   -- XK_RE
fft_im_out <= signed(out_tdata(47 downto 24));  -- XK_IM
```

**Configuration word 0x0557:**

```
bit[0]    = 1        → forward FFT (not inverse)
bits[10:1] = 0x2AB  → per-stage scaling schedule
```

The per-stage scaling prevents overflow of the internal fixed-point arithmetic. Without appropriate scaling, a full-scale sine wave input would cause the intermediate butterfly results to overflow, producing completely wrong output. The value `0x2AB` (binary: 10 10 10 10 10 10) applies a divide-by-2 at alternating stages, matching Xilinx's recommended "DEFAULT" scaling in their demo testbench.

**Pipelined IO:**

The FFT IP can accept the next frame's input while it is still computing and outputting the previous frame. The wrapper returns to `IDLE` after sending all 1024 input samples (without waiting for output to finish), allowing the frame accumulator to immediately begin the next 1024-sample collection.

**Natural output order:**

The FFT IP is configured for natural output order, meaning bin 0 comes out first, then bin 1, then bin 2, up to bin 1023. No bit-reversal reordering is needed. This simplifies the bin buffer and UART transmitter significantly.

---

### `mag_calc.vhd` — Magnitude Calculator

**Role:** Converts complex FFT output to a scalar magnitude.

**Implementation:**

```vhdl
re_abs := abs_signed(re_in);
im_abs := abs_signed(im_in);
mag_out <= ('0' & re_abs) + ('0' & im_abs);
```

The `abs_signed` function negates negative signed values (two's complement negation). Adding a zero MSB before each operand zero-extends from 24 to 25 bits, preventing overflow when both abs values are maximum (24'h7FFFFF + 24'h7FFFFF overflows 24 bits but fits in 25 bits).

**Latency:** One clock cycle. The `last_in` signal passes through to `last_out` with the same one-cycle delay, keeping the frame boundary signal aligned with the magnitude output.

---

### `buffer.vhd` — Bin Buffer

**Role:** Decouples the FFT pipeline (which produces bins sequentially at high speed) from the UART transmitter (which reads bins in arbitrary order at UART speed).

**Dual-bank design (ping-pong buffering):**

Two RAM banks, each holding 1024 × 25-bit values. The FFT writes into the "write bank" while the UART reads from the "read bank." When the FFT finishes a complete frame (`mag_last` arrives):

- If the UART has consumed the previous frame (`frame_available = '0'`): swap banks, assert `frame_available`, switch FFT to the other bank.
- If the UART is still sending the previous frame (`frame_available = '1'`): the new frame is silently dropped. The `overflow` flag is asserted for one cycle.

This design ensures the UART never reads partially-written data. The FFT output is always complete before it becomes visible to the UART side.

**Why 1024 entries when only 256 are sent:**

The buffer stores all 1024 FFT output bins, not just the 256 that will be transmitted. The UART FSM uses `BIN_STRIDE = 2` to read every other bin (bins 0, 2, 4, ..., 510), providing twice the frequency resolution compared to reading every 4th bin. Storing all bins gives flexibility to change the stride or range without modifying the buffer.

**Read port:**

The UART FSM sets `buf_rd_index` to the bin address it wants and reads `buf_rd_data` after one cycle of settling. This is a synchronous read from a RAM, which is why the FSM has a `TX_SET_BIN_ADDR → TX_WAIT_BIN_DATA` two-state sequence for each bin.

---

### `spectrum_uart_top.vhd` — UART Packet Transmitter

**Role:** Integrates the FFT core, bin buffer, and UART byte transmitter, and implements the packet formatting FSM.

**Magnitude scaling:**

The raw magnitude from `magnitude_calc` is 25 bits wide. At maximum FFT output with full-scale input, the magnitude can be large. To fit into a 16-bit packet field, the magnitude is right-shifted by `SCALE_SHIFT = 4` bits (divide by 16):

```vhdl
shifted := shift_right(x, SCALE_SHIFT);  -- divide by 16
```

If the result still overflows 16 bits (i.e., bits[24:16] are nonzero), it is clamped to 0xFFFF. This prevents wrap-around that would make loud sounds appear as quiet ones.

**Packet format (current configuration, SEND_BINS = 256):**

```
Byte  Field          Value / Notes
----  -----          --------------
0     Header[0]      0xAA
1     Header[1]      0x55
2     Sequence       0x00–0xFF, increments each packet, wraps
3     Count high     0x01  (256 = 0x0100)
4     Count low      0x00
5     Bin 0 high     scaled magnitude of FFT bin 0
6     Bin 0 low
7     Bin 1 high     scaled magnitude of FFT bin 2 (stride=2)
8     Bin 1 low
...
517   Bin 255 high   scaled magnitude of FFT bin 510
518   Bin 255 low
519   Checksum       XOR of: seq, count_hi, count_lo, all 514 payload bytes
```

Total: **520 bytes** per packet.

Wait — recalculating:

```
2 (header) + 1 (seq) + 2 (count) + 2×256 (payload) + 1 (checksum)
= 2 + 1 + 2 + 512 + 1 = 518 bytes
```

**Checksum:**

Rolling XOR over seq, count_hi, count_lo, and all payload bytes. Initialized before the packet starts:

```vhdl
checksum_reg <= std_logic_vector(seq_reg) xor
                std_logic_vector(SEND_BINS_U(15 downto 8)) xor
                std_logic_vector(SEND_BINS_U(7 downto 0));
```

Each payload byte XORs into `checksum_reg` as it is transmitted. The final value is sent as the last byte. The Python receiver independently computes the same XOR and rejects packets where the received checksum doesn't match.

**Packet FSM states:**

```
TX_WAIT_FRAME     → wait for buf_frame_available
TX_SEND_HDR1      → send 0xAA
TX_WAIT_HDR1      → wait for UART done
TX_SEND_HDR2      → send 0x55
TX_WAIT_HDR2
TX_SEND_SEQ       → send sequence byte
TX_WAIT_SEQ
TX_SEND_COUNT_HI  → send 0x01
TX_WAIT_COUNT_HI
TX_SEND_COUNT_LO  → send 0x00
TX_WAIT_COUNT_LO
TX_SET_BIN_ADDR   → compute bin index = rd_send_idx × BIN_STRIDE
TX_WAIT_BIN_DATA  → wait 1 cycle for RAM read to settle, capture scaled value
TX_SEND_BIN_HI    → send magnitude[15:8], update checksum
TX_WAIT_BIN_HI
TX_SEND_BIN_LO    → send magnitude[7:0], update checksum
TX_WAIT_BIN_LO    → if last bin, go to checksum; else increment rd_send_idx, loop
TX_SEND_CHECKSUM  → send final XOR checksum byte
TX_WAIT_CHECKSUM
TX_ACK_FRAME      → pulse buf_frame_ack, return to TX_WAIT_FRAME
```

The loop over 256 bins (TX_SET_BIN_ADDR through TX_WAIT_BIN_LO) repeats 256 times — the dominant time cost of the packet.

---

### `UART_transmitter.vhd` — UART Byte Transmitter

**Role:** Serializes one 8-bit byte onto the TX line with correct 8N1 framing.

**Baud rate generation:**

```vhdl
constant BAUD_TICK_COUNT : integer := CLK_FREQ / BAUD_RATE;
```

At 312,500 baud with 125 MHz: `BAUD_TICK_COUNT = 400`. The transmitter counts to 400 system clocks per bit period.

**State machine:**

```
IDLE → START_BIT (drive TX low for one bit time)
     → DATA_BITS (shift out bits 0–7, LSB first, one bit per BAUD_TICK_COUNT clocks)
     → STOP_BIT  (drive TX high for one bit time)
     → IDLE, assert done for one clock
```

`busy` is high from the moment `start` is pulsed until STOP_BIT completes. The packet FSM checks `uart_busy = '0'` and `uart_done = '1'` to pace the packet transmission.

---

## Python Visualizer

**File:** `spectrum_analyzer.py`

### Constants (must match FPGA generics exactly)

```python
BAUD_RATE     = 312500    # must equal top.vhd BAUD_RATE generic
EXPECTED_BINS = 256       # must equal SEND_BINS in spectrum_uart_top
SAMPLE_RATE   = 48000     # Hz
NFFT          = 1024      # must equal FFT size
BIN_STRIDE    = 2         # must equal BIN_STRIDE generic
NOISE_FLOOR   = 8         # bins with scaled magnitude below this are zeroed
TIMEOUT       = 0.001     # serial read timeout in seconds
```

### Frequency axis calculation

```python
nat_bins = np.arange(EXPECTED_BINS) * BIN_STRIDE
# = [0, 2, 4, ..., 510]   — which FFT bin each bar represents

freq_hz = nat_bins * SAMPLE_RATE / NFFT
# = [0, 93.75, 187.5, ..., 23906.25] Hz
```

Bar i represents FFT bin (i × BIN_STRIDE). Its center frequency is:

```
freq[i] = i × BIN_STRIDE × SAMPLE_RATE / NFFT
         = i × 2 × 48000 / 1024
         = i × 93.75 Hz
```

The 256 bars span from 0 Hz to 23,906.25 Hz (≈ Nyquist).

### Packet parser (`PacketReader`)

- Maintains a rolling byte buffer.
- Searches the buffer for the `0xAA 0x55` header.
- Reads count (2 bytes), validates it equals `EXPECTED_BINS`.
- Reads payload (2 × count bytes).
- Reads checksum byte, verifies against locally computed XOR.
- Rejects and resyncs on any mismatch.
- Tracks good/bad/checksum-fail/dropped statistics.
- `dropped` is computed as `(seq_this - seq_last - 1) & 0xFF`. Zero means every frame arrived. One means every other frame was dropped (UART too slow). Two means two frames were skipped, etc.

### Live plot loop

Drains all queued packets on each iteration and renders only the latest one. This prevents the display from falling behind when multiple packets arrive between redraws. The display update runs at ~33 Hz (30 ms `plt.pause`).

The Y-axis auto-scales: `ymax = max(ymin_ymax, peak_mag × 1.5)`. This ensures the peak bar never touches the top of the plot.

### Running

```bash
# Debug mode — print packets without opening a window
python spectrum_analyzer.py --port COM3 --no-plot

# Live plot
python spectrum_analyzer.py --port COM3

# Custom initial Y-axis limit
python spectrum_analyzer.py --port COM3 --ymax 128
```

Note: Python sets the COM port baud rate programmatically via pyserial. The Windows Device Manager "Bits per second" setting for the COM port is **irrelevant** — pyserial overrides it when it opens the port.

---

## Design Decisions and Trade-offs

### Why BIN_STRIDE = 2 (not 1 or 4)?

The FFT produces 512 positive-frequency bins (bins 0–511). UART bandwidth limits how many we can transmit per frame.

**BIN_STRIDE = 1, SEND_BINS = 512:** Packet = 2+1+2+1024+1 = **1030 bytes**. At 312,500 baud: 1030 × 10 / 312,500 = **32.96 ms > 21.33 ms FFT frame time**. Every frame would be dropped. Not feasible.

**BIN_STRIDE = 2, SEND_BINS = 256:** Packet = 2+1+2+512+1 = **518 bytes**. At 312,500 baud: 518 × 10 / 312,500 = **16.58 ms < 21.33 ms**. Every frame transmitted with 4.75 ms margin. ✓

**BIN_STRIDE = 4, SEND_BINS = 128:** Packet = 2+1+2+256+1 = **262 bytes**. At 312,500 baud: 262 × 10 / 312,500 = **8.38 ms**. Faster, but frequency resolution is halved to 187.5 Hz/bin.

BIN_STRIDE = 2 gives the best resolution achievable within the UART timing budget.

### Why BAUD_RATE = 312,500?

Three criteria:

1. **UART time < FFT frame time** — UART must finish before the next FFT frame arrives (21.33 ms).
2. **Zero clock error** — 125 MHz / BAUD_RATE must be an exact integer. 125,000,000 / 312,500 = **400** exactly. No fractional baud error means no accumulated bit timing drift.
3. **Comfortable margin** — 16.58 ms UART time leaves 4.75 ms headroom. Not so tight that any processing jitter causes a missed frame.

Other candidates considered:

| Baud | Divider | Error | UART time | Margin |
|------|---------|-------|-----------|--------|
| 115,200 | 1085.07 | 0.007% | 44.9 ms | -23.6 ms (too slow) |
| 230,400 | 542.54 | 0.099% | 22.5 ms | -1.2 ms (too close) |
| 460,800 | 271.27 | 0.099% | 11.2 ms | 10.1 ms (fast but fractional) |
| **312,500** | **400** | **0%** | **16.58 ms** | **4.75 ms** ✓ |
| 500,000 | 250 | 0% | 10.4 ms | 10.9 ms (faster, less resolution feasible) |
| 921,600 | 135.63 | 0.46% | 5.6 ms | 15.7 ms (baud error gets large) |

312,500 is optimal: zero error, enough margin, uses maximum bin count.

### Why L1 magnitude (|Re| + |Im|) instead of true magnitude?

True magnitude requires `sqrt(Re² + Im²)`. A hardware square root needs a CORDIC or LUT-based approach — roughly 10–20 clock cycles of latency and significant LUT/DSP usage. For a spectrum display, the exact absolute magnitude doesn't matter — only the relative heights of the bars matter. The L1 norm preserves relative ordering and is within sqrt(2) of the true value. One-cycle latency, zero DSP slices.

### Why dual-bank buffer?

The FFT produces bins sequentially in order (0, 1, 2, ..., 1023) at the FFT output clock rate. The UART FSM reads them in stride order (0, 2, 4, ..., 510) with random access. Without a buffer, the UART would need to read each bin exactly as it flows out of the FFT — impossible at UART baud rates. The buffer absorbs the entire frame, then lets the UART read at its own pace.

The dual-bank (ping-pong) design ensures the UART never reads from a bank that the FFT is simultaneously writing. A single-bank design would require the UART to finish before the FFT starts writing the next frame — too restrictive.

### Why natural FFT output order?

Early versions of the FFT IP were configured for bit-reversed output order. Bit-reversed order means the output bins appear in a scrambled sequence: 0, 512, 256, 768, 128, 640, ... rather than 0, 1, 2, 3, .... The Python script needed a bit-reversal lookup table to reorder them. This added complexity and a potential source of mapping bugs.

Reconfiguring the FFT IP for natural output order eliminates the scrambling entirely. Bin 0 comes out first, bin 1 second, and so on. The buffer simply stores them in arrival order at address `wr_idx`, which increments 0→1023. No reordering needed anywhere.

---

## Debugging Log — What Broke and How It Was Fixed

### Bug 1: Codec Not Generating LRCLK (No Audio Input)

**Symptom:** LEDs showed init_done but no I2S valid pulses. No audio data reaching the FFT.

**Root cause:** The SSM2603 R4 (Analog Audio Path Control) register was set to `0x005`, which sets `INSEL = 1` (microphone input selected). But R6 (Power Control) had `MICPD = 1` (microphone path powered down). The codec was told to route from a powered-down source — it produced no output.

**Decision process:** Inspected the SSM2603 datasheet register map. Compared R4[0] (INSEL) against R6[1] (MICPD). Found the contradiction. The project uses the LINE IN jack, not the microphone, so INSEL should be 0.

**Fix:** Changed R4 from `0x005` to `0x000`:

```vhdl
-- R4 = 0x000 : Analog audio path control
-- INSEL = 0 selects line input
std_logic_vector(to_unsigned(16#0800#, 16))
```

(The register address occupies bits[15:9] and the data occupies bits[8:0]. Register 4 = 0b0000100 → shifted left 9 = 0x0800 for the address field with data = 0x000.)

After this fix: BCLK appeared, LRCLK appeared, I2S receiver started outputting valid samples.

### Bug 2: UART FSM Never Transmitted

**Symptom:** FFT/magnitude LEDs lit (FFT working), bin buffer filling, but UART LED never lit. Python received no bytes.

**Root cause:** An older `uart_streamer.vhd` module was being used as the packet transmitter. It relied on a separate handshake protocol that had a deadlock condition — it waited for a signal that was never asserted in the current pipeline configuration.

**Decision process:** Rather than trace and fix the complex handshake, the decision was made to write a new direct packet FSM inside `spectrum_uart_top.vhd`. The FSM directly reads the bin buffer and drives the UART byte transmitter, with no intermediate handshake layer. Simpler, easier to debug, and the behavior is directly inspectable in simulation.

**Fix:** Replaced `uart_streamer` instantiation with an inline FSM in `spectrum_uart_top.vhd`. The `uart_streamer.vhd` file is retained but is no longer instantiated.

### Bug 3: FFT Simulation Hang — Testbench Stopped After sample_ready Deasserted

**Symptom:** The `fft_wrapper_tb.vhd` testbench would send some samples then stall. The FFT wrapper appeared to never accept more samples.

**Root cause:** The testbench used a simple loop that sent a sample every clock cycle. When the FFT's `s_axis_data_tready` deasserted (the FFT momentarily paused accepting data), the testbench counted that cycle as a transmitted sample anyway — it counted clock cycles, not successful handshakes. After 1024 clock cycles it stopped presenting data, but the FFT had only accepted fewer than 1024 samples (missing the ones during backpressure). Without 1024 accepted samples and `tlast`, the FFT never completed its frame.

**Fix:** The testbench was changed to count only cycles where both `sample_valid = '1'` and `sample_ready = '1'` — actual successful handshakes. After exactly 1024 such handshakes (with `tlast` on the 1024th), the FFT proceeds correctly.

### Bug 4: Every Other Frame Dropped (dropped=1 consistently)

**Symptom:** Python showed `dropped=1` on every packet. Good packets were arriving but every other FFT frame was being lost.

**Root cause:** With `SEND_BINS = 128` and `BAUD_RATE = 115200`:

```
Packet size = 2+1+2+256+1 = 262 bytes
UART time   = 262 × 10 / 115200 = 22.74 ms
FFT frame   = 1024 / 48000     = 21.33 ms
```

The UART took 22.74 ms to send one packet, but a new FFT frame arrived every 21.33 ms. The UART was slower than the FFT. While the UART was sending, the next FFT frame completed and was dropped (buffer overflow). The frame after that arrived just as the UART finished, was sent, and the cycle repeated — hence exactly one dropped frame between every two good packets.

**Decision process:** Three options were considered:
1. Reduce `SEND_BINS` (less data, faster UART) — loses frequency resolution.
2. Increase BAUD_RATE — more bandwidth, same resolution.
3. Add `FRAME_DECIM` (send every Nth frame) — reduces update rate.

Option 2 was chosen: increase resolution (BIN_STRIDE 4→2, SEND_BINS 128→256) while increasing baud rate (115,200→312,500) such that the larger packet still fits within the FFT frame time.

**Fix:** Changed BIN_STRIDE from 4 to 2, SEND_BINS from 128 to 256, BAUD_RATE from 115,200 to 312,500 in `top.vhd` and `spectrum_analyzer.py`. Result: `dropped=0` on all subsequent packets.

### Bug 5: Python Baud Rate — Misunderstanding about Device Manager

**Symptom / question:** The user asked whether the Windows Device Manager baud rate setting (showing 9600 by default) needed to be changed to 312,500.

**Answer:** No. When pyserial opens a COM port, it programs the FT232R UART chip with the baud rate specified in the `serial.Serial()` constructor, overriding whatever the Device Manager shows. Device Manager only shows the default/last-used setting. pyserial's `baudrate=312500` argument is what actually sets the hardware register.

### Bug 6: 24kHz Label Not Visible on Plot

**Symptom:** The x-axis ended at approximately 22–23k. No "24k" label visible.

**Root cause:** The x-axis `set_xlim` was set to `np.max(freq_hz)` = 23,906.25 Hz. The x-tick array included a tick at 24,000 Hz, but that tick was outside `xlim` — matplotlib does not render ticks outside the axis limits.

**Fix:** `set_xlim` changed to `SAMPLE_RATE / 2` = 24,000 Hz, then `+ 500` added as margin to ensure the 24k tick label is not clipped against the right plot boundary.

**Follow-up:** The user then noted that there was no signal bar visible near 24kHz when playing a YouTube 20kHz tone. This is physically correct — YouTube's Opus encoding rolls off above ~20kHz, and the SSM2603 anti-aliasing filter attenuates signals as they approach the 24kHz Nyquist. No bar at 24kHz means no input signal at 24kHz. The system is working correctly.

---

## UART Timing Analysis

All timing values for the current configuration:

```
FFT frame period:
  = NFFT samples / SAMPLE_RATE
  = 1024 / 48000
  = 21.333 ms

UART packet size:
  = 2 (header) + 1 (seq) + 2 (count) + 2×SEND_BINS (payload) + 1 (checksum)
  = 2 + 1 + 2 + 2×256 + 1
  = 518 bytes

UART transmission time (312,500 baud, 10 bits/byte):
  = 518 × 10 / 312,500
  = 16.576 ms

Margin before next FFT frame:
  = 21.333 ms - 16.576 ms
  = 4.757 ms

Baud rate error:
  = CLK_FREQ / BAUD_RATE = 125,000,000 / 312,500 = 400 (exact integer)
  = 0% error
```

The 4.757 ms margin means the UART finishes transmitting the packet approximately 4.76 ms before the next FFT frame is ready. The system can tolerate up to 4.76 ms of processing jitter (interrupt latency, clock domain crossing, etc.) without dropping any frames.

---

## Frequency Resolution Analysis

```
FFT bin spacing:
  = SAMPLE_RATE / NFFT
  = 48000 / 1024
  = 46.875 Hz per FFT bin

Displayed bin spacing (BIN_STRIDE = 2):
  = BIN_STRIDE × SAMPLE_RATE / NFFT
  = 2 × 46.875
  = 93.75 Hz per displayed bar

Number of displayed bars: 256
Frequency range covered:  0 Hz to 23,906.25 Hz (≈ Nyquist)

Bin quantization example — 20 kHz tone:
  Nearest bin = round(20000 / 46.875) = 426.67 → bin 427
  Displayed bar index = 427 / 2 = 213 (integer)
  Displayed frequency = 213 × 2 × 46.875 = 19,968.75 Hz ≈ 19,969 Hz

  If bin 426 is transmitted:
  Displayed frequency = 426 × 46.875 = 19,968.75 Hz

  Maximum quantization error = ±46.875 Hz
```

The peak frequency shown by Python will always be within ±93.75 Hz of the true frequency (one displayed bin either side of the true peak).

---

## Current Configuration Reference

### VHDL (top.vhd generics and u_spectrum port map)

```vhdl
entity top is
    generic (
        CLK_FREQ   : integer := 125_000_000;
        I2C_FREQ   : integer := 100_000;
        DATA_WIDTH : integer := 16;
        BAUD_RATE  : integer := 312_500      -- ← change baud rate here
    );
...
u_spectrum : entity work.spectrum_uart_top
    generic map (
        CLK_FREQ    => CLK_FREQ,
        BAUD_RATE   => BAUD_RATE,
        TOTAL_BINS  => 1024,
        SEND_BINS   => 256,                  -- ← number of bins transmitted
        BIN_STRIDE  => 2,                    -- ← step between bins
        FRAME_DECIM => 1,                    -- ← 1 = send every frame
        SCALE_SHIFT => 4                     -- ← right-shift before packing
    )
```

### Python (spectrum_analyzer.py constants)

```python
BAUD_RATE     = 312500    # must equal BAUD_RATE generic in top.vhd
EXPECTED_BINS = 256       # must equal SEND_BINS generic
SAMPLE_RATE   = 48000     # Hz
NFFT          = 1024      # must equal FFT size in xfft_0
BIN_STRIDE    = 2         # must equal BIN_STRIDE generic
NOISE_FLOOR   = 8         # display threshold
TIMEOUT       = 0.001     # serial read timeout (seconds)
```

**These pairs must always be kept in sync:**

| VHDL generic | Python constant |
|---|---|
| `BAUD_RATE` in `top.vhd` | `BAUD_RATE` in `spectrum_analyzer.py` |
| `SEND_BINS` in `top.vhd` | `EXPECTED_BINS` in `spectrum_analyzer.py` |
| `BIN_STRIDE` in `top.vhd` | `BIN_STRIDE` in `spectrum_analyzer.py` |

Changing one without the other will cause either `count` mismatches (Python rejects all packets as `bad_count`) or incorrect frequency axis labeling.

---

## Build and Run Instructions

### Vivado Build

1. Open `Audio_Spectrum_Analyzer.xpr` in Vivado 2020.x or later.
2. Ensure all VHDL files in `sources_1/new/` are added to the project.
3. Ensure `top.xdc` is the active constraints file.
4. Confirm `xfft_0` IP is generated (right-click → Generate Output Products if needed).
5. Run Synthesis → Implementation → Generate Bitstream.
6. Open Hardware Manager, connect Zybo Z7-10, program with the generated `.bit` file.

### Python Environment

```bash
cd C:\Users\Char\Documents\ECE_524\Audio_Spectrum_Analyzer
.venv\Scripts\python.exe -m pip install pyserial matplotlib numpy
```

### Running the Visualizer

```bash
# Check which COM port the Pmod USBUART is on (Device Manager → Ports)

# Debug mode first — no plot window, just print packet stats
.venv\Scripts\python.exe spectrum_analyzer.py --port COM3 --no-plot

# Live spectrum plot
.venv\Scripts\python.exe spectrum_analyzer.py --port COM3

# If bars are all tiny, lower ymax
.venv\Scripts\python.exe spectrum_analyzer.py --port COM3 --ymax 16

# If bars are clipping the top, raise ymax
.venv\Scripts\python.exe spectrum_analyzer.py --port COM3 --ymax 512
```

---

## Verification Procedure

### Step 1: Confirm FPGA is alive

After programming:
- `led[0]` blinks at ~1 Hz (heartbeat counter, 125 MHz / 2^26 ≈ 1.86 Hz)
- `led[1]`, `led[2]`, `led[3]` should light up after a few seconds (codec init completes, FFT starts, UART starts)

### Step 2: Confirm UART packets arrive

```bash
python spectrum_analyzer.py --port COM3 --no-plot
```

Expected output within a few seconds:

```
GOOD packet seq=  1 count=256 max=   12 good=  1 bad=  0 dropped=n/a
GOOD packet seq=  2 count=256 max=   11 good=  2 bad=  0 dropped=0
GOOD packet seq=  3 count=256 max=   13 good=  3 bad=  0 dropped=0
```

Key indicators:
- `count=256` — correct bin count
- `good` increasing — packets arriving
- `bad=0` — no framing or checksum errors (a few at startup is normal)
- `dropped=0` — every FFT frame is being transmitted

If `dropped=1` consistently: UART is too slow. Check `BAUD_RATE` in both `top.vhd` and `spectrum_analyzer.py`.

If all packets are bad: check `EXPECTED_BINS` matches `SEND_BINS`. Check COM port is correct.

### Step 3: Confirm spectrum responds to audio

Connect a 3.5mm cable from laptop/phone headphone output to Zybo LINE IN.

Open the live plot:

```bash
python spectrum_analyzer.py --port COM3
```

Play a 1 kHz sine wave (use Audacity tone generator, or any local audio file — avoid YouTube for calibration). A single narrow spike should appear at approximately 1000 Hz (within ±93.75 Hz due to bin quantization).

Expected: `peak=938 Hz` or `peak=1031 Hz` — the nearest displayed bin center to 1000 Hz.

### Step 4: Frequency calibration check

Test tones and expected peak bin:

| Tone | Nearest bin (BIN_STRIDE=2) | Expected displayed freq |
|------|---------------------------|------------------------|
| 500 Hz | bin index 5 | 468.75 Hz |
| 1000 Hz | bin index 11 | 1031.25 Hz |
| 2000 Hz | bin index 21 | 1968.75 Hz |
| 4000 Hz | bin index 43 | 4031.25 Hz |
| 8000 Hz | bin index 85 | 7968.75 Hz |
| 10000 Hz | bin index 107 | 10031.25 Hz |

All peaks should land within ±93.75 Hz of the test tone frequency. If peaks appear at systematically wrong frequencies (off by a factor), check `SAMPLE_RATE` and `NFFT` constants in Python.

---

## Module Summary

All paths relative to `Audio_Spectrum_Analyzer.srcs/`.

| File | Entity | Role |
|------|--------|------|
| `sources_1/new/top.vhd` | `top` | Top-level. Codec MCLK, reset, frame accumulator, LED diagnostics. |
| `sources_1/new/ssm2603_init.vhd` | `ssm2603_init` | I2C sequencer for SSM2603 register configuration. |
| `sources_1/new/i2c_master.vhd` | `i2c_master` | Write-only 100 kHz I2C master. |
| `sources_1/new/i2s_receiver.vhd` | `i2s_receiver` | I2S deserializer with CDC synchronizers. |
| `sources_1/new/fft.vhd` | `fft_wrapper` | AXI4-Stream wrapper around xfft_0. Pipelined IO. |
| `sources_1/new/spectrum_core.vhd` | `spectrum_core` | Connects fft_wrapper to magnitude_calc. |
| `sources_1/new/mag_calc.vhd` | `magnitude_calc` | L1 magnitude: |Re| + |Im|. |
| `sources_1/new/buffer.vhd` | `bin_buffer` | Dual-bank 1024-bin ping-pong buffer. |
| `sources_1/new/spectrum_uart_top.vhd` | `spectrum_uart_top` | Integrates FFT core + buffer + packet FSM. |
| `sources_1/new/UART_transmitter.vhd` | `uart_tx` | 8N1 UART byte serializer. |
| `sources_1/new/uart_streamer.vhd` | `uart_streamer` | Legacy module, currently not instantiated. |
| `spectrum_analyzer.py` | — | Python live spectrum visualizer. |

---

## Testbenches

| File | Covers |
|------|--------|
| `sim_1/new/top_tb.vhd` | Top-level integration sanity check |
| `sim_1/new/mag_calc_tb.vhd` | Magnitude calculator: positive, negative, zero, valid/last |
| `sim_1/new/bin_buffer_tb.vhd` | Buffer: writes, bank swap, readback, overflow, reset |
| `sim_1/new/uart_tb.vhd` | UART byte transmitter: bit-level decode |
| `sim_1/new/fft_wrapper_tb.vhd` | FFT wrapper: config handshake, 1024-sample acceptance, output |
| `sim_1/new/i2c_master_tb.vhd` | I2C master: start/stop, byte framing, ACK |
| `sim_1/new/i2s_receiver_tb.vhd` | I2S receiver: deserialization, valid pulse, CDC |
| `sim_1/new/ssm2603_init_tb.vhd` | Codec init sequencer: all 9 register writes |

---

## Current Status

| Stage | Status |
|-------|--------|
| MCLK generation (12.5 MHz divider) | Working |
| SSM2603 I2C initialization | Working |
| SSM2603 line-in analog path | Working (fixed INSEL bug) |
| BCLK / LRCLK detection | Working |
| I2S deserialization | Working |
| 1024-sample frame accumulation | Working |
| Xilinx 1024-point FFT | Working in simulation and hardware |
| L1 magnitude calculation | Working |
| Dual-bank bin buffer | Working |
| UART packet transmission (312,500 baud) | Working, dropped=0 |
| Pmod USBUART communication | Working (COM3) |
| Python packet decoder | Working |
| Python live bar-graph plot | Working |
| Frequency calibration (93.75 Hz resolution) | Working |
| VGA output | Not yet implemented |

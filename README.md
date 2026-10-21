# FPGA Audio Spectrum Analyzer

A real-time audio spectrum analyzer on the Digilent Zybo Z7-10 (Zynq-7010). Audio comes in through the line-in jack, the on-board SSM2603 codec digitizes it (nominally 48 kHz), a 1024-point FFT runs in the FPGA fabric, and the magnitudes go over UART to a Python script that draws a live bar graph.

## Data flow

```
line-in jack
   |
SSM2603 codec       configured over I2C, sends I2S, gets MCLK from the FPGA
   |
i2s_receiver        synchronizers + deserializer, 16-bit samples at 48 kHz
   |
frame accumulator   collects 1024 left-channel samples (in top.vhd)
   |
fft_wrapper         Xilinx xfft_0, 1024-point, AXI4-Stream
   |
mag_calc            abs(Re) + abs(Im)
   |
bin_buffer          ping-pong RAM, holds all 1024 bins
   |
packet FSM          518-byte packets: header, sequence number, XOR checksum
   |
UART TX             312,500 baud 8N1, into the Pmod USBUART (FT232R)
   |
spectrum_analyzer.py   finds the header, checks the checksum, plots
```

## Background

**Bin spacing.** With N = 1024 and Fs = 48 kHz each FFT bin is 48000 / 1024 = 46.875 Hz wide. For real input, bins 513-1023 just mirror bins 511-1, so only 0-512 matter. Bin 512 is Nyquist (24 kHz).

**Magnitude.** The true magnitude is sqrt(Re² + Im²). A square root in fabric needs a CORDIC or a lookup table, so I use abs(Re) + abs(Im) instead. It's never smaller than the true value and at most sqrt(2) (about 41%) larger. For a bar graph only the relative heights matter, so that's fine.

**Aliasing.** Anything above 24 kHz folds back into the band (a 40 kHz component shows up at 8 kHz). The codec has an anti-aliasing filter, but it isn't a brick wall. A 20 kHz YouTube tone shows a cluster around 8-10 kHz in the plot, which I think is harmonics folding back. Bins near 24 kHz stay close to zero with normal music or YouTube audio because the source rolls off around 20 kHz and the codec filter attenuates near Nyquist.

**I2S.** The codec is the I2S master. BCLK is 2 x 16 x 48000 = 1.536 MHz, LRCLK toggles at 48 kHz (low = left), and data is MSB first, one BCLK after the LRCLK edge. Only the left channel goes to the FFT.

**MCLK.** The codec is in USB mode (R8 = 0x001), which expects a 12 MHz master clock. I generate MCLK by toggling a divider every 5 cycles of the 125 MHz clock, which gives 12.5 MHz. That isn't exactly 12 MHz, so the real sample rate isn't exactly 48 kHz. The Python script assumes exactly 48 kHz, so treat the frequency axis as approximate.

## Hardware

| Item | Value |
|------|-------|
| Board | Digilent Zybo Z7-10 (XC7Z010-1CLG400C) |
| System clock | 125 MHz on pin K17 |
| Codec | Analog Devices SSM2603 (on board), line-in, I2S master |
| Codec MCLK | 12.5 MHz (125 MHz / 10, from a divider in the FPGA) |
| UART | Digilent Pmod USBUART (FT232R), 312,500 baud, 8N1 |
| PC side | COM3 on my machine (check Device Manager for yours) |

Pin assignments are in `Audio_Spectrum_Analyzer.srcs/constrs_1/new/top.xdc`:

| Port | Pin | Dir | Function |
|------|-----|-----|----------|
| `clk_125` | K17 | in | 125 MHz system clock |
| `ac_mclk` | R17 | out | master clock to codec |
| `ac_bclk` | R19 | in | I2S bit clock |
| `ac_lrclk` | Y18 | in | I2S left/right clock |
| `ac_recdat` | R16 | in | I2S data from the codec ADC |
| `ac_scl` | N18 | out | I2C clock |
| `ac_sda` | N17 | inout | I2C data |
| `uart_rts` | V15 | in | Pmod USBUART RTS |
| `uart_tx` | W15 | out | to Pmod USBUART RXD |
| `uart_rx` | T11 | in | from Pmod USBUART TXD |
| `uart_cts` | T10 | out | driven low (always ready) |
| `led[0]` | M14 | out | heartbeat |
| `led[1]` | M15 | out | FFT/magnitude output active |
| `led[2]` | G14 | out | UART byte being sent |
| `led[3]` | D18 | out | full packet sent |

## Modules

**`top.vhd`** ties everything together: power-on reset, the MCLK divider, open-drain I2C pins (drive low or high-Z), the frame accumulator, and the LEDs. Reset is held for CLK_FREQ/100 = 1,250,000 cycles (about 10 ms). The frame accumulator has three states: `WAIT_INIT` (until codec init is done), `WAIT_FRAME_READY` (until the FFT can take a frame) and `STREAM`. It has a one-sample staging register because the I2S receiver produces a sample every 1/48000 s no matter what the FFT is doing. Without it, a sample would be lost any time the FFT briefly deasserts ready. The LED signals are single-cycle pulses, so each one is stretched to 0.25 s (CLK_FREQ/4 cycles) to be visible.

**`ssm2603_init.vhd` and `i2c_master.vhd`** configure the codec. The I2C master is write-only at 100 kHz (1250 system clocks per SCL period). The codec address is 0x1A, and each register write is three bytes: address + write bit, then register/data bits. The master samples ACK on the 9th clock and raises `ack_err` on a NACK, but the init sequence keeps going either way. After the software reset I wait 100 ms before writing the rest.

| Step | Reg | Value | What it does |
|------|-----|-------|--------------|
| 0 | R15 | 0x000 | software reset |
| 1 | R6 | 0x01A | power: line-in and ADC on; mic, DAC and outputs off |
| 2 | R0 | 0x017 | left line-in, 0 dB, unmuted |
| 3 | R1 | 0x017 | right line-in, 0 dB, unmuted |
| 4 | R4 | 0x000 | analog path: line-in selected, no mic boost |
| 5 | R5 | 0x000 | digital path: ADC high-pass filter on, no de-emphasis |
| 6 | R7 | 0x042 | I2S format, 16-bit, codec is master |
| 7 | R8 | 0x001 | USB mode, 48 kHz |
| 8 | R9 | 0x001 | activate the digital interface |

**`i2s_receiver.vhd`** deserializes the codec output. BCLK, LRCLK and SDATA are all asynchronous to the 125 MHz clock, so each goes through a synchronizer: 3 stages on BCLK (so I can compare the last two values for a rising edge) and 2 stages on LRCLK and SDATA. The receiver skips the first BCLK after the LRCLK edge (the I2S delay bit) and shifts in the next 16. It pulses `valid` once per L+R pair.

**`fft.vhd`** wraps the Xilinx `xfft_0` core in a simple ready/valid interface.

- 1024-point, pipelined streaming architecture, fixed point
- 24-bit real input, imaginary part tied to 0; 24-bit real + 24-bit imaginary output
- natural output order, truncation rounding
- one config word at startup: `0x0557` = forward FFT (bit 0) plus the scaling schedule `0x2AB` in bits 10:1. In 2-bit groups, one per stage, that is `10 10 10 10 11`. Without per-stage scaling a full-scale sine overflows the fixed-point math.
- `tlast` on sample 1023. The wrapper holds `m_axis_data_tready` high so outputs never stall, and goes back to idle as soon as the last input sample is accepted, so the next frame can start while the previous one is still coming out.

The first version used bit-reversed output order, which meant a bit-reversal table in the Python script. Switching the IP to natural order removed all of that.

**`mag_calc.vhd`** computes abs(Re) + abs(Im) in one clock cycle and passes `last` through with the same delay. Each absolute value can be as large as 2^23 (the abs of the most negative 24-bit value), so the sum can reach 2^24 and needs 25 bits. Both operands are zero-extended to 25 bits before the add.

**`buffer.vhd`** has two RAM banks of 1024 x 25 bits. The FFT writes one bank while the UART reads the other. When `mag_last` arrives, the banks swap if the UART has finished the previous frame. If it hasn't, the new frame is dropped and `overflow` pulses for one cycle. The UART never sees a half-written frame. The read is synchronous, which is why the packet FSM has a set-address state followed by a wait state for every bin.

**`spectrum_uart_top.vhd` and `UART_transmitter.vhd`** build and send the packets. Magnitudes are shifted right by 4 to fit 16 bits (`SCALE_SHIFT`) and clamped to 0xFFFF if they still don't fit, so loud sounds can't wrap around to look quiet. The byte transmitter does 8N1, LSB first, with one bit every `CLK_FREQ / BAUD_RATE` = 400 clocks. `uart_streamer.vhd` is an older module that is still in the repo but isn't used.

## UART packet

| Bytes | Field |
|-------|-------|
| 0-1 | header `0xAA 0x55` |
| 2 | sequence number (wraps at 255) |
| 3-4 | bin count, `0x0100` = 256 |
| 5-516 | 256 bins, 16 bits each, big-endian. Bar i is FFT bin 2i |
| 517 | checksum |

518 bytes total: 2 + 1 + 2 + 512 + 1. The checksum is the XOR of the sequence number, both count bytes and all 512 payload bytes (the header isn't included).

## Timing and design choices

An FFT frame is 1024 / 48000 = 21.33 ms. The UART has to finish a packet in less time than that or frames get dropped.

- 518-byte packet at 312,500 baud: 518 x 10 / 312,500 = 16.58 ms, which leaves 4.76 ms of margin.
- Sending every bin (stride 1, 512 bins) would be 1030 bytes, or 32.96 ms at 312,500 baud. That doesn't fit.
- Stride 4 (128 bins, 262 bytes) takes only 8.38 ms, but the bars are 187.5 Hz apart instead of 93.75 Hz.
- 125 MHz / 312,500 = 400 exactly, so there's no rounding error in the baud generator on the FPGA side.

| Baud | Divider | UART time (518 B) | Margin |
|------|---------|-------------------|--------|
| 115,200 | 1085.07 | 44.97 ms | -23.63 ms |
| 230,400 | 542.53 | 22.48 ms | -1.15 ms |
| **312,500** | **400** | **16.58 ms** | **4.76 ms** |
| 460,800 | 271.27 | 11.24 ms | 10.09 ms |
| 500,000 | 250 | 10.36 ms | 10.97 ms |
| 921,600 | 135.63 | 5.62 ms | 15.71 ms |

I went with 312,500 because the divider is exact and it keeps a few milliseconds of margin. 500,000 baud is also an exact divider and would be fast enough for all 512 bins (1030 bytes is 20.6 ms), but that leaves under 1 ms of margin.

**Resolution.** Each FFT bin is 46.875 Hz, and with stride 2 each displayed bar is 93.75 Hz apart. The 256 bars cover 0 to 23,906.25 Hz. Example: a 20 kHz tone falls at bin 426.67. Only even bins are sent, so the nearest bar is bin 426 (bar 213, 19,968.75 Hz). The displayed peak should be within about one bar (94 Hz) of the true frequency.

## Python script

`spectrum_analyzer.py` reads the serial port and plots with matplotlib.

- Keeps a rolling buffer and looks for `0xAA 0x55`.
- Reads the count and rejects anything other than `EXPECTED_BINS`.
- Reads the payload and checksum, recomputes the XOR, and resyncs on any mismatch.
- Tracks good, bad and dropped packets. Dropped is `(seq - last_seq - 1) & 0xFF`, so 0 means nothing was skipped and 1 means one frame was skipped between two packets.
- Draws only the newest packet on each pass so the plot doesn't fall behind. It updates about 33 times a second (30 ms `plt.pause`), and the y-axis auto-scales to about 1.5 x the current peak.
- Frequency of bar i = i x 2 x 48000 / 1024 = i x 93.75 Hz.

These constants have to match the VHDL generics:

| Python (`spectrum_analyzer.py`) | VHDL (`top.vhd`) |
|---------------------------------|------------------|
| `BAUD_RATE = 312500` | `BAUD_RATE` |
| `EXPECTED_BINS = 256` | `SEND_BINS` |
| `BIN_STRIDE = 2` | `BIN_STRIDE` |

`SAMPLE_RATE = 48000` and `NFFT = 1024` also have to match the codec setup and the FFT core. If `BAUD_RATE` or `BIN_STRIDE` don't match, you get garbage. If `EXPECTED_BINS` doesn't match `SEND_BINS`, every packet is rejected as a bad count.

The baud rate shown in Windows Device Manager doesn't matter. pyserial sets it when it opens the port.

## Testing

Testbenches in `sim_1/new/`:

| File | Covers |
|------|--------|
| `top_tb.vhd` | top-level sanity check |
| `mag_calc_tb.vhd` | positive, negative and zero inputs, valid/last |
| `bin_buffer_tb.vhd` | writes, bank swap, readback, overflow, reset |
| `uart_tb.vhd` | bit-level decode of the byte transmitter |
| `fft_wrapper_tb.vhd` | config handshake, 1024-sample acceptance, output |
| `i2c_master_tb.vhd` | start/stop, byte framing, ACK |
| `i2s_receiver_tb.vhd` | deserialization, valid pulse, clock-domain crossing |
| `ssm2603_init_tb.vhd` | all 9 register writes |

On the board:

1. **Alive check.** `led[0]` blinks (heartbeat). A few seconds after programming, `led[1]`, `led[2]` and `led[3]` should light up.
2. **Packets.** Run `python spectrum_analyzer.py --port COM3 --no-plot`. You should see something like this, with `bad` staying at 0 apart from a few at startup:
```
   GOOD packet seq=  1 count=256 max=   12 good=  1 bad=  0 dropped=n/a
   GOOD packet seq=  2 count=256 max=   11 good=  2 bad=  0 dropped=0
```
   If `dropped` is 1 on every packet, the UART is too slow (check `BAUD_RATE` in both places). If every packet is bad, check `EXPECTED_BINS` and the COM port.
3. **Tone test.** Play a 1 kHz sine from a local file (not YouTube) into LINE IN. A single spike should show up near 1 kHz. With stride 2 the closest bars are 937.5 Hz and 1031.25 Hz.
4. **More tones.** At exactly 48 kHz the expected peaks are:

| Tone | Bar | Displayed |
|------|-----|-----------|
| 500 Hz | 5 | 468.75 Hz |
| 1 kHz | 11 | 1031.25 Hz |
| 2 kHz | 21 | 1968.75 Hz |
| 4 kHz | 43 | 4031.25 Hz |
| 8 kHz | 85 | 7968.75 Hz |
| 10 kHz | 107 | 10031.25 Hz |

   If the peaks are off by a consistent ratio, check `SAMPLE_RATE` and `NFFT` in the Python script (and see the MCLK note above).

## Bugs I ran into

**1. No I2S clocks from the codec.** `init_done` came up but no valid samples reached the FFT. I compared my register values against the datasheet and found R4 was 0x005, which selects the mic input, while R6 had the mic powered down. I'm using the line-in jack, so I set R4 to 0x000. After that BCLK and LRCLK showed up and the I2S receiver started producing samples.

**2. The UART never sent anything.** The FFT and buffer LEDs were lit, but the UART LED never was and Python received nothing. The old `uart_streamer.vhd` had a handshake that could deadlock, because it waited on a signal that never came in this pipeline. Instead of untangling it, I wrote the packet FSM directly inside `spectrum_uart_top.vhd` so it drives the byte transmitter with nothing in between.

**3. The FFT testbench hung.** The testbench sent a sample every clock cycle and counted cycles, not accepted samples. Whenever the FFT deasserted `tready`, the testbench counted a sample that was never taken, so the FFT never saw all 1024 samples or `tlast`. I changed it to count only cycles where valid and ready are both high.

**4. Every other frame was dropped.** Python showed `dropped=1` on every packet. At the time I was sending 128 bins (262 bytes) at 115,200 baud. That takes 22.74 ms, but a new FFT frame arrives every 21.33 ms. The next frame finished while the UART was still busy and got dropped, the one after that arrived once the UART was free, and so on. I considered sending fewer bins, sending every Nth frame, or a faster baud rate. I went with the faster baud rate and also doubled the resolution (stride 4 to 2, 128 to 256 bins), which is where 312,500 baud came from. After that, `dropped=0`.

**5. The "24k" label was missing on the plot.** I had set `xlim` to the highest bar (23,906.25 Hz), so the tick at 24,000 Hz fell outside it and matplotlib didn't draw it. I set the limit to `SAMPLE_RATE / 2 + 500`. There's also no bar near 24 kHz when I play a YouTube 20 kHz tone, which is expected because the source rolls off above about 20 kHz.

## Build and run

**FPGA:**
1. Open `Audio_Spectrum_Analyzer.xpr` in Vivado (2020.x or newer).
2. Make sure everything in `sources_1/new/` is in the project and `top.xdc` is the active constraints file.
3. Generate the `xfft_0` output products if Vivado asks.
4. Run synthesis, implementation and bitstream generation.
5. Connect the board in Hardware Manager and program it.

**Python:**
```
pip install pyserial matplotlib numpy

python spectrum_analyzer.py --port COM3 --no-plot   # print packet stats only
python spectrum_analyzer.py --port COM3             # live plot
python spectrum_analyzer.py --port COM3 --ymax 16   # bars too small
python spectrum_analyzer.py --port COM3 --ymax 512  # bars clipping
```

## Status

Everything above works on the board with `dropped=0` at 312,500 baud. Known gaps:

- The frequency axis assumes exactly 48 kHz and I haven't measured the real sample rate (see the MCLK note).
- Bar spacing is 93.75 Hz at 48 kHz. Sending all 512 bins would need a faster baud rate.
- No VGA output yet. The only display is the Python plot.

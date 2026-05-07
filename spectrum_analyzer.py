import argparse
import sys
import time
from collections import deque

import matplotlib

# Force a real desktop window backend.
# This must happen before importing matplotlib.pyplot.
try:
    matplotlib.use("TkAgg")
except Exception:
    pass

import matplotlib.pyplot as plt
import numpy as np
import serial
from serial.tools import list_ports



# Hardware / packet settings
DEFAULT_SERIAL_PORT = "COM3"
BAUD_RATE = 312500
TIMEOUT = 0.001

HEADER = b"\xAA\x55"
EXPECTED_BINS = 256
NOISE_FLOOR = 8   # bins below this magnitude are treated as silence

# FFT / hardware parameters
SAMPLE_RATE = 48000
NFFT = 1024
BIN_STRIDE = 2

# FFT IP outputs in natural order, so buffer index i*BIN_STRIDE is
# directly FFT bin i*BIN_STRIDE. No bit-reversal needed.
nat_bins = np.arange(EXPECTED_BINS, dtype=np.int32) * BIN_STRIDE
sort_order = np.arange(EXPECTED_BINS, dtype=np.int32)  # already sorted
freq_hz = nat_bins * SAMPLE_RATE / NFFT


# ============================================================
# Serial helpers
# ============================================================
def print_available_ports():
    ports = list(list_ports.comports())

    print()
    print("Available serial ports:")

    if not ports:
        print("  No serial ports found.")
        print()
        return

    for p in ports:
        print(f"  {p.device:8s}  {p.description}")

    print()


def checksum_ok(seq_byte, count_bytes, payload, checksum_byte):
    value = seq_byte ^ count_bytes[0] ^ count_bytes[1]

    for b in payload:
        value ^= b

    return (value & 0xFF) == checksum_byte


class PacketReader:
    def __init__(self, port, baud, timeout):
        self.ser = serial.Serial(
            port=port,
            baudrate=baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=timeout
        )

        self.ser.reset_input_buffer()

        self.buf = bytearray()

        self.last_seq = None
        self.good_packets = 0
        self.bad_packets = 0
        self.bad_checksum = 0
        self.bad_count = 0
        self.resyncs = 0
        self.total_bytes = 0

        self.last_byte_time = time.time()
        self.raw_recent = deque(maxlen=32)

    def close(self):
        self.ser.close()

    def _fill(self):
        waiting = self.ser.in_waiting
        data = self.ser.read(waiting if waiting > 0 else 1)

        if data:
            self.buf.extend(data)
            self.total_bytes += len(data)
            self.last_byte_time = time.time()

            for b in data:
                self.raw_recent.append(b)

        return len(data)

    def raw_recent_hex(self):
        if not self.raw_recent:
            return "(none)"

        return " ".join(f"{b:02X}" for b in self.raw_recent)

    def read_packet(self):
        self._fill()

        while True:
            header_pos = self.buf.find(HEADER)

            if header_pos < 0:
                # Keep the last byte in case it is 0xAA and the next byte is 0x55.
                if len(self.buf) > 1:
                    del self.buf[:-1]
                    self.resyncs += 1

                return None

            if header_pos > 0:
                del self.buf[:header_pos]
                self.resyncs += 1

            # Need at least:
            #   2 header bytes + 1 seq + 2 count
            if len(self.buf) < 5:
                return None

            seq_byte = self.buf[2]
            count_hi = self.buf[3]
            count_lo = self.buf[4]
            count = (count_hi << 8) | count_lo

            # Sanity check count before trusting frame length.
            if count <= 0 or count > 1024:
                del self.buf[0]
                self.bad_packets += 1
                self.bad_count += 1
                self.resyncs += 1
                continue

            frame_len = 2 + 1 + 2 + (2 * count) + 1

            if len(self.buf) < frame_len:
                return None

            packet = bytes(self.buf[:frame_len])
            del self.buf[:frame_len]

            payload = packet[5:-1]
            checksum_byte = packet[-1]

            if count != EXPECTED_BINS:
                self.bad_packets += 1
                self.bad_count += 1
                continue

            if len(payload) != 2 * count:
                self.bad_packets += 1
                self.bad_count += 1
                continue

            if not checksum_ok(seq_byte, packet[3:5], payload, checksum_byte):
                self.bad_packets += 1
                self.bad_checksum += 1
                continue

            mags = np.frombuffer(payload, dtype=">u2").astype(np.float32)

            dropped = None
            if self.last_seq is not None:
                dropped = (seq_byte - self.last_seq - 1) & 0xFF

            self.last_seq = seq_byte
            self.good_packets += 1

            return {
                "seq": seq_byte,
                "count": count,
                "mags": mags,
                "dropped": dropped,
            }


# ============================================================
# No-plot debug mode
# ============================================================
def run_no_plot(reader):
    try:
        last_print = time.time()

        while True:
            packet = reader.read_packet()
            now = time.time()

            if packet is not None:
                mags = packet["mags"]

                print(
                    f"GOOD packet "
                    f"seq={packet['seq']:3d} "
                    f"count={packet['count']:3d} "
                    f"max={int(np.max(mags)):5d} "
                    f"good={reader.good_packets} "
                    f"bad={reader.bad_packets} "
                    f"dropped={packet['dropped'] if packet['dropped'] is not None else 'n/a'}"
                )

            elif now - last_print > 1.0:
                age = now - reader.last_byte_time

                print(
                    f"waiting... "
                    f"bytes={reader.total_bytes} "
                    f"buf={len(reader.buf)} "
                    f"good={reader.good_packets} "
                    f"bad={reader.bad_packets} "
                    f"bad_checksum={reader.bad_checksum} "
                    f"bad_count={reader.bad_count} "
                    f"resyncs={reader.resyncs} "
                    f"last_byte_age={age:.2f}s "
                    f"recent={reader.raw_recent_hex()}"
                )

                last_print = now

    except KeyboardInterrupt:
        print()
        print("Stopped.")


# ============================================================
# Live plotting mode
# ============================================================
def run_plot(reader, ymin_ymax):
    print(f"Matplotlib backend: {matplotlib.get_backend()}")
    print("Opening live spectrum window...")
    print("Close the plot window to stop.")
    print()

    plt.ion()

    y = np.zeros(EXPECTED_BINS, dtype=np.float32)

    fig, ax = plt.subplots(figsize=(12, 5))

    bar_width = SAMPLE_RATE / NFFT * BIN_STRIDE * 0.8
    bars = ax.bar(freq_hz, y, width=bar_width, align="center")

    ax.set_title("FPGA Audio Spectrum Analyzer — SSM2603 Line In / ADC")
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Magnitude")

    ax.set_xlim(0, SAMPLE_RATE / 2)
    ax.set_ylim(0, ymin_ymax)
    ax.set_xticks(np.arange(0, SAMPLE_RATE / 2 + 1, 1000))
    ax.set_xticklabels([f"{int(f/1000)}k" if f % 2000 == 0 else "" for f in np.arange(0, SAMPLE_RATE / 2 + 1, 1000)], fontsize=8)
    ax.grid(True, axis="both", alpha=0.3)

    status = ax.text(
        0.01,
        0.98,
        "waiting for packets...",
        transform=ax.transAxes,
        verticalalignment="top",
        fontsize=9,
        family="monospace"
    )

    fig.tight_layout()
    fig.show()

    last_console_print = time.time()

    try:
        while plt.fignum_exists(fig.number):
            got_packet = False

            # Drain all queued packets and keep only the latest.
            # This prevents the display from lagging behind when the
            # serial buffer fills up faster than we render.
            latest_packet = None
            while True:
                packet = reader.read_packet()
                if packet is None:
                    break
                latest_packet = packet

            if latest_packet is not None:
                got_packet = True
                packet = latest_packet
                mags_sorted = packet["mags"][sort_order]
                mags_sorted = np.where(mags_sorted > NOISE_FLOOR, mags_sorted, 0)

                if np.max(mags_sorted) == 0:
                    peak_freq, peak_mag = 0.0, 0
                else:
                    peak_idx  = int(np.argmax(mags_sorted))
                    peak_freq = float(freq_hz[peak_idx])
                    peak_mag  = int(mags_sorted[peak_idx])

                ymax = max(ymin_ymax, float(peak_mag) * 1.5)
                ax.set_ylim(0, ymax)

                for bar, h in zip(bars, mags_sorted):
                    bar.set_height(float(h))

                dropped = packet["dropped"]

                status.set_text(
                    f"seq={packet['seq']:3d}  "
                    f"peak={peak_freq:.0f} Hz @ {peak_mag}  "
                    f"good={reader.good_packets}  "
                    f"bad={reader.bad_packets}  "
                    f"cksum_bad={reader.bad_checksum}  "
                    f"dropped={dropped if dropped is not None else 'n/a'}  "
                    f"bytes={reader.total_bytes}"
                )

            now = time.time()

            if not got_packet and now - last_console_print > 1.0:
                age = now - reader.last_byte_time

                status.set_text(
                    f"waiting... "
                    f"bytes={reader.total_bytes}  "
                    f"buf={len(reader.buf)}  "
                    f"good={reader.good_packets}  "
                    f"bad={reader.bad_packets}  "
                    f"last_byte_age={age:.1f}s"
                )

                print(
                    f"waiting... "
                    f"bytes={reader.total_bytes} "
                    f"buf={len(reader.buf)} "
                    f"good={reader.good_packets} "
                    f"bad={reader.bad_packets}"
                )

                last_console_print = now

            fig.canvas.draw_idle()
            fig.canvas.flush_events()
            plt.pause(0.03)

    except KeyboardInterrupt:
        print()
        print("Stopped.")

    finally:
        plt.ioff()


# ============================================================
# Main
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description="FPGA UART audio spectrum analyzer viewer"
    )

    parser.add_argument(
        "--port",
        default=DEFAULT_SERIAL_PORT,
        help=f"Serial port, for example COM3. Default: {DEFAULT_SERIAL_PORT}"
    )

    parser.add_argument(
        "--baud",
        type=int,
        default=BAUD_RATE,
        help=f"UART baud rate. Default: {BAUD_RATE}"
    )

    parser.add_argument(
        "--no-plot",
        action="store_true",
        help="Only print packet/debug info. Do not open matplotlib window."
    )

    parser.add_argument(
        "--raw",
        action="store_true",
        help="Accepted for compatibility. Raw bytes are printed in no-plot waiting status."
    )

    parser.add_argument(
        "--ymax",
        type=float,
        default=64.0,
        help="Initial/minimum Y-axis maximum. Default: 64.0"
    )

    args = parser.parse_args()

    print_available_ports()

    print(f"Opening serial port: {args.port}")
    print(f"Baud rate: {args.baud}")
    print("Expected packet:")
    print("  header      = AA 55")
    print(f"  bin count   = {EXPECTED_BINS}")
    print(f"  packet size = {2 + 1 + 2 + (2 * EXPECTED_BINS) + 1} bytes")
    print()

    try:
        reader = PacketReader(args.port, args.baud, TIMEOUT)
    except serial.SerialException as e:
        print(f"ERROR: Could not open {args.port}")
        print(e)
        print()
        print("Check Device Manager and run again with:")
        print("  python spectrum_analyzer.py --port COMx")
        sys.exit(1)

    try:
        if args.no_plot:
            run_no_plot(reader)
        else:
            run_plot(reader, args.ymax)

    finally:
        reader.close()


if __name__ == "__main__":
    main()
# Munbyn Easy Print

Print to a Bluetooth **MUNBYN 941BP** label printer from any Mac app.

Munbyn Easy Print is a small menu bar app that makes the 941BP show up as a
regular macOS printer. Press ⌘P in Safari, Preview, a shipping site, or
anything else, pick **MUNBYN 941BP**, and the label prints over Bluetooth. You
don't need a vendor driver, a kernel extension, or a USB cable.

```
 Any Mac app ──⌘P──▶ CUPS ──IPP/PDF──▶ Munbyn Easy Print ──TSPL over Bluetooth──▶ 941BP
                    (queue MUNBYN_941BP)   127.0.0.1:8631
```

> [!NOTE]
> This is an independent project. It is not affiliated with or endorsed by
> MUNBYN. "MUNBYN" is used only to say which printer this works with.

## Features

- Works with the standard macOS print dialog. Paper sizes, copies, and
  page ranges behave like any other printer.
- 17 built-in label sizes (4×6, 4×4, 2.25×1.25, and others) plus custom sizes
  from 1–4.25" wide and 0.5–22" long.
- Prints at the printer's native 300 dpi. Barcodes and text stay crisp, and
  photos are dithered.
- Landscape pages, such as a 6×4 shipping label, are rotated to fit the 4"
  print head.
- Finds the paired printer on its own and releases the Bluetooth connection
  when idle, so the phone app can still reach the printer.
- Menu bar controls for test labels, gap calibration, job history, darkness,
  and print offsets.

## Requirements

- macOS 14 Sonoma or later
- Xcode or the Xcode Command Line Tools (Swift 5.10 or later) to build it
- A MUNBYN 941BP (the Bluetooth model, which pairs as `ITPP941BP-xxxx`)

Only the 941BP has been tested. Other MUNBYN and Aimo TSPL printers might
work with one of the alternative dialects under **Settings › Connection**. If
you try one, please open an issue and say how it went.

## Install

There are no prebuilt releases yet, so build it from source:

```sh
git clone https://github.com/austinblade/munbyn-easy-print.git
cd munbyn-easy-print
./scripts/build-app.sh --install
```

This builds `Munbyn Easy Print.app`, copies it to `/Applications`, and starts
it. Look for the printer icon in the menu bar.

The script signs the app with your Apple Development certificate if you have
one. Otherwise it uses an ad-hoc signature, and macOS will ask for Bluetooth
permission again after each rebuild. To force ad-hoc signing, run
`SIGN_IDENTITY=- ./scripts/build-app.sh --install`.

## Setup

1. **Pair the printer.** Turn on the 941BP and pair it in
   System Settings › Bluetooth. It shows up as `ITPP941BP-xxxx`.
2. **Launch the app.** On first launch it:
   - adds a `MUNBYN 941BP` printer to macOS (you may be asked for an
     administrator password),
   - asks for Bluetooth and notification permission,
   - turns on **Open at login**, because macOS can only print to the 941BP
     while the app is running.
3. **Pick the printer.** The app selects the paired `ITPP941BP` on its own.
   If it doesn't, click **Find printer…** in the menu bar.
4. **Calibrate.** Load your labels and click **Calibrate** so the printer
   learns where each label starts. Do this again whenever you load a
   different roll.
5. **Print a test label.** Click **Test Label**.

## Printing

Print from any app with ⌘P, choose **MUNBYN 941BP**, and set the paper size
to match the labels you have loaded (for example **4x6**). Turn off any
"scale to fit" or margin options in the app you're printing from if the label
comes out shrunk.

Jobs that arrive while the printer is off or out of range wait in the queue
and print once the printer is reachable.

## Troubleshooting

| Symptom | Try |
| --- | --- |
| A blank label feeds out | **Settings › Connection**: set the dialect to *Standard TSPL II* |
| Job sits at "Waiting for printer" | The printer is off or out of range, or the phone app is holding the connection. Close the phone app |
| "The printer stopped accepting data" | Turn the printer off and on again. The job resends on its own |
| Print is too light, too dark, or shifted | **Settings › Printing**: adjust darkness, offsets, or gap size |
| Labels drift or print across the gap | Click **Calibrate** in the menu bar |
| The printer is gone from the print dialog | **Settings › General › Re-create queue** |
| macOS never asks for Bluetooth permission | System Settings › Privacy & Security › Bluetooth: allow Munbyn Easy Print |

To see what's sent to the printer, turn on **Settings › General › Save TSPL
and preview of every job**. The raw `.tspl` bytes and a PNG preview of each
job are saved to `~/Library/Application Support/Munbyn Easy Print/Jobs`.
**Simulate printer** renders jobs without using Bluetooth at all.

Bluetooth events go to the system log:

```sh
log stream --predicate 'process == "MunbynEasyPrint"' --style compact
```

When you report a bug, please include your macOS version, the label size,
and the relevant log output.

## Uninstall

1. **Settings › General › Remove from macOS** removes the print queue.
2. Quit the app from the menu bar.
3. Delete `/Applications/Munbyn Easy Print.app`.
4. Optionally, delete `~/Library/Application Support/Munbyn Easy Print`.

## How it works

**Virtual printer.** The app runs a small [IPP Everywhere] server that
listens only on loopback (`ipp://127.0.0.1:8631/ipp/print`) and registers it
with `lpadmin -m everywhere`. CUPS builds the driver from the attributes the
server reports: label sizes, zero margins, 300 dpi, and PDF passthrough.
Nothing gets installed into `/usr/libexec/cups`, and System Integrity
Protection stays on. The server is not reachable from other machines, and
the queue is not shared.

**Rendering.** PDF pages are rasterized at 300 dpi with CoreGraphics. Vector
art is drawn without antialiasing so barcodes keep hard edges, and gray areas
are Floyd–Steinberg dithered. PWG Raster, Apple URF, JPEG, and PNG input are
also accepted.

**TSPL.** The printer speaks TSPL. `Sources/PrintCore/TSPL.swift` is based on
the encoder from [thermal-label/labelife] (`packages/core/src/tspl/encode.ts`)
and supports three dialects:

- *Standard TSPL II* (`BITMAP …,0,`, uncompressed, `0 = dark`). This is what
  the 941BP speaks and is the default. Only the parts of the label that have
  ink are sent, as one `BITMAP` per run of ink in 24-dot bands. `CLS` already
  blanks the rest. A typical 4×6 label drops from 270 KB to about 70 KB.
- *Aimo chunked LZO* (`BITMAP …,4,`) and *whole-frame LZO*
  (`BITMAP …,3,<len>,`). These are LabeLife's profiles for other MUNBYN and
  Aimo models. The 941BP ignores LZO bitmaps and feeds a blank label.

**LZO.** The Aimo dialects use `Sources/PrintCore/LZO.swift`, a full LZO1X-1
compressor ported from miniLZO. LabeLife's own encoder only emits literals.
The output is checked against liblzo2's `lzo1x_decompress_safe` (see
[Development](#development)).

**Bluetooth.** The 941BP is a Classic Bluetooth device. It offers a serial
port ("SPP Dev") on RFCOMM channel 1 and doesn't advertise over BLE. When a
job arrives, the app connects with IOBluetooth, streams the job in MTU-sized
writes (about 40 KB/s), and drops the link after 90 seconds idle. Jobs are
never cancelled in the middle of a transfer: if a job is cut off inside a
`BITMAP`, the printer stops accepting data until it's power cycled. If the
printer stops draining for 15 seconds anyway, the app reconnects and resends
the job.

## Development

```sh
swift build                          # debug build
swift test                           # TSPL, LZO, IPP, and raster tests
./scripts/build-app.sh               # release .app in build/, no install
```

`swift run` won't work well. The app needs a bundle (`Info.plist`) for
Bluetooth permission and launch at login, so use `build-app.sh` to try it for
real.

To cross-check the LZO compressor against the reference implementation
(needs `brew install lzo`):

```sh
LZO_FIXTURE_DIR=/tmp/lzo swift test --filter testDumpFixturesForLiblzo
cc scripts/verify-lzo.c -I"$(brew --prefix lzo)/include" -L"$(brew --prefix lzo)/lib" -llzo2 -o /tmp/verify-lzo
/tmp/verify-lzo /tmp/lzo
```

The app icon is generated by `scripts/make-icon.swift`. Delete
`Resources/AppIcon.icns` and run `build-app.sh` to regenerate it.

### Layout

```
Sources/PrintCore/           pure Swift, unit-tested
  LZO.swift                  LZO1X-1 compressor + TSPL chunk framing
  TSPL.swift                 TSPL encoder (LabeLife port + stock dialect)
  Rasterizer.swift           PDF/image → 1-bit, rotation, dithering
  DocumentDecoder.swift      PDF, PWG Raster, URF, JPEG, PNG
  IPP.swift                  IPP/2.0 wire codec
  LabelMedia.swift           label sizes, PWG media names
Sources/MunbynEasyPrint/     the menu bar app
  HTTPServer.swift           loopback HTTP/1.1 (chunked, 100-continue)
  IPPPrinterService.swift    IPP Everywhere printer + job operations
  JobStore.swift             job queue and history
  JobProcessor.swift         decode → rasterize → encode → send
  BluetoothPrinter.swift     IOBluetooth RFCOMM transport
  CUPSQueue.swift            lpadmin registration
  MenuView.swift             menu bar UI
  SettingsView.swift         settings window
Tests/PrintCoreTests/        XCTest suite for PrintCore
scripts/                     build, icon, and LZO verification scripts
```

## Contributing

Issues and pull requests are welcome. Reports from people with other MUNBYN
or TSPL printers are especially useful. Please run `swift test` before you
open a pull request.

## Acknowledgements

- [thermal-label/labelife] by Mannes Brak (MIT) for working out the TSPL
  protocol and printer profiles that the encoder is based on.
- [miniLZO] by Markus F.X.J. Oberhumer, which the LZO1X-1 compressor is
  ported from.

## License

Munbyn Easy Print is free software, licensed under the
[GNU General Public License v2.0 or later](LICENSE). You can use, modify,
and share it. If you distribute a modified version, you must release its
source under the same license.

It includes code derived from LabeLife (MIT) and miniLZO (GPL-2.0-or-later).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

[IPP Everywhere]: https://www.pwg.org/ipp/everywhere.html
[thermal-label/labelife]: https://github.com/thermal-label/labelife
[miniLZO]: https://www.oberhumer.com/opensource/lzo/

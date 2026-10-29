# RaceBox Session Extractor

Download stored RaceBox Mini S recordings over Bluetooth, saving one JSON file
per recording session. Live telemetry is ignored. Device memory is not erased.

```sh
npm install
npm run download
```

Power on the Mini S and disconnect other apps from it before starting. On macOS,
allow Bluetooth access for your terminal when prompted.

Files are written relative to the current directory under
`racebox_sessions/YYYY-MM-DD/session-HH-MM-SS-<GPS timestamp>.json`.
The folder and stable filename use the first point's UTC recording date and time,
not the download date. Complete JSON files (`complete: true`) are left untouched
on later runs. Incomplete or invalid files are downloaded again at the same path.
Older exports in `download-*` directories are left untouched; the first run with
this naming scheme writes a dated copy.

Recording stop/start markers separate sessions; pauses and
resumes remain in the same file. Without boundary markers, the downloaded points
remain together rather than guessing boundaries from time gaps.
The device only supports full-memory downloads, so skipped recordings still
traverse Bluetooth but are not written again. Emoji status messages report
connection progress, saved files, skipped recordings, and the final totals.
Set `RACEBOX_DEBUG=1` to also print raw status/download responses.

Each JSON object contains `session`, a `points` array, `pointCount`, `complete`,
and `endReason`. Points include the calendar date/time, `nanoseconds`, coordinates
in degrees, `altMslM` in meters, `speedKmh`, `headingDeg`, G-forces in g, and
rotation rates in degrees/second. `timestampMs` is GPS time of week in milliseconds,
not a Unix timestamp. `fixStatus` indicates GNSS fix quality.

The script exits automatically when the device acknowledges download completion,
checking that the received point count does not exceed the advertised maximum.
The protocol permits fewer points due to memory alignment and recording pauses.
A zero-point download is reported as an error rather than a successful export.
Memory status is printed for diagnosis.
Security bit 0 means protection is enabled; bit 1 means memory is unlocked.
Ctrl+C, a
disconnect, or a 30-second download timeout finalizes the current file as valid
JSON with `complete: false`. Earlier sessions already closed by recording markers
are retained. Incomplete files contain only the points received so far.
The last session remains incomplete if the device is still recording, allowing
later runs to capture appended points.

For memory protected by a security code, set `RACEBOX_SECURITY_CODE` in the
environment to the device's unsigned 32-bit code. It defaults to zero for
unprotected devices.

## Live Recording

```sh
npm run live
```

The separate live recorder subscribes to live telemetry only and writes each
point directly to disk, without keeping the recording in memory. It sends no
unlock, download, erase, or recording-configuration commands. Standalone
recording does not need to be enabled. Close the RaceBox app or history downloader
before connecting.

Logging waits for a valid 3D GNSS fix (`fixStatus === 3` and the fix-valid flag).
No file is created until then. Logging pauses if the fix is lost and resumes in
the same file when it returns. Incoming no-fix telemetry keeps the connection
watchdog alive while the device acquires satellites.

An emoji dashboard with paired measurement/value/unit tables refreshes in place
up to four times per second in an
interactive terminal, including while acquiring a fix. It shows satellites used
in the solution, fix validity, horizontal/vertical accuracy, PDOP, speed and
heading with accuracy estimates, coordinates, MSL/WGS84 altitude, acceleration,
rotation rates, battery/charging, UTC/time accuracy, and saved/rejected counts.
Position-dependent values stay unavailable until the fix is valid. The display
is clipped to the terminal dimensions; redirected output contains no dashboard
or terminal escape codes. Live JSON points also include these extra diagnostics.
The satellite count is not the number visible or tracked. Per-satellite signal
strength (C/N0) is not provided by the standard live packet; accuracy and PDOP
are not signal-strength measurements.

Output defaults to `racebox_live/YYYY-MM-DD/live-HH-MM-SS-<unique ID>.json`,
using the first point's UTC timestamp. Each run creates a new file, even if the
device timestamp repeats. To choose a path, run `npm run live -- captures/drive.json`.
Existing files are never overwritten.

Press Ctrl+C to finish and close the JSON object. The file contains `source: "live"`,
telemetry `points` with the live diagnostics above, `pointCount`, `complete`,
`invalidFrames`, and `endReason`. The JSON footer is written when recording stops;
the full file is not valid JSON until then. A disconnect or 30 seconds without
live data preserves received points and marks the capture incomplete. Captures
with rejected frames are also marked incomplete. Force-killing the process or
losing power can leave an unfinished JSON file.

Run the hardware-free protocol tests with `npm test`.

Protocol reference: [RaceBox BLE Protocol Description, revision 8](https://github.com/JanSargsyan/react-native-racebox-api/blob/HEAD/RaceBox%20BLE%20Protocol%20Description%20rev%208.pdf).
Tests include the manufacturer's literal telemetry, status, and command examples.
Status, unlock, and download requests have been verified against a Mini S running
firmware 3.6. A nonempty history download still needs hardware verification.

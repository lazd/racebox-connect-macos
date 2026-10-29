# RaceBox Session Extractor

## RaceBox Connect for macOS

A fully native SwiftUI + CoreBluetooth app for RaceBox Mini S. No Node runtime,
JavaScript bridge, or third-party Swift dependencies are used by the app.
Requires macOS 14 or later.

### Website and GitHub Pages

The static website lives in [`docs/`](./docs/) and is deployed by
the [Pages workflow](./.github/workflows/pages.yml). After pushing this repository
to `lazd/racebox-connect-macos`, select **Settings → Pages → Build and deployment →
Source → GitHub Actions**. Push website changes to `main`, or run the workflow
manually, to publish at <https://lazd.github.io/racebox-connect-macos/>.
If the default branch is not `main`, update the workflow's branch filter.

Preview locally with `python3 -m http.server 8000 --directory docs`, then open
<http://localhost:8000>. The site has no build step or runtime dependencies.
All local asset links are relative so they also work under the Pages project path.
Run `node --test src/website.test.js` to check local assets, navigation targets,
screenshots, and latest-release download links.

Download buttons use GitHub's permanent latest-release asset URL. Attach the
build's **`RaceBox Connect.dmg`** (with exactly that name) to each published GitHub
release; no website edit is needed for new versions. Before the first release,
GitHub will return 404 for the download and latest-release links.
The app icon and screenshots are stored in [`docs/assets/`](./docs/assets/).
When updating the UI, replace the screenshots there; avoid including personal
paths, device identifiers, or sensitive recording locations.
The current screenshots use sample recordings and redact device identifiers.

### Build and use the app

```sh
npm run build:mac
open "dist/RaceBox Connect.dmg"
```

Drag **RaceBox Connect** to Applications, launch it, and allow Bluetooth access.
Power on your Mini S, close other RaceBox apps, click **Find RaceBox**, and select
your device. Scanning starts automatically as soon as Bluetooth is ready on
every launch; **Find RaceBox** starts another scan if needed.
The dashboard displays satellites used in the GNSS fix, accuracy,
battery/charging, position, motion, and device-memory status. Individual satellite
identities and signal strengths are not available in the standard RaceBox packet.
Stale telemetry is hidden after three seconds; live data is silenced by the
device during history download and erase.

- **Download Recordings** exports all stored sessions, keeping pause/resume
  points in the same session and separating sessions at recording boundaries.
  A completion dialog shows recording/point totals, the actual saved location,
  and **Show in Finder** to reveal the files. It flags any incomplete recordings;
  automatic memory clearing, if enabled, is reported separately.
- **Start Live Capture** streams directly to disk. Logging waits for a valid
  3D fix and pauses when the fix is lost. **Stop & Save Capture** finalizes it.
- **Recordings** reads saved JSON/CSV files from the chosen download folder,
  including earlier app runs and Node exports. It searches `racebox_sessions`
  and `racebox_live` date folders, plus RaceBox files directly in the selected
  folder. Use **Refresh** after copying files in; the list also refreshes on
  returning to the app, changing folders, and finishing downloads or captures.
  Active output files are excluded until finalized. Unreadable files are
  reported without hiding other recordings. CSV imports without a metadata
  sidecar show completion as unknown.
- Click **View** on a session for an interactive Apple Maps track (satellite or
  standard), start/finish markers, and a Swift Charts G-force graph with
  acceleration/braking (X) and cornering (Y) in g against elapsed time.
  Z is not plotted. Selecting a chart time shows exact readings
  and the corresponding track position. A separate speed-over-time chart shares
  the time selection and uses the selected mph/km/h display units. Session
  summaries show max speed, peak acceleration (+X), peak braking (−X, reported
  as a positive magnitude), and peak cornering (Y).
  Y also shows separate positive- and negative-direction peaks.
  Statistics are calculated from all saved samples, not the reduced
  chart data, and acceleration/braking are stored separately in the loaded
  session model. Export file formats are unchanged.
  Long charts retain extrema from speed and all three G-force axes when reducing
  display samples. JSON no-fix points are excluded from speed statistics and
  break the speed trace rather than implying zero speed. They split track lines
  but keep their motion samples. Apple Maps tiles require internet access; no
  API key is needed and the app does not upload recording files.
- **Start Standalone Recording** / **Stop Standalone Recording** controls
  recording in device memory, separately from live capture. The app unlocks
  memory, reads current configuration, changes only the enable byte, waits for
  acknowledgement, then reads configuration back to verify the result. Existing
  rate/filter settings are preserved. Recording continues after disconnecting;
  starting or stopping is disabled during another operation or live capture.
- **Clear Device Memory** permanently erases device recordings after confirmation.
  Clearing is refused while standalone recording is active.

Stored recording time and capacity are shown as estimated hours/minutes/seconds,
using the device's configured rate (25, 20, 10, 5, or 1 Hz), not an assumed 25 Hz.
These are sample-time estimates: previous rates and recording pauses may differ.
Memory usage refreshes every five seconds while standalone recording is enabled.

Open **RaceBox Connect → Settings…** (Command-comma), or **Preferences** in the
sidebar, to choose a download directory (default `~/Downloads`), JSON/CSV format,
and **Delete after downloading** (off by default). Changes apply to the next
operation. Protected memory can be unlocked with the optional unsigned 32-bit
security code; it is held only in memory until the app quits.

**Units** defaults to **Automatic (locale)**: mph/feet for US and UK measurement
systems, km/h/meters for metric locales. Choose **Metric** or **Imperial** to
override this. Dashboard speed, speed accuracy, altitude, and horizontal/vertical
position accuracy update immediately. G-forces remain in g, angles in degrees,
and recording time in hours/minutes/seconds. JSON and CSV exports keep their
existing km/h and meter units for compatibility.

Enable **Connect automatically** (off by default) to connect on the next launch.
Once Bluetooth is ready, the app scans for three seconds and selects the Mini S
with the strongest valid RSSI (the highest dBm value). Manual selection overrides
the automatic scan. If no device is found, use **Find RaceBox** to try again;
the app does not automatically reconnect after an intentional disconnect.

Automatic deletion requires a nonempty, acknowledged download with a valid
advertised maximum, no rejected frames or file errors, and standalone recording
stopped. Every output is flushed and closed first, and recording status is
checked again before erasing. As in the Node version, the announced record count
is an upper bound, not an exact total. Cancelling, disconnecting, timing out, or
failed verification never initiates an erase. An erase already in progress is
irreversible and may leave memory partially erased if interrupted.

Exports use the first point's UTC date under `racebox_sessions/YYYY-MM-DD/` or
`racebox_live/YYYY-MM-DD/` inside the chosen folder. Native exports include unique
IDs in filenames so existing files are never overwritten. Completed history
downloads are compared with complete exports in the same date folder and selected
format. Exact duplicate point data is discarded, leaving the existing copy
untouched; the completion dialog reports new files and skipped recordings.
JSON comparison ignores key order, session numbering, and completion messages.
CSV comparison requires identical CSV content and a complete metadata sidecar.
Incomplete recordings are retained and downloaded again, and choosing a different
format creates that format's export. The device only supports full-memory
transfers, so duplicate recordings still travel over Bluetooth. Automatic deletion
remains available after a verified transfer when all data is saved or already
present locally; duplicate-check or cleanup failures prevent erasing.
Unreadable existing exports are reported and left untouched without blocking new
saves.
JSON has the same point fields and outer
metadata as the respective Node history/live implementation. Files are written
incrementally; JSON becomes valid when finalized. Interrupted captures and the
last session of an active standalone recording are marked incomplete.
Force-quitting or power loss can leave unfinished JSON.

CSV matches the supplied RaceBox export layout:

```csv
Record,Time,Latitude,Longitude,Altitude,Speed,GForceX,GForceY,GForceZ,Lap,GyroX,GyroY,GyroZ
```

Rows use 1-based records, millisecond ISO-8601 UTC timestamps (including signed
nanosecond correction), MSL altitude in meters, speed in km/h, acceleration in g,
and rotation in degrees/second. `Lap` is always `0` because BLE does not supply
lap numbers. Each CSV has a `.csv.metadata.json` sidecar carrying completion,
point count, and end reason without changing the CSV columns.

### Native build and tests

The npm commands are convenience wrappers around shell and Swift tools; no
`npm install` is needed for native builds. They also work directly:

```sh
bash macos/scripts/build.sh
bash macos/scripts/test.sh
```

For automatic rebuilds, run `npm run watch:mac`, or choose **Tasks: Run Task →
Watch macOS app** in VS Code. The task builds and opens the app immediately,
then watches native sources, package configuration, `Info.plist`, and the build
and icon scripts. Saves are debounced and builds run one at a time; changes
during a build trigger another rebuild. Generated files and website edits do
not trigger native builds.

Each rebuild gracefully quits the app, builds/signs the app bundle without
recreating the DMG, and reopens it. If a capture, download, or erase is active,
the normal quit confirmation still applies; choose **Keep Open** to cancel.
Build or quit failures are shown in the terminal and retried on the next save.
Stop watching with Control-C or **Tasks: Terminate Task**; this leaves an
already-open app running. Use `npm run build:mac -- --app-only` for a one-off
app-only build, or `npm run build:mac` to also create the DMG.

Building requires Swift 5.10 or later (Xcode 15.3+ or recent Command Line Tools).
Tests require full Xcode for XCTest. The test script selects the standard Xcode
installation if Command Line Tools are selected; `DEVELOPER_DIR` can select
another installation. Run `npm run test:mac` for native framing, schema, CSV,
session-boundary, interruption, file-error, deletion-eligibility, saved-file
loading, chart downsampling, memory-duration, and standalone-command tests.

The build produces `dist/RaceBox Connect.app` and `dist/RaceBox Connect.dmg`
for the build Mac's CPU architecture, with a natively drawn multi-resolution
icon and an Applications shortcut in the DMG. The app is locally ad-hoc signed,
not Developer ID signed or notarized; public distribution requires your own
Apple signing/notarization workflow. The in-app mascot uses the same bow-and-Wi-Fi
icon as the application, loaded directly from the bundled artwork rather than
the system icon cache. Launching also sets the Dock icon from that artwork.
After rebuilding, quit any running copy and open `dist/RaceBox Connect.app` to
see the updated icon. Device recording settings only change when explicitly
starting/stopping standalone recording; rate and filter settings are preserved.
Hardware-free tests do not replace verification on a physical Mini S, especially
for history download, standalone start/stop, protected-memory access, and
destructive erase operations.

## Node command-line tools

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

## Clear Device Memory

```sh
npm run erase
```

This permanently deletes **all recordings on the first RaceBox Mini S found**.
Download recordings first and close other RaceBox connections. Local exports
are never deleted. The command requires an interactive terminal and typing
`ERASE` before Bluetooth scanning starts; any other answer cancels.

The recorder must be stopped, not paused. Protected devices use
`RACEBOX_SECURITY_CODE` as above; locked memory is refused. The command displays
erase progress, waits for the completion acknowledgement, then checks that the
stored record count is zero before reporting success. Keep the device powered
on: an erase already sent cannot be undone, and interruption or disconnection
can leave memory partially erased. Erase progress has a 180-second inactivity
timeout; connection and other command waits time out after 30 seconds.

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

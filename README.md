# NETCAP — Net Message Capture & Bottleneck Finder for Garry’s Mod

NETCAP is a lightweight network capture and bottleneck profiler for Garry’s Mod that records both incoming `net.Receive` traffic and outgoing `net.*` sends. It prints clear top-lists to console and writes a structured JSON report (including estimated “wire bytes”) so you can pinpoint spammy messages, oversized payloads, and bandwidth hotspots.

## Why NETCAP

When a server feels “laggy” or players report stutters, the root cause is often a small set of net messages:
- sent too frequently,
- too large,
- or broadcast to too many recipients.

NETCAP helps you answer:
- **Which net strings are the biggest offenders?**
- **Is the bottleneck incoming (`net.Receive`) or outgoing (`net.Send` / `net.Broadcast` / PVS/PAS)?**
- **Which player is spamming messages (server-side incoming view)?**
- **What’s the estimated bandwidth impact (“wire bytes” = payload × recipients)?**

## Key Features

- **Incoming profiling**: wraps `net.Receive` receivers and aggregates total bytes + count + max.
- **Outgoing profiling**: tracks payload size and estimates wire cost per send:
  - `net.Send`, `net.Broadcast`, `net.SendOmit`, `net.SendPVS`, `net.SendPAS` (server)
  - `net.SendToServer` (client)
- **Future-safe receiver capture**: patches `net.Receive` so receivers registered *after* capture starts are included.
- **Per-player incoming breakdown (server)**: quickly identify who is spamming which net strings.
- **JSON reports**: outputs detailed results to `data/netcap/` for offline analysis.
- **Auto-stop**: optionally stop after N seconds for controlled profiling sessions.
- **Safe restore / reload**: cleanly unpatches and restores original functions.

## Installation

### Server-side (recommended)
1. Create the file:
   - `garrysmod/lua/autorun/server/netcap.lua`
2. Paste the script contents.
3. Restart the server (or `lua_openscript` it).

### Client-side (optional)
You can also run it client-side to profile:
- incoming messages from the server
- outgoing `net.SendToServer`

Place it in:
- `garrysmod/lua/autorun/client/netcap.lua`

> Tip: Most bottleneck hunting is done **server-side** first.

## Usage

### Commands
- `netcap_start [seconds]`  
  Starts capturing. If `seconds` is provided, NETCAP auto-stops after that time.

- `netcap_status`  
  Prints a short summary while capture is running.

- `netcap_stop`  
  Stops capturing, prints top lists, and writes a JSON report.

### Typical workflow
1. Start a short capture window:
   - `netcap_start 20`
2. Reproduce the issue (open menus, spawn entities, run the problematic addon, etc.)
3. Let it auto-stop or manually:
   - `netcap_stop`
4. Inspect console output and the report in:
   - `garrysmod/data/netcap/*.json`

## Output & Metrics

NETCAP records:

### Incoming (Receive)
- **total bytes**
- **message count**
- **max message size**
- **avg bytes/message**
- **rate** (bytes/sec over capture window)

> Note: In GMod net receivers the `len` parameter is in **bits**; NETCAP converts it to bytes via `ceil(bits/8)`.

### Outgoing (Send)
- **payload bytes**: size of the message once per send call
- **wire bytes (estimated)**: `payload bytes × recipients`
  - Broadcast and PVS/PAS recipient counts are estimated using `RecipientFilter()`.
- **send types**: counts by send method (`Send`, `Broadcast`, `SendPVS`, etc.)

### Server-only: By Player (Incoming)
- Top players by total incoming bytes
- Per-player breakdown by net string (useful for spam detection)

## Interpreting Results

A few common patterns:

- **High outgoing wire bytes + Broadcast-heavy**
  - Large payloads being sent to everyone. Consider:
    - sending only to relevant clients (PVS/PAS),
    - compressing payloads,
    - reducing frequency.

- **High incoming bytes from a single player**
  - Client spam (intentional or buggy). Consider:
    - rate limiting,
    - validating inputs,
    - removing expensive server-side handlers.

- **High count but low bytes**
  - Too many tiny messages. Consider batching or lowering send frequency.

## Performance Notes

NETCAP is designed for short profiling sessions:
- Wrapping net receivers adds overhead.
- Tracking outgoing sends touches `net.Start`/`net.*` send functions.

For best results:
- capture in **short windows** (10–30 seconds),
- reproduce the issue reliably,
- stop and inspect.

## Safety / Compatibility

- NETCAP uses `pcall` inside wrapped receivers to avoid breaking net handling if a receiver errors.
- It restores original functions on stop and provides a `NETCAP.Shutdown()` helper for safe reloads.
- Some recipient counts are estimates (especially PVS/PAS), but they’re typically good enough to highlight bottlenecks quickly.

## Data Files

Reports are written to:
- `garrysmod/data/netcap/netcap_YYYY-MM-DD_HH-MM-SS_sv.json`
- `garrysmod/data/netcap/netcap_YYYY-MM-DD_HH-MM-SS_cl.json`

The JSON includes:
- totals
- incoming/outgoing ranked lists
- server-only per-player breakdown

## License

Choose a license that fits your project. (MIT is common for small tooling utilities.)

## Credits

Built for practical profiling during real GMod performance investigations—focused on actionable signal rather than noisy logs.

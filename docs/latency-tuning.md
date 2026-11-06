# Latency: budget, measurement and tuning

Status: analysis only (task 6.3). **No number in this document has been measured.** Every figure
is an estimate from reading the code at commit `c6f0ff8` plus general knowledge of the platforms;
the job of section 2 is to replace them with real measurements. Line numbers refer to `c6f0ff8`
(adaptive-bitrate work, `BitrateController`, was in progress and uncommitted while this was written).

Pipeline in one line: ScreenCaptureKit (30 fps, NV12, ≤1920 long side) → VideoToolbox H.264 High,
low-latency rate control, 6 Mbps, 2 s GOP → main-actor `Task` → `StreamServer.queue` →
`ClientSendGate` (≤ 8 frames) → `NWConnection` (TLS 1.3 / TCP, `TCP_NODELAY`) → network →
`StreamLink` (256 KB reads) → `VideoRenderer` → `AVSampleBufferDisplayLayer` (`DisplayImmediately`).

---

## 1. Latency budget (all estimates)

"One-way" = screen change on the Mac to changed pixels on the iPhone 12 (60 Hz panel).
Assumed sizes: a P-frame at 6 Mbps / 30 fps averages 6,000,000 / 8 / 30 ≈ **25 KB** (arithmetic);
an IDR of a 1080p desktop is assumed **100–300 KB** (estimate, not measured; see follow-up F2).

| # | Stage | What the code does | LAN (Wi-Fi) | Tailscale direct | Tailscale DERP relay | Kind |
|---|-------|--------------------|-------------|------------------|----------------------|------|
| 1 | Capture interval | `minimumFrameInterval = 1/30` (`ScreenCapturer.swift:65`), `queueDepth = 3` (`:34`, `:67`). A change waits for the next sample. | 0–33 ms (avg ~17) | same | same | estimate |
| 2 | Capture/compose → callback | SCK delivers `.complete` frames only (`:115-123`) on a `.userInteractive` queue (`:96`) | 2–8 ms | same | same | estimate |
| 3 | Encode | HW encoder, `EnableLowLatencyRateControl`, `RealTime`, no reordering, `PrioritizeEncodingSpeedOverQuality` (`CompressionSessionFactory.swift:19-22, 82-94`) | 3–10 ms | same | same | estimate |
| 4 | Host hand-off | VT callback → unbounded `AsyncStream` → `Task` **on the main actor** (`StreamingPipeline.swift:37`) → `server.broadcast` → `queue.async` (`StreamServer.swift:106-119`) | <1 ms typical, spikes if main thread busy | same | same | estimate |
| 5 | Packetise + TLS | 14-byte header + payload copy (`FrameEncoder`), TLS 1.3 records (≤16 KB), `noDelay = true` (`TLSParameters.swift:78-83`) | <1 ms | <1 ms (+WireGuard encrypt) | <1 ms | estimate |
| 6 | Serialisation of one frame on the bottleneck link | P ≈ 25 KB, IDR 100–300 KB | P 1–3 ms, IDR 5–25 ms | P 4–15 ms, IDR 30–120 ms | P 10–60 ms, IDR 100–500 ms | estimate |
| 7 | Propagation (≈ RTT/2) | — | 1–5 ms (Wi-Fi power-save jitter can add 10–30) | 5–40 ms | 20–150 ms (detour via relay region) | estimate |
| 8 | Queueing (host gate + TCP send buffer + network) | Gate allows 8 frames ≈ 267 ms at 30 fps (`ClientSendGate.swift:18-19`); kernel TCP buffer on top (see finding F-A) | ~0 when uncongested | 0–100+ ms | 0–1000+ ms under loss | estimate |
| 9 | Receive + decode | `receive(minimumIncompleteLength: 1, maximumLength: 256 KB)` (`StreamLink.swift:100`, `StreamClient.swift:20`), HW decode in the layer | 2–8 ms | same | same | estimate |
| 10 | Display | `DisplayImmediately = true` (`SampleBufferFactory.swift:142`), no timebase; wait for 60 Hz vsync + composition | 8–33 ms | same | same | estimate |
| | **Total, steady state, P-frames** | | **~40–100 ms** | **~60–170 ms** | **~120–400+ ms** | estimate |

Takeaways (still estimates): on LAN the budget is dominated by fixed clocks (capture interval +
display vsync ≈ 25–50 ms) rather than the network; on Tailscale the network terms (6–8) dominate,
and the largest single risk is queueing (row 8), not raw RTT.

---

## 2. How to measure on real devices

### 2a. The in-app overlay ping (what it is and is not)

How it works (verified in code): once per second `StreamClient.sampleStats()` sends a `.ping`
frame stamped with the phone's monotonic clock (`StreamClient.swift:242-245`,
`MonotonicClock.swift:8-10`); the Mac echoes it unchanged through the same gate and send queue as
video (`StreamServer+Frames.swift:12-14`); the phone computes `now − stamp` on arrival
(`StreamLink.swift:132-150`). The overlay shows **only the latest sample**, no min/avg/jitter
(`StatsCollector.swift:30-31`), and since the snapshot is taken right after sending, it displays
the previous second's ping.

It **includes**: phone→Mac uplink, Mac TCP/TLS receive, `StreamServer.queue`, the echo's wait
behind every video frame already handed to `NWConnection` and in the Mac's TCP send buffer,
Mac→phone downlink, and the phone receiving any video bytes queued ahead of it on the stream.

It **excludes**: capture interval, encode, the main-actor hop, decode and display (rows 1–4, 9–10).
It is a *network + host-queue RTT*, not glass-to-glass. Because the echo queues behind video, a
ping that climbs while the network RTT (`tailscale ping`) stays flat means **bufferbloat in our
own send path** — this is its most useful diagnostic.

Procedure: watch it for 60 s per scenario; note the typical and worst value. Move a window
continuously during part of the run (video load) and leave the screen still for the rest (idle
screen = almost no video, so ping ≈ pure network RTT).

### 2b. Glass-to-glass with a slow-motion video

1. The Mac needs a real monitor (an HDMI dummy plug cannot be filmed).
2. On the Mac, show a fast-changing reference, e.g. in Terminal:
   `python3 -c 'import time,sys
   while True: sys.stdout.write("\r%.3f" % time.time()); sys.stdout.flush(); time.sleep(0.001)'`
   (or any millisecond stopwatch web page). Make the text large.
3. Connect the iPhone 12 and place it next to the monitor so both screens fit in one frame.
4. Film both with a second phone in **240 fps slow-mo** (1 frame = 4.17 ms).
5. Method A (clock): pause on several frames; latency ≈ monitor reading − phone reading. Accuracy
   is limited by the 60 Hz refresh of both screens (± ~17 ms per reading); average ≥ 10 readings.
6. Method B (event, more precise): with nothing else moving, trigger a sharp change (press a key
   that switches a full-screen window from black to white, or `Cmd-Tab` between a black and a
   white app). In the video, count frames from the first changed frame on the monitor to the first
   changed frame on the phone; × 4.17 ms. Repeat ≥ 20 times; report median and worst.
7. Caveat: the Mac monitor has its own input lag (typically 5–20 ms, unknown for yours), and
   ScreenCaptureKit captures before scan-out, so this method **under-reports** true capture-to-phone
   latency by roughly that amount. It is still the right number for "how laggy does it feel".
8. Also measure with the phone driving the Mac (tap to move a window) for a rough input-to-photon
   figure; that adds the phone→Mac input path and `CGEvent` injection.

### 2c. Which path is Tailscale using?

On the Mac (App Store Tailscale's CLI lives at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`):

```sh
tailscale status                 # peer line ends in "direct <ip:port>" or "relay \"<region>\""
tailscale ping -c 10 <iphone>    # "via <ip>:<port>" = direct, "via DERP(<region>)" = relay
tailscale netcheck               # UDP reachability, NAT type, nearest DERP latencies
networksetup -listallhardwareports           # which interface is Wi-Fi vs Ethernet
networksetup -getinfo Wi-Fi                  # Mac's LAN address (compare with the overlay's address)
ifconfig | grep -B2 -A2 'inet 100\.'         # the Tailscale utun interface and its MTU
```

Run `tailscale ping` **before and after** each test: a path can upgrade from DERP to direct
mid-session. To force relay for a test, put the phone on cellular behind a strict NAT, or block
UDP on the Mac's router temporarily. On the iPhone the Tailscale app shows the same per-peer info.

### 2d. Logs (subsystem/category names verified)

`AppLog` uses the bundle ID as subsystem (`AppLog.swift:9-15`; IDs from `project.yml:44,69`):
host `com.alifu.lfremac.host`, iPhone `com.alifu.lfremac.client`.

```sh
log stream --level info --predicate 'subsystem == "com.alifu.lfremac.host" && category IN {"capture","encoder","pipeline","server"}'
```

Lines worth watching: `Created H.264 encoder (hardware low-latency)` (confirms low-latency mode;
`(default (hardware preferred))` means it fell back), `Encoder ignored <key>` (a tuning key was
rejected), `Client is falling behind; dropping video until next keyframe` (gate tripped). For the
iPhone use Console.app with the device selected, subsystem `com.alifu.lfremac.client`, categories
`link`, `renderer`, `client`. For CPU/GPU time, Instruments' *Time Profiler* and *Metal System
Trace* on the host; no custom signposts exist yet (follow-up F2).

### 2e. Results template

| Scenario | Path check (`tailscale ping`) | Overlay RTT idle (typ / worst) | Overlay RTT moving (typ / worst) | Overlay fps / Mbps | Glass-to-glass median / worst (n) | "Falling behind" logs per min | Notes |
|---|---|---|---|---|---|---|---|
| LAN Wi-Fi (Mac Ethernet) | n/a | | | | | | |
| LAN Wi-Fi (both Wi-Fi) | n/a | | | | | | |
| Tailscale direct | via ip:port | | | | | | |
| Tailscale DERP relay | via DERP(…) | | | | | | |
| Cellular → Tailscale | | | | | | | |

---

## 3. Findings from the code (ranked by expected impact)

**F-A. The gate only sees frames *above* TCP; the kernel send buffer is unbounded latency. High impact, medium cost.**
`pendingSends` is decremented on `.contentProcessed` (`StreamServer+Frames.swift:41-44`), which
for TCP means the stack has accepted the bytes, not that the phone received them (Apple's
semantics; behaviour under load not yet verified on device). Once the link slows, bytes pile up
in the TCP send buffer (auto-tuned, can be hundreds of KB–MBs = seconds at 6 Mbps) *before* the
gate's 8-frame limit trips. Network.framework exposes no `TCP_NOTSENT_LOWAT` (checked
`NWProtocolTCP.Options` in the macOS 26.5 SDK: only `noDelay`, `noPush`, keepalive, MSS, timeouts,
`disableAckStretching`, `enableFastOpen`, `disableECN`, …). It does expose
`NWProtocolTCP.Metadata.availableSendBuffer` (read-only). Fix: application-level acks — the phone
returns the frame timestamp after enqueueing it, and the gate counts *unacknowledged* frames (or
milliseconds) instead of unprocessed sends. Cheap first step: log `availableSendBuffer` once per
second to confirm the hypothesis.

**F-B. After a congestion drop the requested keyframe is usually dropped too → freeze up to one GOP (2 s). High impact, cheap.**
`ClientSendGate.decideVideo` (`ClientSendGate.swift:44-50`) returns `.dropAndRequestKeyframe` only
on the *first* drop; later drops while still backed up return plain `.drop`. The forced IDR arrives
~1 frame later, while `pendingSends` is almost certainly still ≥ 8, so it is dropped with no new
request. The phone receives nothing, so `VideoRenderer` never asks either (`VideoRenderer.swift:78-81`
only fires when a non-key frame arrives). Recovery therefore waits for the next periodic IDR
(≤ 2 s). Fix: when the backlog drains below a threshold while `isWaitingForKeyframe`, request one
keyframe (e.g. `sendCompleted()` returns a "request keyframe now" decision). Add a test in
`MacHostTests/ClientSendGateTests.swift`. This must land before lengthening the GOP (F-E).

**F-C. `maxPendingFrames = 8` (≈ 267 ms at 30 fps) is deep for interactive use. Medium-high, trivial.**
`ClientSendGate.swift:18-19`. For a remote desktop, ~100–130 ms of host-side queue is a better
ceiling: 4 frames at 30 fps, 6–8 at 60 fps. Better still, express it in time
(`maxPendingMilliseconds`) so it does not change meaning with fps. Lowering it alone causes more
drops on bursty Wi-Fi, which is only acceptable once F-B is fixed (otherwise each drop = up to 2 s
freeze). Note pings also count as pending (`ClientSendGate.swift:34-35`) — harmless.

**F-D. Keyframe size spikes vs `DataRateLimits` over a 1-second window. Medium, cheap.**
`DataRateLimits = [peakBytesPerSecond, 1]` = 1,125,000 bytes per 1 s (`CompressionSessionFactory.swift:92`,
`EncodedVideoEvent.swift:51-54`). A 1 s window does not bound a single frame, so an IDR can be many
times a P-frame and arrive as one burst: estimated +30–120 ms on Tailscale direct, more on DERP,
every 2 s (finding F-E) and after every drop. The SDK header (`VTCompressionProperties.h`,
"Ultra-low-latency conferencing" recommendations) says `DataRateLimits` may be used with
low-latency rate control and that it is a hard cap that "may be used … to establish hard limits
over a smaller window". Try adding a short window, e.g. `[peak/10, 0.1]` (pairs in one array), and
consider `kVTCompressionPropertyKey_MaxAllowedFrameQP` to keep quality floors sane. Unverified:
how the M1 low-latency encoder trades IDR quality for size under a 100 ms window — measure IDR
bytes and visual quality (F2).

**F-E. 2 s periodic GOP. Medium, trivial (after F-B).**
`keyframeIntervalSeconds: 2` (`EncodedVideoEvent.swift:35`) → an IDR spike every 60 frames.
TCP is reliable and the phone/host already request IDRs on demand (`StreamServer+Connections.swift:59`,
`VideoRenderer.swift:114-118`), so periodic IDRs mainly serve as the *de facto* recovery path for
F-B. Once F-B is fixed, 10 s (or longer) is reasonable; keep some periodic IDR as a safety net.

**F-F. Encoded frames hop through the main actor. Low-medium (jitter), cheap.**
`StreamingPipeline` is `@MainActor`, so `Task { for await event in encoder.events { sink(event) } }`
(`StreamingPipeline.swift:37`) inherits main-actor isolation: every encoded frame waits for the
main thread (SwiftUI menu, `HostSession` event loop, input injection) before reaching the server
queue. The `AsyncStream` is unbounded (`H264Encoder.swift:11-12, 38`), so a main-thread stall
becomes invisible queueing the gate cannot see. Fix: `Task.detached`, or call `sink` directly from
the VideoToolbox output handler (it is already `@Sendable` and `broadcast` just does `queue.async`).

**F-G. 30 fps capture. Medium on LAN, trivial knob (bitrate cost).**
`CaptureSettings.default` (`ScreenCapturer.swift:23`). At 60 fps the average wait for the next
sample drops from ~17 to ~8 ms and each frame is smaller (shorter serialisation), at roughly
1.3–1.6× the bitrate for similar quality (estimate). The iPhone 12 panel is 60 Hz, so 60 fps is
the useful maximum. SCK only delivers frames on change, so an idle desktop stays cheap.

**F-H. TCP head-of-line blocking on Tailscale. Situational, expensive to remove (section 4).**
Over Tailscale, our TCP rides inside WireGuard/UDP. A lost packet stalls *every later byte* until
it is retransmitted: about one extra RTT with fast retransmit, an RTO (commonly hundreds of ms) for
tail or burst loss; congestion-window cuts then back the queue up into F-A/F-B. Tailscale's
default MTU (1280; check with `ifconfig`) also means more packets per frame. On **DERP** the relay
hop itself is TCP (HTTPS), so the path is already TCP-over-TCP and UDP/QUIC on our side would not
remove HOL blocking there.

**F-I. Things that are already right (no change needed).**
`TCP_NODELAY` on (`TLSParameters.swift:80`); `AllowFrameReordering = false` and `RealTime = true`
(`CompressionSessionFactory.swift:83-84`) so no B-frame delay; hardware low-latency encoder tried
first (`:19-22`); `DisplayImmediately` with no timebase pacing (`SampleBufferFactory.swift:142`);
receive with `minimumIncompleteLength: 1` (`StreamLink.swift:100`, `StreamServer+Connections.swift:89`);
`.userInteractive` queues on both sides; capture handler encodes inline with no extra copy.
TLS record size (16 KB) costs at most one record's serialisation once per frame (< 7 ms even at
20 Mbps) since the whole access unit is needed before decode anyway — not worth tuning.
`kVTCompressionPropertyKey_MaxFrameDelayCount` is not set; with `RealTime` + no reordering it
should already be minimal, but setting it to 0 in the optional list is free insurance (it is
logged, not fatal, if rejected).

| Rank | Finding | Impact | Cost |
|---|---|---|---|
| 1 | F-B keyframe re-request after drain | High (2 s freezes) | Cheap |
| 2 | F-A count unacked frames, not unprocessed sends | High under congestion | Medium |
| 3 | F-C gate depth 8 → ~120 ms worth | Medium-high | Trivial (after F-B) |
| 4 | F-D short `DataRateLimits` window | Medium | Cheap |
| 5 | F-E GOP 2 s → 10 s | Medium | Trivial (after F-B) |
| 6 | F-F main-actor hop | Low-medium | Cheap |
| 7 | F-G 60 fps on LAN | Medium on LAN | Trivial |
| 8 | F-H TCP HOL blocking | Situational | Expensive |

---

## 4. TCP vs UDP/QUIC

**Verdict: stay on TLS 1.3 over TCP now.** Fix F-A/F-B/F-C first; they target the same symptom
(queueing after loss) at a fraction of the cost.

Why: on LAN, loss is rare and TCP adds nothing measurable. On Tailscale DERP the relay is TCP
anyway. Only Tailscale-direct with real packet loss benefits from UDP, and only if the
application then *drops* late data instead of retransmitting it — which requires a new video
transport (fragmentation of 25–300 KB frames into ~1200-byte datagrams, NACK or FEC, reassembly,
frame-level drop, pacing, congestion control).

Criteria that would justify moving video to UDP/QUIC datagrams (measure with section 2):
- Tailscale direct is the common path (`tailscale ping` shows `via ip:port` most of the time), **and**
- after F-A–F-C, the overlay ping (moving screen) on Tailscale direct shows p90 spikes > ~150 ms
  above idle RTT at least once a minute, or glass-to-glass p90 > ~250 ms, **and**
- those spikes correlate with loss/retransmits (`netstat -s -p tcp` retransmit counters rising
  during the test), not with bitrate exceeding the link (that is fixed by bitrate, not transport).

What moving would cost:
- Network.framework supports QUIC (`NWProtocolQUIC.Options`, with `isDatagram` and
  `maxDatagramFrameSize`) and DTLS (`NWParameters(dtls:udp:)`) — verified in the SDK. Both expose
  `securityProtocolOptions`, so the identity/verify-block setup in `TLSParameters.parameters`
  could likely be reused. Unverified: mutual client-certificate auth over Network.framework QUIC,
  and ALPN requirements; prototype before committing.
- `TLSParameters.peerFingerprint(of:)` reads `NWProtocolTLS` metadata (`TLSParameters.swift:35-40`);
  QUIC would need its own metadata path, and the defence-in-depth check in `StreamLink` (`:74-79`)
  and the server's role assignment would need re-testing. Pairing, rate limits and
  `NetworkPolicy` would be re-reviewed for a new socket type.
- The 14-byte framing assumes a byte stream (`FrameDecoder`). Datagrams need a new fragment header
  and loss handling; control traffic (input, pairing, keyframe requests) should stay on a reliable
  stream (a QUIC stream, or keep the TCP connection).
- Realistic scope: a multi-week project plus a security re-review. A cheaper middle ground, if
  needed: keep TCP for control, add a *separate* QUIC connection (datagrams) for video only.

---

## 5. HEVC

**Verdict: stay on H.264 for now.** Revisit only if, after the fixes above, relay/cellular is
bandwidth-bound (overlay Mbps pinned at the cap while quality is poor).

Pros: M1 Mac mini has a hardware HEVC encoder and the iPhone 12 (A14) decodes HEVC in hardware,
so both ends are capable. HEVC typically saves roughly 25–40 % bitrate at equal quality for camera
content (industry rule of thumb; **unmeasured for desktop/text content**, where H.264 High with
8×8 transforms is already decent). Smaller frames → shorter serialisation and smaller IDR spikes,
which matters most on DERP/cellular.

Cons / risks:
- Low-latency mode: `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` was introduced for
  H.264; the macOS 26.5 SDK header does not state which codecs support it. HEVC support on the
  M1/macOS 14+ is **unverified**. Worse, `CompressionSessionFactory.createSession` silently falls
  back to the non-low-latency spec (`CompressionSessionFactory.swift:23-25, 58-72`), so an HEVC
  attempt could quietly add encoder-side buffering. Any HEVC trial must log which spec won and
  compare encode time.
- Encode latency per frame is likely similar on M1 hardware (unverified); no benefit there.
- Compatibility: the whole pipeline is H.264-specific — codec type (`CompressionSessionFactory.swift:62`),
  profile (`:88`), parameter-set extraction via `CMVideoFormatDescriptionGetH264ParameterSetAtIndex`
  (`MacHost/Encoding/AnnexB.swift:38,55`), NAL-type parsing with a 5-bit mask
  (`RemoteCore/Video/AnnexB.swift:16-27`; HEVC uses a 2-byte header and VPS/SPS/PPS), the client's
  `CMVideoFormatDescriptionCreateFromH264ParameterSets` (`SampleBufferFactory.swift:103`), and
  the protocol, which has no codec field (`Frame.swift:5`).

Code that would change: codec + profile in the factory; an HEVC variant of the host `AnnexB`
parameter-set extraction; HEVC NAL types in RemoteCore `AnnexB`; HEVC format-description creation
in `SampleBufferFactory`; a codec indicator in `videoConfig` (new `MessageType` or flag, with the
phone advertising support); tests for each. Moderate (a few days), but only worth it with data.

---

## 6. Recommended presets and follow-ups

Selection: the host already classifies the peer address (`NetworkPolicy.swift:35-53`: private
ranges vs `100.64.0.0/10` / `fd7a:115c:a1e0::/48`). Use LAN vs Tailscale from that. Direct vs
DERP is invisible to the app (same Tailscale IP), so start Tailscale sessions at the "direct"
preset and let the in-progress `BitrateController` cut toward the relay values on congestion.

| Preset | Long side | fps | Avg bitrate | Peak (`DataRateLimits`) | GOP | Gate depth | Reasoning |
|---|---|---|---|---|---|---|---|
| LAN | 1920 | 60 | 12 Mbps | 1.5× per 1 s **and** ~1.5 MB/s-equivalent per 0.1 s | 10 s* | ~120 ms (8 frames at 60 fps) | Wi-Fi has headroom; 60 fps cuts ~8 ms average capture wait and matches the 60 Hz panel. |
| Tailscale direct | 1920 | 30 | 6 Mbps (floor 1.5) | 1.5× per 1 s and per 0.1 s | 10 s* | ~130 ms (4 frames) | Uplinks of home connections vary; keep today's bitrate, cut queue depth. |
| Tailscale relay / cellular | 1280 | 30 | 2.5 Mbps (floor 1) | 1.3× per 0.1 s | 10 s* | ~100 ms (3 frames) | DERP/cellular throughput is low and variable; smaller frames shrink IDR bursts. |

\* only after follow-up F1 (keyframe re-request) lands; until then keep 2 s.

Concretely in code: `CaptureSettings(framesPerSecond:maxLongSide:)` (`ScreenCapturer.swift:22-27`),
`H264EncoderSettings(averageBitRate:framesPerSecond:keyframeIntervalSeconds:peakBitRateRatio:)`
(`EncodedVideoEvent.swift:31-55`, plus a new short-window field), and
`ClientSendGate(maxPendingFrames:)` (`ClientSendGate.swift:26`). These are starting points to be
validated with the section 2e table, not tuned values.

### Prioritised follow-up tasks

1. **F1 — Re-request keyframe after backlog drains** (`MacHost/Transport/ClientSendGate.swift`,
   `StreamServer+Frames.swift`, `MacHostTests/ClientSendGateTests.swift`). Fixes up-to-2 s freezes (F-B).
2. **F2 — Instrument the pipeline**: log IDR/P byte sizes and encode time per second, `pendingSends`
   high-water mark and `NWProtocolTCP.Metadata.availableSendBuffer`; add `OSSignposter` intervals
   for capture→encoded→sent (`H264Encoder.swift`, `StreamServer+Frames.swift`). Turns this
   document's estimates into measurements.
3. **F3 — Gate depth in milliseconds, default ~120 ms** (`ClientSendGate.swift`, tests) (F-C).
4. **F4 — Move the forwarding loop off the main actor** (`StreamingPipeline.swift`) (F-F).
5. **F5 — Short-window `DataRateLimits` + `MaxFrameDelayCount = 0`** in the optional property list
   (`CompressionSessionFactory.swift`, `EncodedVideoEvent.swift`); check `Encoder ignored` logs (F-D).
6. **F6 — Overlay min/avg/max ping over 10 s** instead of the last sample (`StatsCollector.swift`,
   `StreamStats.swift`) so section 2a readings are less noisy.
7. **F7 — Application-level frame acks** so the gate measures delivered, not accepted, frames
   (`Frame.swift` new message type, `VideoRenderer.swift`/`StreamLink.swift`, `ClientSendGate.swift`) (F-A).
8. **F8 — Per-network presets** chosen from the peer address (`StreamingPipeline.swift`,
   `HostSession.swift`, `NetworkPolicy.swift` classification helper); then GOP 10 s and 60 fps on LAN.
9. **Later, only with data:** HEVC trial behind a flag (section 5); UDP/QUIC video (section 4).

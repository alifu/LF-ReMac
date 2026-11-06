# Keeping the Mac reachable

LF-ReMac only works while the Mac is awake, on a network the iPhone can reach, and the app is running.

## What the app does
- **Keep Mac Awake While Hosting** (menu, on by default). While you are hosting, the app holds a
  "prevent idle system sleep" assertion. The *display* may still turn off; the Mac does not sleep.
  Check with `pmset -g assertions` (look for "LF-ReMac is hosting a remote session").
- **Allow Tailscale Connections** (menu, off by default). Without it only your local network
  (private IPv4, link-local and unique-local IPv6) can connect. With it, Tailscale addresses
  (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) are accepted as well. Public internet addresses are
  always refused, even if a router forwards the port.
- Pairing, TLS 1.3 and the paired-device list still apply on every network.

## Mac settings to check
1. **System Settings → Battery/Energy**: turn on "Prevent automatic sleeping on power adapter when the
   display is off" (Mac mini: "Wake for network access"). The app's assertion covers idle sleep, but a
   manual Sleep, closing a laptop lid or an Energy schedule still sleeps the Mac.
2. Optional, from Terminal: `sudo pmset -a sleep 0 displaysleep 10 womp 1` (never idle-sleep, display
   off after 10 min, wake for network access). Revert with `sudo pmset -a sleep 1`.
3. **Lock screen**: the Mac may lock while the display is off. The stream then shows the lock screen
   and you can type your password with the remote keyboard. Screen Recording and Accessibility
   permissions keep working while locked. To avoid the password prompt on a Mac only you can reach,
   you can lengthen *Require password after screen saver begins*, at the cost of physical security.
4. **FileVault**: after a reboot the Mac stops at the disk-unlock screen before the app can start, so
   it cannot be reached remotely until someone unlocks it once.

## Waking a sleeping Mac (Wake-on-LAN)
The iPhone can wake a sleeping Mac with the **Wake** button on the Mac's entry in the iPhone app.
- **Setup on the Mac:** turn on "Wake for network access" (see *Mac settings to check*). An Ethernet
  connection is the most reliable; Wi-Fi wake depends on the Mac model.
- **Learn the Mac once:** connect to the Mac from the iPhone while it is awake. The Mac tells the iPhone
  its hardware (MAC) addresses, and the iPhone saves them with the pairing. Without that the button
  says to connect once first.
- **Same network only:** the wake signal is a broadcast on the Wi-Fi network the iPhone is on. It cannot
  cross Tailscale or the internet. The Mac can take several seconds to wake; then connect as usual.
- Checked on a real iPhone that the signal can be sent from a free developer account. Waking an actual
  sleeping Mac mini is still to be confirmed on your own network.

## Headless Mac mini (no monitor)
With no display attached macOS may give a missing or tiny screen, and apps that need a display behave
badly. Plug an **HDMI (or DisplayPort/USB-C) dummy plug** into the Mac mini: it makes macOS see a
normal monitor, so the stream has a proper full-size picture. A built-in virtual display was tried
and rejected: it relies on a private macOS API and could not be re-created reliably while the app keeps
running (see the Phase 7 notes in the plan).

## Choosing a display
If the Mac has more than one display, a display button appears in the stream toolbar on the iPhone.
The choice is remembered per iPhone. If the chosen display is unplugged, the stream falls back to the
main display and returns when it is plugged in again.

## Sound
Sound from the Mac is **off by default**. Tap the speaker button in the stream toolbar to turn it on;
the choice is remembered for each Mac. It plays what the Mac plays (not the Mac's microphone), without
this app's own sounds. Audio is sent only while it is on, so muting saves CPU and data.
- It is kept close to the picture on purpose (about 40 ms buffered); on a poor connection you may hear
  short gaps instead of a growing delay.
- Update the **Mac app first**, then the iPhone app: an older Mac app drops the connection when it gets
  the newer iPhone's greeting.
- On a Mac mini with no speakers or monitor audio, the dummy plug above also gives macOS an output
  device. Whether sound is captured with no output device at all is not yet confirmed; if the speaker
  button gives silence, try the dummy plug.

## Start at login
Add the app in **System Settings → General → Login Items** ("Open at Login"), then open it once and
choose **Start Hosting**. Hosting does not start by itself, by design.

## Checks
- `pmset -g assertions | grep LF-ReMac` shows the assertion while hosting and nothing after "Stop Hosting".
- Leave the Mac idle overnight, then connect from the iPhone in the morning.

## Can't connect over Tailscale
Work through these in order. The Mac is the same in every case: it listens on port 47800 on all
interfaces and accepts Tailscale addresses only when **Allow Tailscale Connections** is on.

1. **Mac settings.** *Allow Tailscale Connections* is on, and the Mac is hosting (**Start Hosting**).
   `tailscale status` on the Mac lists the iPhone and shows the Mac as online.
2. **Saved address.** The iPhone does not find Tailscale addresses by itself (Bonjour only works on
   the same Wi-Fi). Swipe the Mac's row, tap **Set Address…**, and enter the Mac's Tailscale IP
   (`tailscale ip -4`, starts with `100.`) or its MagicDNS name, with port `47800`. The row then
   shows `Saved: 100.x.y.z:47800`. The address belongs to the Mac, so it does not change when you
   reinstall Tailscale on the iPhone.
3. **Test the route without the app.** In the iPhone's Safari, open `https://<Mac Tailscale IP>:47800`.
   - A TLS or "secure connection failed" error is good: the Mac was reached (a browser has no
     client key, so it is refused).
   - "Could not connect to the server" means the iPhone cannot reach the Mac. The app is not the problem.
4. **See whether packets arrive** (needs your Mac password), then tap Connect on the iPhone:
   `sudo tcpdump -ni utun4 'tcp port 47800'` (use the `utun` that `ifconfig` shows with your Tailscale IP).
   - Nothing printed: the iPhone's traffic never enters the tunnel. Fix Tailscale on the iPhone.
   - `SYN` lines printed: the traffic arrives, so look at the Mac (hosting on? port listening?
     `lsof -nP -iTCP:47800 -sTCP:LISTEN`).
5. **Fix the iPhone's tunnel.** Switch Tailscale off and on, force-quit and reopen it, check that
   no other VPN or content filter is active (Settings → VPN & Device Management), turn off
   *Private Wi-Fi Address* for the network, and test on cellular to separate a Wi-Fi problem from a
   Tailscale one. If the app shows the Mac online and the Mac can ping the iPhone but the iPhone's
   own traffic still never arrives, delete and reinstall the Tailscale app and sign in again. This
   fixed a real case, where the tunnel looked connected but carried no traffic from the iPhone.
6. **Connected but can't control the Mac.** *Allow Remote Control* resets to off at every launch. Turn it
   on in the Mac's menu.

### Reading the error
| What the app or log says | Meaning |
|---|---|
| "Network is down" | iOS has no usable route to the address. Check step 5. |
| "Connection refused" in about 25 ms | Something on the local network answered instead of the Mac: the traffic is not going through the tunnel. Check step 5. |
| "does not recognise this iPhone" | The Mac was reached but the iPhone is not paired. Pair again. |
| "security key does not match" | A different device answered. Do not pair again; check the address. |

To read the iPhone's own logs over a cable: `brew install libimobiledevice`, then
`idevicesyslog -u <device id>` while you tap Connect, and search the output for `iOSClient`.
`xcrun devicectl list devices` shows the device id. The app's console output is empty because it
logs to the system log, and the address itself is hidden (`<private>`) in the log.

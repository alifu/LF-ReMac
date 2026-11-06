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

## Start at login
Add the app in **System Settings → General → Login Items** ("Open at Login"), then open it once and
choose **Start Hosting**. Hosting does not start by itself, by design.

## Checks
- `pmset -g assertions | grep LF-ReMac` shows the assertion while hosting and nothing after "Stop Hosting".
- Leave the Mac idle overnight, then connect from the iPhone in the morning.

<!-- Rename to the next version's tag (e.g. v1.10.0.md) when it is released. -->

### iPhone: battery saving
- The idle battery saving (as on Android since 1.8.3) now works on iPhone too:
  Wi-Fi or mobile data is detected by itself, and keep-alives, retries,
  LAN announcements and camera checks slow down while no call is on.
- **Low Power Mode** (Settings → Battery) uses the mobile-data pace on Wi-Fi
  too. Calls ring just as fast.

### Mac: menu bar and running in the background
- A menu bar icon with the status, **Open** and **Quit**.
- Close and minimize hide the window (and its Dock icon) to the menu bar; the
  intercom keeps receiving. **Settings → Keep running in the menu bar**.
- **Settings → Start automatically at login** (macOS 13 or later): starts
  hidden in the menu bar.
- App Nap is off, so talk plays at once while hidden.
- Notifications when a line opens or someone rings while the window is hidden.

# Updating an Ottocast U2AIR Pro (CP82) when the app's update fails

Tested on an Ottocast **U2AIR Pro, model CP82** (FCC ID 2BB2X-CP82): firmware `24102111.2702.2` → `26042313.2702.2`, October 2026. Other Ottocast dongles that serve the same web page at `192.168.1.101` probably work the same way, but only the CP82 was tested.

## Why the phone update fails

The dongle never downloads its own firmware. Its update page (`http://192.168.1.101`, script `/js/cpbox.js`) runs **in the client** and does this:

1. Reads the installed version from `http://192.168.1.101/cgi-bin/index.cgi?id=host` (`sys.appver`, e.g. `24102111.2702.2`).
2. Downloads `https://cpbox-abroad.oss-us-west-1.aliyuncs.com/<2nd field>/version.json` (e.g. `.../2702/version.json`). Versions whose 3rd field isn't `2` use `https://cpbox.oss-cn-shenzhen.aliyuncs.com` instead.
3. If `appver` there is newer, downloads the `url` it lists (`update.img`, ~6 MB) from the internet.
4. While downloading, it checks in with the dongle every second. If the dongle stops answering for 3 s, the page reloads and the update is lost.
5. POSTs the image to `http://192.168.1.101/cgi-bin/index.cgi?id=upload` (multipart field `file`) and polls `?id=host` until `update` = `3`.

So the client needs **internet and the dongle at the same time**. A phone joined to the dongle's Wi-Fi typically has no usable internet path while it's on it, so the update stalls or reloads. The vendor's server is fine.

Two more traps:
- `update=3` means **staged**, not installed. The firmware is written on the **next power-up**. Until then the dongle reports version `00000000.xxxx.x`. In a car that happens at ignition-off; on a bench, unplug and replug it.
- **There is no rollback.** Only the latest image is published, and the dongle has no shell to back up the current firmware.

## What you need

- A computer with **two network paths**: Wi-Fi to join the dongle, plus internet over **something else** (Ethernet, or USB tethering from a phone).
- Your home network must **not** use `192.168.1.x`, or the two subnets collide. If it does, use a phone's USB tethering as the internet path instead.
- Stable USB power for the dongle (a wall charger, not a laptop port that may sleep). Losing power during the flash can brick it.
- Wi-Fi: SSID `OTTO-xxxx`, password `88888888`. On the CP82 that password worked on the **5 GHz** network. The 2.4 GHz one advertised a placeholder MAC (`00:01:02:00:00:14`) and wasn't joinable here.

## Method A — any laptop with Ethernet + Wi-Fi, just a browser

Not tested end to end; this follows from the page's code. The dongle's DHCP gives **no default gateway**, so joining its Wi-Fi shouldn't take over the laptop's internet route. The vendor bucket also allows the cross-origin requests the page makes.

1. Plug the laptop into Ethernet and check that you have internet.
2. Join `OTTO-xxxx` over Wi-Fi with password `88888888`. Ignore "no internet" warnings.
3. Open `http://192.168.1.101`. The firmware version is shown and the page checks for an update. Press **Update**.
4. Leave the page alone until the progress bar finishes and it says the update is complete.
5. Unplug the dongle, wait 10 s, plug it back in, and **leave it powered for 5 minutes**. Then reload `http://192.168.1.101` and check the version.

## Method B — Linux script

[`ottocast-update.sh`](ottocast-update.sh) does the whole sequence. The dry run has been tested on a CP82; the flash steps are the same requests that were sent by hand for the update above. It runs on a Linux machine. Requirements: `iw`, `wpa_supplicant`, `curl`, `python3`, and `busybox` or `dhcpcd`.

```
sudo ./ottocast-update.sh -i wlan0 --dry-run
sudo ./ottocast-update.sh -i wlan0
```

The script:
- Joins the dongle with its own `wpa_supplicant`. It reads the DHCP offer but applies only the address — **no route or DNS change**, so the machine's normal connectivity is untouched.
- Refuses to run if the interface is your internet uplink, is managed by NetworkManager, or if `192.168.1.0/24` is already in use.
- Reads the installed version, fetches the vendor manifest, downloads the image and verifies its MD5 against the server's `Content-MD5`.
- Asks you to type `flash`, then uploads exactly as the web page does and polls until the update is staged.
- Asks you to power-cycle the dongle, then waits until the new version appears.
- Disconnects and removes the address on exit. Logs, the manifest and the image stay in `./otto-<timestamp>/`.

`--dry-run` stops before flashing. Run it first; it's a safe way to see the installed and available versions.

## Troubleshooting

- **Wrong password / can't join:** try the 5 GHz network. On a phone, delete any saved `OTTO-xxxx` profile first.
- **`update` stuck at 1 or 2 for more than 10 minutes:** leave it powered, then power-cycle once and check `?id=host`.
- **`update` greater than 3:** the dongle reported a failure. Power-cycle and retry.
- **Version shows `00000000.…`:** the update is staged; power-cycle it (see above).

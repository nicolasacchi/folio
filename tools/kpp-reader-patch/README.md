# KPP reader-gate bytecode patch — EXPERIMENTAL, CAUSED A BOOT LOCKOUT

**Status: do not run against a device you can't afford to lose remote access
to.** This patch bricked remote access to the test Kindle on 2026-07-13
because its accompanying auto-heal safety net was hooked at too late a boot
stage. See [Incident](#incident-2026-07-13) below and
`docs/kindle-519-kpp-reader-routing.html` for the full technical writeup.

## What this is

Sideloaded books on Kindle firmware 5.19.2 only get the modern reader's
back/home buttons when TWO gates are on:

1. `/var/local/ENABLE_KPPREADER` exists — safe, reversible, no rootfs
   changes. This is what Folio's `modern_reader_pinned` device setting
   manages (see `kindled/src/hardening.rs`).
2. Amazon's `LegacyFormatMigration` weblab (`KINDLE_FEATURE_1308000`),
   evaluated by a method in `/opt/amazon/ebook/lib/Reader-utils.jar` —
   **no known safe local override**. It's a server-driven, staged rollout.

**The recommended path is to wait for gate 2** (Folio reports
`reader_mode: kpp_pending` until it flips). This directory exists because
the user asked to force it immediately instead, which requires patching
firmware bytecode — a materially riskier operation than anything else in
this repo, done to a physical device with no easy remote recovery if it goes
wrong.

## Files

- `patch_reader_utils.py` — finds the obfuscated method in
  `ReaderUtils.class` that reads weblab `KINDLE_FEATURE_1308000` (by its
  string-constant reference, not by name — names are obfuscated and may
  differ across firmware builds) and flips its final `iload_0` to
  `iconst_1`, i.e. makes it always return `true`. One byte changed;
  verified byte-identical to the patch actually applied on 2026-07-13.
- `kpp-apply.sh` — backs up the stock jar (two locations), installs the
  patched jar, installs the auto-heal upstart job, arms it.
- `kpp-autoheal.conf` — upstart job meant to revert the patch on the second
  unconfirmed boot. **Corrected** after the incident to hook on
  `start on startup` (the earliest upstart event) instead of
  `start on starting lab126_gui` (too late — see incident below). This fix
  is **unverified on real hardware**.
- `kpp-recover.sh` — standalone restore, for running from any shell (USB
  console, diagnostic mode) independent of the framework/WiFi/tunnel being
  up. Safe no-op if nothing was ever patched.

## Incident (2026-07-13)

1. Patch applied via the original (buggy) `kpp-apply.sh` + autoheal hooked
   on `start on starting lab126_gui`.
2. Device rebooted to load the patched jar. The Java reader framework
   crashed/hung before reaching the `lab126_gui` upstart stage — so the
   auto-heal job never ran, and neither did WiFi/the reverse SSH tunnel the
   normal remote workflow depends on.
3. Multiple power-cycles did not recover it (the same early crash recurs
   every boot).
4. Recovery required physically connecting the device over **USB
   networking** to run the equivalent of `kpp-recover.sh` from a shell that
   doesn't depend on the crashed framework.

**Lesson encoded in the fixed `kpp-autoheal.conf`:** a boot-time safety net
must hook the earliest possible stage, not a stage that assumes the thing
you're guarding against still lets boot progress that far. `start on startup`
should run before the framework starts constructing itself. This has not yet
been re-verified on real hardware — the device that broke could not be used
to test it. Confirm on a **healthy, unpatched** device that a
`start on startup` job actually fires and completes before `framework`/
`lab126_gui`, before trusting this in a real apply.

## Deliberately not committed

The original and patched `Reader-utils.jar` files are not in this repo:
they're Amazon's proprietary firmware binaries, multi-hundred-KB binaries
with no place in git history, and keeping the already-proven-dangerous
patched copy around invites re-running it without re-deriving it fresh
against whatever jar is actually on the target device. `patch_reader_utils.py`
operates on a `ReaderUtils.class` extracted from the jar in place at apply
time.

## USB recovery, if you're locked out again

The device's `/etc/hosts` carries `192.168.15.200 usbnet-host-gw`, implying
a USB-networking jailbreak extension in the `192.168.15.0/24` range — the
exact device-side address was not confirmed live. On the host computer,
after plugging in via USB: look for a new network interface (RNDIS/CDC-ether,
often `usb0` or similar) in `dmesg`/`ip addr`, bring it up with an address in
that /24 (e.g. `192.168.15.201/24`), and try SSH to nearby addresses in the
block (a common convention for this jailbreak's USBNetwork extension is
`.244`, but verify rather than assume). The same SSH key used for the normal
reverse-tunnel login (`~/.ssh/id_ed25519x`, kept outside this repo) is
expected to authenticate — get it from whoever normally accesses the device
if working from a different machine.

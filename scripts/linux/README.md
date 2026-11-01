# A Linux desktop for Circe

Use a Debian/Ubuntu, Fedora/RHEL, or Arch (including Omarchy) VM with systemd, an
ordinary Linux account, and sudo access. If the VM already serves a desktop over VNC
on localhost (for example wayvnc on Omarchy), Circe's Google Cloud setup offers it as is
and installs nothing. Otherwise the installer sets up Circe's desktop on display `:1` (TigerVNC on loopback only),
which shows, in order of preference:

1. **The account's session that's already open**: Chrome Remote Desktop's (its Xvfb) or an RDP session
   (xrdp's Xorg). TigerVNC's screen-sharing server (`x0vncserver`) shows that same session, with its open
   windows, rather than a second desktop. A second desktop would fight the first over apps that run once per
   account: Chrome's profile, VS Code, Electron apps. Sound and the Mac microphone go to that session's own
   sound server, since Chrome Remote Desktop runs one. On a computer where Chrome Remote Desktop is enabled,
   Circe waits briefly at startup for its session. The session ending (sign-out, restart) restarts Circe's
   desktop, which looks again.
2. **The computer's own desktop**: the best X11 session in `/usr/share/xsessions` (Ubuntu's GNOME, KDE Plasma,
   Cinnamon, MATE, XFCE, then any window manager). It is started the way the login screen and xrdp start it
   (`/etc/X11/Xsession` on Debian/Ubuntu), in its own D-Bus session. It uses the computer's own programs and
   libraries, never Circe's private ones. A desktop that can't run inside Xvnc (it stops within 20 seconds)
   falls back to Circe's light desktop. Wayland-only desktops (GNOME 49+) have no X11 session, so they also
   use the fallback.
3. **XFCE** (installed with sudo) or **Circe's light desktop** (without administrator access), each with an
   Applications menu of the computer's installed apps.

The installer also provides headless audio through PulseAudio or an existing PipeWire-pulse server. With sudo it
installs only TigerVNC on a computer that has its own desktop. RHEL/Rocky XFCE may require EPEL/CRB. On Arch, packages come from
the existing package list (`pacman -S --needed`, never `-Sy`); if a download fails, update
the system first (`sudo pacman -Syu`, or `omarchy-update`).
Setup also attempts to install FFmpeg, the smooth-video helper, and a compressed
audio helper. These are optional: unavailable encoders keep VNC and PCM audio
usable. See [smooth video](VIDEO.md) for CPU defaults and the FLV interface, and
[compressed audio](AUDIO.md) for the Ogg/Opus contract and diagnostics.

## Install on the VM

In Circe, **Add a computer → Google Cloud computer** (or *Set up & connect* for SSH)
sends the bundled installer through your existing SSH/IAP connection. If sudo needs a
password, Circe asks for it. The installer receives it on a private file descriptor
(never in arguments, environment, or files), and each privileged command runs with
`/dev/null` as its input. Setup returns the newly generated VNC password to Circe for
Keychain storage and immediate connection. It is not downloaded from a public URL.

**Without administrator access.** If the account can't use sudo, or doesn't know its Linux password (common with
OS Login), Circe sets up a desktop in the account's own folder instead (`--without-admin`). It downloads the
distribution's own packages as the user and checks every one before unpacking it: apt verifies them against the
signed package lists it refreshes (user-owned), `dnf download` packages are checked with `rpmkeys` against the
keys the administrator installed in `/etc/pki/rpm-gpg` (in a private key database), and Arch packages must carry
a signature that verifies with `gpgv` against pacman's keyring. A package that can't be verified is never used.
Nothing installs system-wide or runs as root. The packages are unpacked next to `~/.local/share/circe/root` and
swapped in only when complete, so a failed or cancelled repair leaves the working desktop alone; one setup runs
at a time per account, and about 2 GB of free space is required. `~/.config/circe/prefix.env` adds the private
programs after the system's own (they fill gaps and never replace the computer's programs). Because XFCE's window
manager and panel have `/usr` paths built in, the light desktop is JWM (a taskbar with Menu, Terminal, Files and a
browser if installed; the menu's Applications lists every installed app, including snaps and Flatpaks) with
XFCE's terminal and Thunar; Openbox with tint2 is used where JWM isn't packaged
(RHEL/Rocky). On a computer with no sound server (most server images), a private PulseAudio runs as the user
service `circe-pulse`; otherwise the computer's PulseAudio or PipeWire is used. Sound is optional: setup still
finishes, and says so, if it can't start. Where TigerVNC's keyboard compiler (`xkbcomp`) isn't installed, Circe
points its private Xvnc at its own copy. A computer that would need a newer C library than it has is refused with
a request to install system updates (a private C library can't work). Lingering is enabled through the account's
own polkit permission where allowed (never waiting for a password prompt); otherwise Circe starts the desktop each
time it connects and holds a session open while connected, so it isn't stopped underneath you. Smooth video needs
an FFmpeg that's already installed. If the computer's package mirror refuses a file (Google Cloud's regional Ubuntu
mirrors sometimes answer 503), setup fetches it from the distribution's main archive. A file fetched this way is
used only if it matches the SHA-256 in the package list apt verified. An optional package that still can't be
fetched (the screen-sharing server) is skipped. Run end to end on Ubuntu 24.04 (a real GCE VM and a systemd container), Fedora
41 and Rocky 9 + EPEL (systemd containers: desktop, sound, microphone, keyboard, reboot), and Debian 12 and Arch
(containers without systemd: install, desktop, apps).

`bash setup-circe-host.sh --probe` is read-only. It prints one `CIRCE_PROBE_RESULT` JSON
line with the distribution, package manager, sudo mode (`passwordless`, `password`,
`root`, or `none`), whether Circe's desktop is installed, loopback VNC listeners that
answer the RFB greeting, and this user's desktop sessions. Failures print a stable
`CIRCE_SETUP_ERROR {"code": …}` line, such as `sudo_password_required`,
`sudo_password_incorrect`, `sudo_not_allowed`, `unsupported_distribution`, or
`package_install_failed`.

For manual installation or accounts that require an interactive sudo password:

Copy `setup-circe-host.sh` to the VM using your existing SSH connection, then run:

```sh
bash ~/setup-circe-host.sh
# If sudo requires a password, run this in an interactive SSH terminal instead:
sudo bash ~/setup-circe-host.sh
```

For example, from a checkout on your Mac, copy it with either:

```sh
scp scripts/linux/setup-circe-host.sh user@host:setup-circe-host.sh
gcloud compute scp scripts/linux/setup-circe-host.sh INSTANCE:setup-circe-host.sh --zone ZONE --project PROJECT --tunnel-through-iap
```

Run the script as the account you will connect to. If already root, use
`bash setup-circe-host.sh --user YOUR_LINUX_ACCOUNT`. Package installation uses
noninteractive apt or dnf. The script enables systemd user services and login
lingering, so the desktop and audio start at boot without an interactive login.
It does not change cloud resources, SSH configuration, or firewall rules.

Save the VNC password printed on the first install. Rerunning preserves it and
repairs Circe's managed configuration. To generate a new password explicitly:

```sh
bash ~/setup-circe-host.sh --reset-password
```

The VNC password is eight characters because classic VNC authentication uses
only the first eight. The password file is `~/.vnc/passwd`, readable only by its
owner; the plaintext is not saved by this installer. SSH protects the VNC stream
and authenticates the server. Never expose the VNC listener directly to the internet.

Successful installation ends with a `CIRCE_SETUP_RESULT` JSON record for Circe.
Its password is populated only when this invocation creates one; reruns return
`null` and retain existing credentials. Treat the first-install output as a secret.

## Add it in Circe

Choose **Add a computer** in the launcher:

| Connection | Enter |
|---|---|
| Google Cloud | Instance name, zone, project (optional); leave **Use IAP** on |
| SSH | `user@host` or an SSH-config alias; port is optional |
| Both | VNC display `1`; enter the generated VNC password when asked |

The installer prints these fields, including instance/zone/project when the
Google Cloud metadata service is available. Use the same Linux account for setup
and the tunnel; audio and the desktop belong to that account.

Circe uses your Mac's existing SSH keys/configuration or Google Cloud CLI login.
Set up and verify SSH access first. Google Cloud IAP needs the IAP tunnel IAM
permission and SSH ingress from the IAP forwarding range; OS Login or SSH-key
permissions may also apply. A VM public IP and a public VNC port are unnecessary.
See Google's [IAP SSH guide](https://docs.cloud.google.com/compute/docs/connect/ssh-using-iap)
and [IAP prerequisites](https://docs.cloud.google.com/iap/docs/using-tcp-forwarding).
This installer does not grant those permissions or open firewall rules.

## Check and troubleshoot

```sh
bash ~/setup-circe-host.sh --check
systemctl --user status circe-desktop circe-audio
journalctl --user -u circe-desktop -u circe-audio -n 60 --no-pager
ss -ltn 'sport = :5901'
```

`--check` is read-only and exits nonzero if a service, boot setting, loopback
listener, or audio monitor is missing. Any non-loopback listener is reported as
unsafe. Expected listeners are `127.0.0.1:5901` and/or `[::1]:5901`.
Optional media capability lines report H.264 and Opus availability without
failing an otherwise healthy VNC/PCM host.

Use `--display 2` if `:1` already belongs to another desktop; choose display `2`
in Circe too. `--geometry 1920x1080` sets the initial size; Circe can request a
different size when the server supports remote resize. Signing out inside Circe's
desktop starts a fresh one a few seconds later, like signing in again over RDP (`circe-desktop.service` uses
`Restart=always`). `--check` says which desktop Circe is showing. `--probe` reports the computer's own desktop
(`systemDesktop`), whether Circe's desktop was set up by this version (`circe.current`), and whether it's
showing an open session (`circe.shared`). Circe's wizard offers *Update & connect* for a desktop set up by an
older version.

For audio, Circe records the default output monitor (the `circe` sink after
setup) over another SSH channel, using the Opus helper when available and PCM
otherwise. To diagnose PCM capture directly:

```sh
XDG_RUNTIME_DIR=/run/user/$(id -u) parec --device=circe.monitor --format=s16le --rate=48000 --channels=2 --raw > /tmp/circe-audio.pcm
```

Stop that diagnostic with Control-C. The file contains raw stereo PCM. The audio
service recreates its null sink after an audio-server restart and makes it this
account's default output. Existing PipeWire-pulse installations are retained.

On SELinux systems, inspect denials if the custom user service is blocked; this
script does not disable SELinux or replace distribution security policies.
Package installation and service behavior still need a real Linux VM check;
local development fixtures validate generation, reruns, and failure reporting.

To stop Circe's desktop and audio:

```sh
systemctl --user disable --now circe-desktop circe-audio
```

Only disable lingering with `sudo loginctl disable-linger "$USER"` if no other
user services need to run at boot. Installed packages and unrelated user files
are retained. Circe's managed files are in `~/.config/circe`,
`~/.local/libexec/circe`, and `~/.config/systemd/user/circe-*.service`.

Server options follow the [TigerVNC Xvnc manual](https://tigervnc.org/doc/Xvnc.html).
Password handling follows [vncpasswd](https://tigervnc.org/doc/vncpasswd.html);
boot persistence uses [systemd user lingering](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html).

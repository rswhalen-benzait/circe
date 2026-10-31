# A Linux desktop for Circe

Use a Debian or Ubuntu VM with systemd, an ordinary Linux account, and sudo access.
The installer creates a separate XFCE desktop on display `:1`, keeps TigerVNC on
loopback only, and provides headless audio through PulseAudio or an existing
PipeWire-pulse server. RHEL/Rocky/Fedora are best-effort; XFCE may require EPEL/CRB.
Setup also attempts to install FFmpeg, the smooth-video helper, and a compressed
audio helper. These are optional: unavailable encoders keep VNC and PCM audio
usable. See [smooth video](VIDEO.md) for CPU defaults and the FLV interface, and
[compressed audio](AUDIO.md) for the Ogg/Opus contract and diagnostics.

## Install on the VM

In Circe, **Add a computer → Set up & connect** sends the bundled installer
through your existing SSH/IAP connection. It needs passwordless sudo (standard
on many cloud images). Setup returns the newly generated password to Circe for
Keychain storage and immediate connection. It is not downloaded from a public URL.

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
different size when the server supports remote resize. Logging out inside XFCE
ends that desktop session; reconnect after restarting the service with
`systemctl --user restart circe-desktop`.

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

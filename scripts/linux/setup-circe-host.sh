#!/usr/bin/env bash
# A private, persistent Linux desktop for Circe's SSH / Google Cloud connections.
main() {
{ set +x; } 2>/dev/null # never trace: the sudo password and VNC password pass through variables
set -euo pipefail
umask 077

usage() {
    cat <<'HELP'
Usage: bash setup-circe-host.sh [--user USER] [--display 1] [--geometry 1600x1000]
       bash setup-circe-host.sh [--user USER] [--display 1] --check
       bash setup-circe-host.sh [--user USER] --reset-password
       bash setup-circe-host.sh [--user USER] --probe
       bash setup-circe-host.sh [--display 1] --without-admin

Run as the Linux account you connect to (sudo is used for packages and boot setup).
When running as root, supply --user or invoke through sudo from that account.
--check only reports status; it never installs packages or changes services.
--probe prints one CIRCE_PROBE_RESULT JSON line (distribution, sudo, existing desktops); read-only.
--without-admin installs versioned desktop runtimes under ~/.local/share/circe from the distribution's own packages
(downloaded and unpacked as this user, never as root) when sudo isn't available.
When CIRCE_SUDO_PASSWORD_FD names an open descriptor, its first line is the sudo password.
Rerunning preserves the VNC password. --reset-password generates a new one.
HELP
}
die() { printf 'Circe: %s\n' "$*" >&2; exit 1; }
# A stable code for Circe (stdout), then the human explanation (stderr).
fail() { printf 'CIRCE_SETUP_ERROR {"code":"%s"}\n' "$1"; die "$2"; }
SUDO_PASSWORD=
if [[ -n "${CIRCE_SUDO_PASSWORD_FD:-}" ]]; then
    [[ "$CIRCE_SUDO_PASSWORD_FD" =~ ^[3-9]$ ]] || die 'CIRCE_SUDO_PASSWORD_FD must be a descriptor from 3 to 9.'
    IFS= read -r -u "$CIRCE_SUDO_PASSWORD_FD" SUDO_PASSWORD || true
    eval "exec $CIRCE_SUDO_PASSWORD_FD<&-"
fi
unset CIRCE_SUDO_PASSWORD_FD
TARGET_USER="${SUDO_USER:-$(id -un)}"
DISPLAY_NUMBER=1
GEOMETRY=1600x1000
DISPLAY_EXPLICIT=false
GEOMETRY_EXPLICIT=false
CHECK=false
PROBE=false
WITHOUT_ADMIN=false
RESET_PASSWORD=false
while (($#)); do
    case "$1" in
        --user|--display|--geometry)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --user) TARGET_USER="$2" ;;
                --display) DISPLAY_NUMBER="${2#:}"; DISPLAY_EXPLICIT=true ;;
                --geometry) GEOMETRY="$2"; GEOMETRY_EXPLICIT=true ;;
            esac
            shift 2 ;;
        --check) CHECK=true; shift ;;
        --probe) PROBE=true; shift ;;
        --without-admin) WITHOUT_ADMIN=true; shift ;;
        --reset-password) RESET_PASSWORD=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ "$(uname -s)" == Linux ]] || die 'Run this script on the Linux VM, not on your Mac.'
command -v getent >/dev/null || die 'getent is required.'
ACCOUNT="$(getent passwd "$TARGET_USER")" || die "No such Linux account: $TARGET_USER"
IFS=: read -r TARGET_USER _ TARGET_UID _ _ TARGET_HOME _ <<< "$ACCOUNT"
[[ "$TARGET_UID" != 0 ]] || die 'Choose a non-root desktop account with --user USER.'
[[ "$TARGET_HOME" == /* && -d "$TARGET_HOME" && "$TARGET_HOME" != *$'\n'* ]] || die 'The account needs an existing home directory.'
[[ $EUID == 0 || $EUID == "$TARGET_UID" ]] || die 'Use sudo when configuring another account.'
RUNTIME="/run/user/$TARGET_UID"
CONFIG="$TARGET_HOME/.config/circe"
LIBEXEC="$TARGET_HOME/.local/libexec/circe"
UNITS="$TARGET_HOME/.config/systemd/user"
# Circe's own password file; an existing ~/.vnc/passwd may belong to another VNC server. Desktops set up by
# older Circe versions (host.conf present, no new file) keep using ~/.vnc/passwd.
PASSWORD_FILE="$CONFIG/vncpasswd"
if [[ ! -s "$PASSWORD_FILE" && -f "$CONFIG/host.conf" && -s "$TARGET_HOME/.vnc/passwd" ]]; then PASSWORD_FILE="$TARGET_HOME/.vnc/passwd"; fi
# Read only numeric settings here. Never source a user-owned shell file as root.
# The desktop helpers' generation. A desktop set up by an older generation is offered an update (repair) by Circe.
# 2: runs the computer's own desktop (GNOME, KDE…) when it has one; the light desktop gained an Applications menu.
SETUP_GENERATION=2
read_host_settings() {
    if ! $DISPLAY_EXPLICIT; then
        DISPLAY_NUMBER=1
        if [[ -f "$CONFIG/host.conf" ]]; then DISPLAY_NUMBER="$(awk -F= '/^DISPLAY_NUMBER=[0-9]+$/ { print $2; exit }' "$CONFIG/host.conf")"; fi
    fi
    if ! $GEOMETRY_EXPLICIT; then
        GEOMETRY=1600x1000
        if [[ -f "$CONFIG/host.conf" ]]; then GEOMETRY="$(awk -F= '/^GEOMETRY=[0-9]+x[0-9]+$/ { print $2; exit }' "$CONFIG/host.conf")"; fi
    fi
    [[ "$DISPLAY_NUMBER" =~ ^[0-9]{1,2}$ ]] || die 'Display must be a number from 1 to 99.'
    DISPLAY_NUMBER=$((10#$DISPLAY_NUMBER))
    ((DISPLAY_NUMBER >= 1 && DISPLAY_NUMBER <= 99)) || die 'Display must be from 1 to 99.'
    [[ "$GEOMETRY" =~ ^([0-9]{3,4})x([0-9]{3,4})$ ]] || die 'Geometry must look like 1600x1000.'
    WIDTH=$((10#${BASH_REMATCH[1]})); HEIGHT=$((10#${BASH_REMATCH[2]}))
    ((WIDTH >= 640 && WIDTH <= 7680 && HEIGHT >= 480 && HEIGHT <= 4320)) || die 'Geometry must be between 640x480 and 7680x4320.'
    VNC_PORT=$((5900 + DISPLAY_NUMBER))
}
read_host_settings

# The password (when given) lives only in this shell; printf is a builtin, so it never reaches argv.
# -k makes sudo read it even with cached credentials (without touching the user's other sudo sessions), and
# the command itself always gets /dev/null as stdin, so a NOPASSWD rule can't hand it the password.
as_root() {
    if ((EUID == 0)); then "$@"
    elif [[ -n "$SUDO_PASSWORD" ]]; then as_root_with_password "$@"
    elif [[ -t 0 && -t 2 ]]; then sudo -- "$@"
    else sudo -n -- "$@"; fi
}
# Preferred: the command runs under /bin/sh with /dev/null as stdin. If sudo policy allows only specific commands
# (no shell), run the exact command instead; these commands (package managers, loginctl, systemctl) don't read stdin.
as_root_with_password() {
    local errors status
    errors="$(mktemp)"
    if printf '%s\n' "$SUDO_PASSWORD" | sudo -k -S -p '' -- /bin/sh -c 'exec "$@" </dev/null' circe-root "$@" 2>"$errors"; then status=0; else status=$?; fi
    if ((status != 0)) && grep -qiE 'not allowed to (execute|run)|may not run' "$errors"; then
        rm -f "$errors"
        # Exact command only. Try it without a password first (stdin closed); a NOPASSWD rule then never sees
        # the password. Only if sudo asks is the password sent, and sudo consumes that single line itself.
        if sudo -n -- "$@" </dev/null 2>/dev/null; then return 0; fi
        printf '%s\n' "$SUDO_PASSWORD" | sudo -k -S -p '' -- "$@"
        return
    fi
    cat "$errors" >&2; rm -f "$errors"
    return "$status"
}
as_user() {
    local environment=(env "HOME=$TARGET_HOME" "USER=$TARGET_USER" "LOGNAME=$TARGET_USER"
        "XDG_RUNTIME_DIR=$RUNTIME" "DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME/bus" "PULSE_SERVER=unix:$RUNTIME/pulse/native")
    if ((EUID == TARGET_UID)); then "${environment[@]}" "$@"
    else runuser -u "$TARGET_USER" -- "${environment[@]}" "$@"; fi
}
# A tool that may live in the account's private folder: its prefix.env is read only after switching to the
# account, never by a root shell.
# shellcheck disable=SC2016
user_tool() { as_user bash -c '[[ -r "$HOME/.config/circe/prefix.env" ]] && . "$HOME/.config/circe/prefix.env"; exec "$@"' circe-tool "$@"; }
report_status() {
    local failed=0 listeners address found=0 check_media="${1:-true}"
    printf 'Circe desktop for %s — display :%s, TCP %s\n' "$TARGET_USER" "$DISPLAY_NUMBER" "$VNC_PORT"
    if [[ -s "$PASSWORD_FILE" ]]; then printf '  Password: configured (never printed by --check)\n'
    else printf '  Password: missing\n'; failed=1; fi
    if as_user systemctl --user is-active --quiet circe-desktop.service 2>/dev/null; then printf '  circe-desktop.service: running\n'
    else printf '  circe-desktop.service: not running\n'; failed=1; fi
    if ! as_user systemctl --user is-enabled --quiet circe-desktop.service 2>/dev/null; then printf '  circe-desktop.service: not enabled at boot\n'; fi
    local session_id session_name shared=""
    [[ -z "${RUNTIME:-}" || ! -r "$RUNTIME/circe/desktop.env" ]] || shared="$(sed -n 's/^CIRCE_SHARED_DISPLAY=\([0-9]\{1,2\}\)$/\1/p' "$RUNTIME/circe/desktop.env")"
    if [[ -n "$shared" ]]; then printf '  Desktop: the session already open on display :%s (Chrome Remote Desktop or RDP)\n' "$shared"
    elif IFS=$'\037' read -r session_id session_name _ < <(find_system_session); then printf "  Desktop: %s (this computer's own)\n" "${session_name:-$session_id}"
    else printf "  Desktop: Circe's light desktop\n"; fi
    if [[ "$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || true)" == yes ]]; then printf '  Boot persistence: enabled\n'
    # Without lingering Circe starts the desktop when it connects; that's a known mode, not a failure.
    elif [[ "${PERSISTENT:-true}" == false || -f "$CONFIG/connected-only" ]]; then printf '  Boot persistence: off (Circe starts the desktop when it connects)\n'
    else printf '  Boot persistence: not enabled\n'; fi
    if command -v ss >/dev/null; then
        listeners="$(ss -H -ltn "sport = :$VNC_PORT")"
        while read -r address; do
            [[ -n "$address" ]] || continue
            found=1
            case "$address" in
                "127.0.0.1:$VNC_PORT"|"[::1]:$VNC_PORT"|"::1:$VNC_PORT") printf '  VNC listener: %s (loopback only)\n' "$address" ;;
                *) printf '  UNSAFE VNC listener: %s — stop the server and check its configuration\n' "$address"; failed=1 ;;
            esac
        done < <(awk '{ print $4 }' <<< "$listeners")
        if ((found == 0)); then printf '  VNC listener: missing\n'; failed=1; fi
    else printf '  VNC listener: cannot verify (ss missing)\n'; failed=1; fi
    # Sound is optional: a desktop without it still works, so it's reported separately (AUDIO_READY).
    AUDIO_READY=false
    if [[ "${AUDIO_ACTIVATION_FAILED:-false}" != true ]] && as_user systemctl --user is-active --quiet circe-audio.service 2>/dev/null \
        && user_tool pactl list short sources 2>/dev/null | awk '{ print $2 }' | grep -qx 'circe.monitor'; then printf '  Audio: circe.monitor ready (48 kHz stereo)\n'; AUDIO_READY=true
    else printf '  Audio: unavailable (circe.monitor missing; the desktop works without sound)\n'; fi
    if ! $check_media; then return "$failed"; fi
    if [[ -x "$LIBEXEC/video" ]]; then
        local video_config
        if video_config="$(as_user "$LIBEXEC/video" --check --display "$DISPLAY_NUMBER" 2>/dev/null)"; then printf '  Video: available %s\n' "$video_config"
        else printf '  Video: unavailable (VNC fallback is available)\n'; fi
    else printf '  Video: wrapper missing (VNC fallback is available)\n'; fi
    local audio_config
    if [[ -x "$LIBEXEC/audio" ]] && audio_config="$(as_user "$LIBEXEC/audio" --check 2>/dev/null)"; then
        printf '  Audio transport: Opus available %s\n' "$audio_config"
    else printf '  Audio transport: PCM fallback\n'; fi
    return "$failed"
}
# ---- Installing without administrator access ---------------------------------------------------------------
# The distribution's own packages, downloaded and unpacked as the user into PREFIX (package managers check
# their signatures; nothing runs as root). Programs run from there via prefix.env.
PREFIX="$TARGET_HOME/.local/share/circe/root"
PACKAGE_CACHE="$TARGET_HOME/.cache/circe/packages"
PREFIX_ENV="$CONFIG/prefix.env"
# The target UID opens and holds its lock; a root parent must never inherit a descriptor opened on
# an account-controlled path. Short-lived mutation workers inherit the FIFO lease so a killed parent
# cannot release the lock while its worker is still writing. Only isolated health probes close the lease.
acquire_setup_lock() {
    command -v flock >/dev/null || fail setup_lock_unavailable 'Circe needs flock (util-linux) to set up this account safely.'
    SETUP_LOCK_DIR=$(mktemp -d /tmp/circe-setup-lock.XXXXXX)
    mkfifo "$SETUP_LOCK_DIR/lease"
    if ((EUID == 0)); then chown "$TARGET_UID" "$SETUP_LOCK_DIR/lease"; chmod 711 "$SETUP_LOCK_DIR"; fi
    exec 8<>"$SETUP_LOCK_DIR/lease"
    : > "$SETUP_LOCK_DIR/status"
    trap 'setup_exit $?' EXIT
    (
        exec 8>&- # permanently close the child copy, including shell redirection backups
        # shellcheck disable=SC2016
        as_user bash -c '
        set -e; umask 077
        mkdir -p "$1"
        [[ ! -L "$1/.lock" ]] || { echo unsafe; exit 1; }
        exec 9>>"$1/.lock"
        chmod 600 "$1/.lock"
        flock -n 9 || { echo busy; exit 1; }
        exec 7<"$2" # open while the parent still holds its writer, before acknowledging the lease
        echo locked
        cat <&7 >/dev/null
        ' _ "$PACKAGE_CACHE" "$SETUP_LOCK_DIR/lease"
    ) > "$SETUP_LOCK_DIR/status" &
    SETUP_LOCK_HOLDER=$!
    local attempt answer=""
    for ((attempt=0; attempt<100; attempt++)); do
        IFS= read -r answer < "$SETUP_LOCK_DIR/status" || true
        [[ -z "$answer" ]] || break
        sleep 0.05
    done
    case "$answer" in
        locked) ;;
        busy) fail setup_running 'Circe is already setting up a desktop for this account. Wait for it to finish, then try again.' ;;
        *) fail setup_lock_unavailable 'Circe could not acquire its account setup lock safely.' ;;
    esac
}
# Called through the EXIT cleanup.
# shellcheck disable=SC2329
release_setup_lock() {
    if [[ -n "${SETUP_LOCK_HOLDER:-}" ]]; then
        exec 8>&-
        wait "$SETUP_LOCK_HOLDER" 2>/dev/null || true
    fi
    [[ -z "${SETUP_LOCK_DIR:-}" ]] || rm -rf -- "$SETUP_LOCK_DIR"
}
# Rollback must be usable even when the candidate's loader/plugin settings are broken. Never source the
# journal or any target-owned shell file here, including when an administrator is repairing another account.
clean_user() {
    LD_LIBRARY_PATH='' as_user env -u LD_LIBRARY_PATH -u CIRCE_PREFIX -u CIRCE_XKBDIR -u CIRCE_XVNC_CWD \
        -u GSETTINGS_SCHEMA_DIR -u GDK_PIXBUF_MODULE_FILE -u FONTCONFIG_FILE -u XDG_DATA_DIRS -u XDG_CONFIG_DIRS \
        "PATH=$SETUP_BASE_PATH" "$@"
}
setup_restore() {
    local journal="$1" unit failed=0
    local CONFIG="$TARGET_HOME/.config/circe" LIBEXEC="$TARGET_HOME/.local/libexec/circe" UNITS="$TARGET_HOME/.config/systemd/user" PREFIX="$TARGET_HOME/.local/share/circe/root"
    [[ -f "$journal/ready" && ! -f "$journal/committed" ]] || return 0
    if [[ -f "$journal/services-touched" ]]; then
        for unit in circe-desktop.service circe-audio.service circe-pulse.service; do
            clean_user systemctl --user stop "$unit" >/dev/null 2>&1 || true
            clean_user systemctl --user disable "$unit" >/dev/null 2>&1 || true
        done
    fi
    clean_user bash -s -- "$journal" "$CONFIG" "$LIBEXEC" "$UNITS" "$PREFIX" <<'RESTORE' || failed=1
set -euo pipefail
journal=$1; config=$2; helpers=$3; units=$4; prefix=$5
# A newly published password may already be in Circe's Keychain. Keep it; restoring an old password
# would strand that client. Password generation is intentionally outside runtime rollback.
if [[ -f "$config/vncpasswd" ]]; then cp -p "$config/vncpasswd" "$journal/published-password"; fi
rm -rf -- "$config" "$helpers"
if [[ -d "$journal/config" ]]; then mkdir -p "$(dirname "$config")"; cp -a "$journal/config" "$config"; fi
if [[ -f "$journal/published-password" ]]; then mkdir -p "$config"; chmod 700 "$config"; mv -f "$journal/published-password" "$config/vncpasswd"; fi
if [[ -d "$journal/helpers" ]]; then mkdir -p "$(dirname "$helpers")"; cp -a "$journal/helpers" "$helpers"; fi
mkdir -p "$units"
for unit in circe-desktop.service circe-audio.service circe-pulse.service; do
    rm -f -- "$units/$unit"
    [[ ! -e "$journal/$unit" ]] || cp -a "$journal/$unit" "$units/$unit"
done
if [[ -f "$journal/prefix-link" ]]; then
    link=$(cat "$journal/prefix-link")
    ln -s -- "$link" "$prefix.rollback.$$"
    mv -Tf -- "$prefix.rollback.$$" "$prefix"
elif [[ -f "$journal/prefix-absent" && -L "$prefix" ]]; then rm -f -- "$prefix"; fi
# Legacy actual directories and all immutable runtimes are retained: live SSH helpers may still use them.
RESTORE
    if [[ -f "$journal/services-touched" ]]; then
        clean_user systemctl --user daemon-reload >/dev/null 2>&1 || failed=1
        for unit in circe-pulse.service circe-audio.service circe-desktop.service; do
            if [[ -f "$journal/enabled-$unit" ]]; then clean_user systemctl --user enable "$unit" >/dev/null 2>&1 || failed=1; fi
            if [[ -f "$journal/active-$unit" ]]; then clean_user systemctl --user start "$unit" >/dev/null 2>&1 || failed=1; fi
        done
    fi
    ((failed == 0)) || return 1
    clean_user rm -f -- "$PACKAGE_CACHE/active-transaction"
}
setup_begin() {
    local previous unit
    SETUP_TRANSACTION=
    if [[ -f "$PACKAGE_CACHE/active-transaction" ]]; then
        previous=$(cat "$PACKAGE_CACHE/active-transaction")
        case "$previous" in "$PACKAGE_CACHE"/transactions/setup.*) ;; *) fail runtime_rollback_failed 'Circe found an invalid unfinished setup record.' ;; esac
        setup_restore "$previous" || fail runtime_rollback_failed 'Circe could not restore the previous desktop. Keep the setup record and ask your administrator for help.'
    fi
    SETUP_TRANSACTION=$(clean_user bash -s -- "$PACKAGE_CACHE" "$CONFIG" "$LIBEXEC" "$UNITS" "$PREFIX" <<'SNAPSHOT'
set -euo pipefail
cache=$1; config=$2; helpers=$3; units=$4; prefix=$5
umask 077
mkdir -p "$cache/transactions"
journal=$(mktemp -d "$cache/transactions/setup.XXXXXX")
[[ ! -e "$config" ]] || cp -a "$config" "$journal/config"
[[ ! -e "$helpers" ]] || cp -a "$helpers" "$journal/helpers"
for unit in circe-desktop.service circe-audio.service circe-pulse.service; do
    [[ ! -e "$units/$unit" ]] || cp -a "$units/$unit" "$journal/$unit"
done
if [[ -L "$prefix" ]]; then readlink "$prefix" > "$journal/prefix-link"
elif [[ ! -e "$prefix" ]]; then touch "$journal/prefix-absent"; fi
touch "$journal/ready"
printf '%s\n' "$journal" > "$cache/active-transaction.new"
mv -f "$cache/active-transaction.new" "$cache/active-transaction"
printf '%s' "$journal"
SNAPSHOT
    ) || fail runtime_rollback_failed 'Circe could not save the working desktop before setup. Nothing was replaced.'
    for unit in circe-desktop.service circe-audio.service circe-pulse.service; do
        if [[ -e "$UNITS/$unit" ]]; then
            if clean_user systemctl --user is-active --quiet "$unit" 2>/dev/null; then clean_user touch "$SETUP_TRANSACTION/active-$unit"; fi
            if clean_user systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then clean_user touch "$SETUP_TRANSACTION/enabled-$unit"; fi
        fi
    done
    trap 'setup_exit $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}
# Called by the EXIT trap.
# shellcheck disable=SC2329
setup_exit() {
    local status="$1"
    trap - EXIT HUP INT TERM
    set +e
    if [[ -n "${SETUP_TRANSACTION:-}" && ! -f "$SETUP_TRANSACTION/committed" ]]; then
        if ! setup_restore "$SETUP_TRANSACTION"; then
            printf 'Circe: Restoring the previous desktop failed. Its setup record is in %s; rerun setup to retry recovery.\n' "$SETUP_TRANSACTION" >&2
            status=1
        fi
    fi
    release_setup_lock
    exit "$status"
}
setup_commit() {
    clean_user touch "$SETUP_TRANSACTION/committed"
    clean_user rm -f -- "$PACKAGE_CACHE/active-transaction"
    # Backups/releases are deliberately retained. Deleting them without checking every live consumer
    # (including independent SSH audio/mic commands) would reintroduce the repair race.
}
# Starts an isolated candidate X display and window manager with TCP listening disabled. A version/help
# check alone misses missing XKB compilers, fonts and runtime loader errors. Probes never own the setup lock.
health_check_runtime() {
    clean_user timeout --kill-after=2 20 bash -s -- "$1" 8>&- <<'HEALTH'
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
work=$(mktemp -d "${TMPDIR:-/tmp}/circe-runtime-check.XXXXXX")
xpid=; wmpid=
cleanup() {
    trap - EXIT HUP INT TERM
    [[ -z "$wmpid" ]] || kill "$wmpid" 2>/dev/null || true
    [[ -z "$xpid" ]] || kill "$xpid" 2>/dev/null || true
    [[ -z "$wmpid" ]] || wait "$wmpid" 2>/dev/null || true
    [[ -z "$xpid" ]] || wait "$xpid" 2>/dev/null || true
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
pick() { command -v "$1"; }
xvnc=$(pick Xtigervnc || pick Xvnc)
passwd=$(pick tigervncpasswd || pick vncpasswd)
wm=$(pick jwm || pick openbox)
for tool in xauth xdpyinfo openssl; do command -v "$tool" >/dev/null; done
printf 'probe123\n' | "$passwd" -f > "$work/passwd"
(( $(wc -c < "$work/passwd") == 8 ))
for display in {100..199}; do
    [[ -e "/tmp/.X${display}-lock" || -S "/tmp/.X11-unix/X${display}" ]] || break
done
[[ ! -e "/tmp/.X${display}-lock" && ! -S "/tmp/.X11-unix/X${display}" ]]
export DISPLAY=":$display" XAUTHORITY="$work/authority"
touch "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$(openssl rand -hex 16)"
xkb=(); [[ -z "${CIRCE_XKBDIR:-}" ]] || xkb=(-xkbdir "$CIRCE_XKBDIR")
(cd "${CIRCE_XVNC_CWD:-$HOME}"; exec "$xvnc" "$DISPLAY" -rfbport 0 -rfbunixpath "$work/rfb.sock" -localhost=1 -interface 127.0.0.1 \
    -SecurityTypes VncAuth -PasswordFile "$work/passwd" -geometry 640x480 -depth 24 -nolisten tcp -auth "$XAUTHORITY" "${xkb[@]}") 9<&- >"$work/xvnc.log" 2>&1 &
xpid=$!
ready=false
for ((i=0; i<100; i++)); do
    kill -0 "$xpid" 2>/dev/null || { cat "$work/xvnc.log" >&2; exit 1; }
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.1
done
$ready
if [[ "${wm##*/}" == jwm ]]; then
    printf '<JWM><RootMenu><Program label="Terminal">xfce4-terminal</Program></RootMenu></JWM>\n' > "$work/jwmrc"
    "$wm" -f "$work/jwmrc" 9<&- >"$work/wm.log" 2>&1 &
else "$wm" --sm-disable 9<&- >"$work/wm.log" 2>&1 & fi
wmpid=$!
sleep 0.2
kill -0 "$wmpid" 2>/dev/null || { cat "$work/wm.log" >&2; exit 1; }
for tool in xfce4-terminal thunar; do timeout 8 "$(pick "$tool")" --version >/dev/null 2>&1; done
kill -0 "$xpid" 2>/dev/null && kill -0 "$wmpid" 2>/dev/null
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
HEALTH
}
prepare_candidate_runtime() {
    local PREFIX="$1" CONFIG="$1/.circe-runtime"
    local PREFIX_ENV="$CONFIG/prefix.env"
    prepare_private_runtime
    write_prefix_env
    health_check_runtime "$PREFIX_ENV" || fail runtime_unhealthy 'The downloaded desktop did not pass its private display test. The previous desktop has been kept.'
}
activate_private_runtime() {
    local candidate="$1"
    # Prepare directly at the immutable final path: generated absolute cache/symlink paths stay valid.
    prepare_candidate_runtime "$candidate"
    # Keep a legacy actual root directory intact for existing consumers of its absolute paths.
    # New installations use the canonical symlink, while prefix.env always pins the physical release.
    if [[ -L "$PREFIX" || ! -e "$PREFIX" ]]; then
        ln -s -- "$candidate" "$PREFIX.link.$$"
        mv -Tf -- "$PREFIX.link.$$" "$PREFIX"
    fi
    mkdir -p "$CONFIG"
    cp "$candidate/.circe-runtime/prefix.env" "$PREFIX_ENV.new"
    chmod 600 "$PREFIX_ENV.new"
    mv -f "$PREFIX_ENV.new" "$PREFIX_ENV"
}

without_admin_possible() {
    # Xvnc runs xkbcomp from a fixed /usr/bin path; without it, setup patches the private Xvnc (needs python3 or perl).
    [[ -x "${CIRCE_XKBCOMP:-/usr/bin/xkbcomp}" ]] || command -v dd >/dev/null || command -v python3 >/dev/null || return 1
    command -v systemctl >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null || return 1
    case "$(package_manager " ${ID:-} ${ID_LIKE:-} ")" in
        apt) command -v apt-get >/dev/null && command -v dpkg >/dev/null ;;
        dnf) command -v dnf >/dev/null && command -v rpm2cpio >/dev/null && command -v cpio >/dev/null && command -v rpmkeys >/dev/null ;;
        pacman) command -v pacman >/dev/null && command -v bsdtar >/dev/null && command -v curl >/dev/null && arch_verification_possible ;;
        *) return 1 ;;
    esac
}
# A public key alone does not establish package trust: pacman keeps key validity/disabled state in trustdb.
# Probe is read-only; no GPG home is opened or trust database created here.
arch_verification_possible() {
    command -v gpg >/dev/null && [[ -s /etc/pacman.d/gnupg/pubring.gpg && -r /etc/pacman.d/gnupg/pubring.gpg \
        && -s /etc/pacman.d/gnupg/trustdb.gpg && -r /etc/pacman.d/gnupg/trustdb.gpg ]]
}
prepare_arch_keyring() {
    arch_verification_possible || fail package_unverified "This computer's Arch package trust database isn't readable, or GnuPG is missing; Circe won't use unverified packages."
    # Never use the administrator's home in place: verification can refresh trustdb. Copy public material only,
    # excluding gpg.conf, secret keys, agent sockets and automatic key-fetch configuration.
    ARCH_KEYRING="$PACKAGE_CACHE/arch-gnupg"
    rm -rf -- "$ARCH_KEYRING"
    mkdir -m 700 -- "$ARCH_KEYRING" || fail package_unverified "Circe couldn't prepare a private copy of Arch's package trust database."
    cp /etc/pacman.d/gnupg/pubring.gpg /etc/pacman.d/gnupg/trustdb.gpg "$ARCH_KEYRING/" \
        || fail package_unverified "Circe couldn't copy Arch's package trust database; no packages were used."
    chmod 600 "$ARCH_KEYRING/pubring.gpg" "$ARCH_KEYRING/trustdb.gpg" \
        || fail package_unverified "Circe couldn't secure its private Arch package trust database."
}
verify_arch_package() {
    local package="$1" status fingerprints signer primary listing
    local options=(--no-options --homedir "$ARCH_KEYRING" --batch --no-tty --no-autostart \
        --no-auto-key-retrieve --no-auto-key-import --trust-model pgp)
    [[ -s "$package.sig" ]] || fail package_unverified "Couldn't get the signature for ${package##*/}, so Circe won't use it."
    # A successful exit/VALIDSIG alone also occurs for expired or revoked signers. Require one good signature
    # and its computed full/ultimate trust; reject every unusable-key/signature or verification-error status.
    if ! status="$(LC_ALL=C gpg "${options[@]}" --status-fd 1 --verify "$package.sig" "$package" 2>/dev/null)"; then
        fail package_unverified "The signature of ${package##*/} couldn't be verified with this computer's Arch package trust database."
    fi
    if ! fingerprints="$(awk '
        $1 == "[GNUPG:]" {
            code=$2
            if (code == "NEWSIG") signatures++
            if (code == "GOODSIG") good++
            if (code == "VALIDSIG") {
                valid++; signer=$3; primary=(NF >= 12 ? $12 : $3)
                if (NF < 11) bad=1
                if ((length(signer) != 40 && length(signer) != 64) || signer ~ /[^0-9A-Fa-f]/ ||
                    (length(primary) != 40 && length(primary) != 64) || primary ~ /[^0-9A-Fa-f]/) bad=1
            }
            if (code == "TRUST_FULLY" || code == "TRUST_ULTIMATE") trusted++
            else if (code ~ /^TRUST_/) bad=1
            if (code ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|SIGEXPIRED|NO_PUBKEY|FAILURE|ERROR|NODATA|BADARMOR|UNEXPECTED)$/) bad=1
        }
        END { if (!bad && signatures == 1 && good == 1 && valid == 1 && trusted == 1) print signer, primary; else exit 1 }
        ' <<< "$status")"; then
        fail package_unverified "${package##*/} isn't signed by a valid, fully trusted Arch package signer; Circe won't use it."
    fi
    read -r signer primary <<< "$fingerprints"
    # Arch can disable a key through trustdb without a cryptographic revocation. Check that flag and computed
    # validity for both the primary key and the exact signing subkey, not merely the displayed user identity.
    if ! listing="$(LC_ALL=C gpg "${options[@]}" --with-colons --fixed-list-mode --fingerprint --fingerprint --list-keys "$primary" 2>/dev/null)" \
        || ! awk -F: -v signer="$signer" -v primary="$primary" '
            $1 == "pub" || $1 == "sub" { kind=$1; validity=$2; capabilities=$12 }
            $1 == "fpr" && ($10 == signer || $10 == primary) {
                if ($10 == signer) signerFound=1
                if ($10 == primary && kind == "pub") primaryFound=1
                if (validity !~ /^[fu]$/ || capabilities ~ /D/) bad=1
            }
            END { exit !(signerFound && primaryFound && !bad) }
            ' <<< "$listing"; then
        fail package_unverified "The signer of ${package##*/} is disabled, expired, revoked or not fully trusted in this computer's Arch package policy."
    fi
}
self_linger_allowed() {
    # polkit's org.freedesktop.login1.set-self-linger lets users keep their own services running (Ubuntu, Arch, …).
    grep -A6 'set-self-linger' /usr/share/polkit-1/actions/org.freedesktop.login1.policy 2>/dev/null | grep -qE '<allow_(any|active)>yes'
}
# The variables are expanded when prefix.env is sourced, not now.
# shellcheck disable=SC2016
write_prefix_env() {
    local libs="" dir
    for dir in usr/lib/x86_64-linux-gnu usr/lib/aarch64-linux-gnu lib/x86_64-linux-gnu lib/aarch64-linux-gnu usr/lib64 usr/lib; do
        [[ -d "$PREFIX/$dir" ]] && libs+="${libs:+:}$PREFIX/$dir"
        # libpulse finds libpulsecommon (and the daemon libpulsecore) through a built-in /usr path.
        [[ -d "$PREFIX/$dir/pulseaudio" ]] && libs+=":$PREFIX/$dir/pulseaudio"
    done
    # Only used without administrator access, so this runs as the desktop account itself.
    mkdir -p "$CONFIG"; chmod 700 "$CONFIG"
    local temp; temp="$(mktemp "$PREFIX_ENV.XXXXXX")"
    {
        printf '# Written by Circe: programs installed without administrator access.\n'
        printf 'export CIRCE_PREFIX=%q\n' "$PREFIX"
        # After the system's own directories: private tools only fill gaps and never replace the computer's
        # programs (a private systemctl or loginctl, say, would not match the running systemd).
        printf 'export PATH="$PATH":%q:%q\n' "$PREFIX/usr/bin" "$PREFIX/usr/sbin"
        printf 'export LD_LIBRARY_PATH=%q"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$libs"
        printf 'export XDG_DATA_DIRS=%q:"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"\n' "$PREFIX/usr/share"
        printf 'export XDG_CONFIG_DIRS=%q:"${XDG_CONFIG_DIRS:-/etc/xdg}"\n' "$PREFIX/etc/xdg"
        if [[ -d "$PREFIX/usr/share/glib-2.0/schemas" ]]; then printf 'export GSETTINGS_SCHEMA_DIR=%q\n' "$PREFIX/usr/share/glib-2.0/schemas"; fi
        [[ -r "$CONFIG/fonts.conf" ]] && printf 'export FONTCONFIG_FILE=%q\n' "$CONFIG/fonts.conf"
        [[ -s "$CONFIG/pixbuf-loaders.cache" ]] && printf 'export GDK_PIXBUF_MODULE_FILE=%q\n' "$CONFIG/pixbuf-loaders.cache"
        # Keyboard data: the system's if present, else the private copy (Xvnc gets -xkbdir in start-desktop).
        [[ ! -d /usr/share/X11/xkb && -d "$PREFIX/usr/share/X11/xkb" ]] && printf 'export CIRCE_XKBDIR=%q\n' "$PREFIX/usr/share/X11/xkb"
        [[ -e "$PREFIX/.circe/xkbcomp" ]] && printf 'export CIRCE_XVNC_CWD=%q\n' "$PREFIX"
    } > "$temp"
    chmod 600 "$temp"; mv -f -- "$temp" "$PREFIX_ENV"
}
# A newer C library can't be used from a private folder (the system's loader and every program would mix
# versions), so a computer that needs one has to be updated by whoever manages it.
refuse_core_upgrade() {
    local item
    for item in "$@"; do
        case "${item##*/}" in
            libc6=*|libc-bin=*|libc6_*|glibc-[0-9]*|glibc-common-*|glibc-minimal-langpack-*|glibc-all-langpacks-*)
                fail system_outdated "This computer is missing system updates the desktop needs (a newer C library). Ask whoever manages it to install updates, then try again." ;;
        esac
    done
}
# The light desktop: JWM where the distribution packages it, else Openbox with the tint2 taskbar.
light_wm_packages() {
    shift
    if "$@" jwm >/dev/null 2>&1; then printf 'jwm'; else printf 'openbox tint2'; fi
}
# A cloud image's mirror can be missing files (Google Cloud's regional Ubuntu mirrors answer 503 now and then):
# fetch what apt couldn't from the distribution's main archive, accepted only when it matches the SHA-256 in the
# package list apt verified. Uses "options" from the caller.
fetch_from_main_archive() {
    local name record path sum base file
    case " ${ID:-} ${ID_LIKE:-} " in
        *ubuntu*) case "$(dpkg --print-architecture 2>/dev/null)" in
                      amd64|i386) base=http://archive.ubuntu.com/ubuntu ;;
                      *) base=http://ports.ubuntu.com/ubuntu-ports ;;
                  esac ;;
        *debian*) base=http://deb.debian.org/debian ;;
        *) return 1 ;;
    esac
    command -v curl >/dev/null && command -v sha256sum >/dev/null || return 1
    for name in "$@"; do
        record="$(apt-cache "${options[@]}" show "$name" 2>/dev/null)" || return 1
        path="$(awk '/^Filename: / { print $2; exit }' <<< "$record")"
        sum="$(awk '/^SHA256: / { print $2; exit }' <<< "$record")"
        [[ "$path" == pool/* && "$path" != *..* && "$sum" =~ ^[0-9a-f]{64}$ ]] || return 1
        file="$PACKAGE_CACHE/debs/${path##*/}"
        if [[ -f "$file" && "$(sha256sum "$file" | awk '{ print $1 }')" == "$sum" ]]; then continue; fi
        # An apt download of the same package (named with its epoch) is replaced by the checked copy.
        rm -f "$PACKAGE_CACHE/debs/${name%%=*}_"*.deb
        curl -fsSL --retry 2 --max-time 300 -o "$file.part" "$base/$path" </dev/null || { rm -f "$file.part"; return 1; }
        [[ "$(sha256sum "$file.part" | awk '{ print $1 }')" == "$sum" ]] || { rm -f "$file.part"; return 1; }
        mv -f "$file.part" "$file"
    done
}
install_without_admin() {
    local manager="$1" names=() file url wm packages=() optional=() free target
    shift
    # OPTIONAL:name is a nice-to-have (sharing an open desktop): setup goes on without it if it can't be had.
    for wm in "$@"; do
        case "$wm" in LIGHT_WM) ;; OPTIONAL:*) optional+=("${wm#OPTIONAL:}") ;; *) packages+=("$wm") ;; esac
    done
    mkdir -p "$PACKAGE_CACHE"
    free="$(df -Pk "$TARGET_HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    if [[ "$free" =~ ^[0-9]+$ ]] && ((free < 2000000)); then
        fail disk_full "The desktop needs about 2 GB of free space in $TARGET_HOME; $((free / 1024)) MB is free."
    fi
    # An uncommitted immutable release. Its final physical path never changes after preparation.
    mkdir -p "$TARGET_HOME/.local/share/circe/runtimes"
    target=$(mktemp -d "$TARGET_HOME/.local/share/circe/runtimes/runtime.XXXXXX")
    case "$manager" in
        apt)
            local options=(-o "Dir::State::Lists=$PACKAGE_CACHE/lists" -o "Dir::Cache=$PACKAGE_CACHE" -o Debug::NoLocking=1)
            mkdir -p "$PACKAGE_CACHE/lists/partial" "$PACKAGE_CACHE/archives/partial" "$PACKAGE_CACHE/debs"
            printf 'Refreshing the package list (as %s)…\n' "$TARGET_USER"
            apt-get "${options[@]}" update </dev/null >/dev/null 2>"$PACKAGE_CACHE/update.log" \
                || fail package_download_failed "Couldn't refresh the package list: $(tail -1 "$PACKAGE_CACHE/update.log")"
            # shellcheck disable=SC2207
            packages+=($(light_wm_packages apt apt-cache "${options[@]}" show))
            # Simulating an install as the user lists exactly what this system is missing (and which versions).
            local plan unavailable wanted=("${packages[@]}" ${optional[@]+"${optional[@]}"}) attempt
            for attempt in with-optional required-only; do
                names=()
                if ! plan="$(apt-get "${options[@]}" -s install --no-install-recommends "${wanted[@]}" </dev/null 2>&1)"; then
                    if [[ "$attempt" == with-optional ]] && ((${#optional[@]})); then wanted=("${packages[@]}"); continue; fi
                    unavailable="$(sed -nE 's/^E: Unable to locate package (.*)/\1/p' <<< "$plan" | head -1)"
                    [[ -n "$unavailable" ]] && fail package_unavailable "This computer's software sources don't offer $unavailable, which the desktop needs."
                    fail package_unavailable "This computer's software sources can't provide the desktop: $(grep -E '^E:' <<< "$plan" | tail -1)"
                fi
                while read -r url; do [[ -n "$url" ]] && names+=("$url"); done < <(sed -nE 's/^Inst ([^ ]+) (\[[^]]*\] )?\(([^ ]+) .*/\1=\3/p' <<< "$plan")
                rm -f "$PACKAGE_CACHE"/debs/*.deb
                ((${#names[@]} == 0)) || refuse_core_upgrade "${names[@]}"
                ((${#names[@]})) || break
                printf 'Downloading %d packages…\n' "${#names[@]}"
                # apt checks every file against the signed package lists it just refreshed.
                if (cd "$PACKAGE_CACHE/debs" && apt-get "${options[@]}" -o Acquire::Retries=3 download "${names[@]}" </dev/null >/dev/null); then break; fi
                if fetch_from_main_archive "${names[@]}"; then printf "Some packages came from the distribution's main archive (this computer's mirror was missing them).\n"; break; fi
                if [[ "$attempt" == with-optional ]] && ((${#optional[@]})); then
                    printf "Couldn't download everything; continuing without the optional %s.\n" "${optional[*]}"
                    wanted=("${packages[@]}"); continue
                fi
                fail package_download_failed "Downloading the desktop packages failed. Check the computer's internet access, then try again."
            done
            for file in "$PACKAGE_CACHE"/debs/*.deb; do [[ -f "$file" ]] && dpkg -x "$file" "$target"; done ;;
        dnf)
            mkdir -p "$PACKAGE_CACHE/rpms" "$PACKAGE_CACHE/dnf"; rm -f "$PACKAGE_CACHE"/rpms/*.rpm
            # Reuse the system's repository metadata when it's readable: the first user-level download is slow.
            if [[ -z "$(ls -A "$PACKAGE_CACHE/dnf" 2>/dev/null)" && -r /var/cache/dnf ]]; then cp -a /var/cache/dnf/. "$PACKAGE_CACHE/dnf/" 2>/dev/null || true; fi
            local dnf_options=(-q --setopt=cachedir="$PACKAGE_CACHE/dnf" --setopt=install_weak_deps=False)
            printf 'Checking the package list (as %s)…\n' "$TARGET_USER"
            # shellcheck disable=SC2207
            packages+=($(light_wm_packages dnf dnf "${dnf_options[@]}" list --available))
            printf 'Downloading packages…\n'
            dnf "${dnf_options[@]}" download --resolve --destdir "$PACKAGE_CACHE/rpms" "${packages[@]}" </dev/null 2>"$PACKAGE_CACHE/dnf.log" || {
                url="$(sed -nE 's/^(Error: )?No (package|match for argument:?) ([^ ]+).*/\3/p' "$PACKAGE_CACHE/dnf.log" | head -1)"
                [[ -n "$url" ]] && fail package_unavailable "This computer's software sources don't offer $url, which the desktop needs. On RHEL/Rocky/Alma it usually comes from EPEL."
                fail package_download_failed "Downloading the desktop packages failed: $(tail -1 "$PACKAGE_CACHE/dnf.log")"
            }
            # `dnf download` doesn't check signatures, so check each package against the keys the administrator
            # installed for this system's repositories (a private key database; nothing system-wide changes).
            refuse_core_upgrade "$PACKAGE_CACHE"/rpms/*.rpm
            local keys="$PACKAGE_CACHE/rpmkeys" key verdict
            rm -rf -- "$keys"; mkdir -p "$keys"
            rpm --dbpath "$keys" --initdb 2>/dev/null || true
            for key in /etc/pki/rpm-gpg/*; do [[ -f "$key" ]] && rpmkeys --dbpath "$keys" --import "$key" 2>/dev/null; done
            for file in "$PACKAGE_CACHE"/rpms/*.rpm; do
                verdict="$(rpmkeys --dbpath "$keys" --checksig "$file" 2>&1)" && [[ "$verdict" == *"signatures OK"* ]] \
                    || fail package_unverified "${file##*/} isn't signed by a key this computer trusts, so Circe won't use it."
                (cd "$target" && rpm2cpio "$file" | cpio -idm --quiet)
            done ;;
        pacman)
            mkdir -p "$PACKAGE_CACHE/pkgs"; rm -f "$PACKAGE_CACHE"/pkgs/*
            # Uses the existing package list (never -Sy: a partial upgrade); trust is copied, never mutated globally.
            prepare_arch_keyring
            local listing
            # shellcheck disable=SC2207
            packages+=($(light_wm_packages pacman pacman -Si))
            listing="$(pacman -Sp --needed "${packages[@]}" </dev/null 2>"$PACKAGE_CACHE/pacman.log")" || {
                url="$(sed -nE "s/^error: target not found: (.*)/\1/p" "$PACKAGE_CACHE/pacman.log" | head -1)"
                [[ -n "$url" ]] && fail package_unavailable "This computer's software sources don't offer $url, which the desktop needs."
                fail package_download_failed 'The package list is out of date. Update the system first (omarchy-update on Omarchy), then try again.'
            }
            while read -r url; do [[ -n "$url" ]] && names+=("$url"); done <<< "$listing"
            ((${#names[@]} == 0)) || refuse_core_upgrade "${names[@]}"
            printf 'Downloading %d packages…\n' "${#names[@]}"
            for url in "${names[@]}"; do
                file="$PACKAGE_CACHE/pkgs/${url##*/}"
                case "$url" in
                    file://*) cp "${url#file://}" "$file"; cp "${url#file://}.sig" "$file.sig" 2>/dev/null || rm -f "$file.sig" ;;
                    https://*)
                        curl -fsSL -o "$file" "$url" || fail package_download_failed "Couldn't download ${url##*/}."
                        curl -fsSL -o "$file.sig" "$url.sig" 2>/dev/null || rm -f "$file.sig" ;;
                    *) fail package_download_failed "Refusing a package that isn't from a secure source: $url" ;;
                esac
                verify_arch_package "$file"
                bsdtar -xf "$file" -C "$target" --exclude .PKGINFO --exclude .MTREE --exclude .BUILDINFO --exclude .INSTALL
            done ;;
    esac
    activate_private_runtime "$target"
}

# Things a desktop normally finds under /etc and /usr that a fresh server image doesn't have.
prepare_private_runtime() {
    local libs="" dir loaders xvnc
    mkdir -p "$CONFIG" "$TARGET_HOME/.cache/circe"; chmod 700 "$CONFIG"
    for dir in usr/lib/x86_64-linux-gnu usr/lib/aarch64-linux-gnu usr/lib64 usr/lib; do [[ -d "$PREFIX/$dir" ]] && libs+="${libs:+:}$PREFIX/$dir"; done
    # Packages were unpacked, not installed, so do what their install scripts would have: (1) absolute symlinks
    # into /usr that the system doesn't have, but the private copy does, now point into the private copy;
    local link target
    while IFS= read -r -d '' link; do
        target="$(readlink "$link")"
        [[ "$target" == /* && ! -e "$target" && -e "$PREFIX$target" ]] && ln -sfn "$PREFIX$target" "$link"
    done < <(find "$PREFIX" -type l -print0 2>/dev/null)
    # (2) build the caches a desktop looks things up in (file types, settings schemas, icons), with private tools.
    private_tool() { local tool="$1"; shift; if [[ -x "$PREFIX/usr/bin/$tool" ]]; then LD_LIBRARY_PATH="$libs" "$PREFIX/usr/bin/$tool" "$@"; elif command -v "$tool" >/dev/null; then "$tool" "$@"; fi; }
    [[ -d "$PREFIX/usr/share/mime/packages" ]] && private_tool update-mime-database "$PREFIX/usr/share/mime" >/dev/null 2>&1
    [[ -d "$PREFIX/usr/share/glib-2.0/schemas" ]] && private_tool glib-compile-schemas "$PREFIX/usr/share/glib-2.0/schemas" >/dev/null 2>&1
    for dir in "$PREFIX"/usr/share/icons/*/; do [[ -f "$dir/index.theme" ]] && private_tool gtk-update-icon-cache -q -f -t "$dir" >/dev/null 2>&1; done
    # Fonts: fontconfig reads /etc/fonts; point it at a config that includes the private fonts too.
    if [[ ! -r /etc/fonts/fonts.conf || -d "$PREFIX/usr/share/fonts" ]]; then
        {
            printf '<?xml version="1.0"?>\n<!DOCTYPE fontconfig SYSTEM "fonts.dtd">\n<fontconfig>\n'
            [[ -r /etc/fonts/fonts.conf ]] && printf '  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>\n'
            [[ -r "$PREFIX/etc/fonts/fonts.conf" && ! -r /etc/fonts/fonts.conf ]] && printf '  <include ignore_missing="yes">%s</include>\n' "$PREFIX/etc/fonts/fonts.conf"
            printf '  <dir>%s</dir>\n  <dir>/usr/share/fonts</dir>\n  <cachedir>%s</cachedir>\n' "$PREFIX/usr/share/fonts" "$TARGET_HOME/.cache/circe/fontconfig"
            # Generic families, in case the distribution's alias rules aren't available.
            printf '  <alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family></prefer></alias>\n'
            printf '  <alias><family>sans-serif</family><prefer><family>DejaVu Sans</family></prefer></alias>\n'
            printf '  <alias><family>serif</family><prefer><family>DejaVu Serif</family></prefer></alias>\n</fontconfig>\n'
        } > "$CONFIG/fonts.conf"
    fi
    # Images and icons: GTK's image loaders are listed in a cache with absolute paths; build one for the prefix.
    local query="" candidate
    loaders=""
    for candidate in "$PREFIX"/usr/lib/*/gdk-pixbuf-2.0/2.10.0/loaders "$PREFIX"/usr/lib*/gdk-pixbuf-2.0/2.10.0/loaders; do [[ -d "$candidate" ]] && { loaders="$candidate"; break; }; done
    for candidate in "$PREFIX"/usr/lib/*/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders "$PREFIX"/usr/bin/gdk-pixbuf-query-loaders*; do [[ -x "$candidate" ]] && { query="$candidate"; break; }; done
    if [[ -n "$loaders" && -n "$query" ]]; then
        LD_LIBRARY_PATH="$libs" GDK_PIXBUF_MODULEDIR="$loaders" "$query" > "$CONFIG/pixbuf-loaders.cache" 2>/dev/null || rm -f "$CONFIG/pixbuf-loaders.cache"
    fi
    # Keyboard: Xvnc runs "/usr/bin/xkbcomp" (a path built into it). Without one on the system, point the private
    # copy at "./.circe/xkbcomp" — the same length, relative to the folder start-desktop runs it from.
    xvnc="$PREFIX/usr/bin/Xtigervnc"; [[ -x "$xvnc" ]] || xvnc="$PREFIX/usr/bin/Xvnc"
    if [[ ! -x /usr/bin/xkbcomp && -x "$xvnc" && -x "$PREFIX/usr/bin/xkbcomp" ]]; then
        local patcher='import sys
p = sys.argv[1]; d = open(p, "rb").read()
if d.count(b"./.circe\0") == 1: sys.exit(0)
if d.count(b"/usr/bin\0") != 1: sys.exit(3)
open(p + ".tmp", "wb").write(d.replace(b"/usr/bin\0", b"./.circe\0"))'
        local offsets
        offsets="$(LC_ALL=C grep -obUaP '/usr/bin\x00' "$xvnc" 2>/dev/null | cut -d: -f1)"
        if [[ -n "$offsets" && "$offsets" != *$'\n'* ]]; then
            # Exactly one occurrence: overwrite those 8 bytes in a copy (GNU grep + dd, present everywhere).
            cp "$xvnc" "$xvnc.tmp" && printf './.circe' | dd of="$xvnc.tmp" bs=1 seek="$offsets" conv=notrunc status=none \
                || fail without_admin_unsupported "Circe couldn't adapt its private VNC server."
        elif LC_ALL=C grep -qaP '\./\.circe\x00' "$xvnc" 2>/dev/null; then :
        elif command -v python3 >/dev/null; then python3 -c "$patcher" "$xvnc"
        else perl -0777 -e 'my $p=$ARGV[0]; open(F,"<",$p) or exit 2; binmode F; local $/; my $d=<F>; close F;
                exit 0 if (() = $d =~ m{\./\.circe\0}g) == 1; exit 3 unless (() = $d =~ m{/usr/bin\0}g) == 1;
                $d =~ s{/usr/bin\0}{./.circe\0}; open(O,">","$p.tmp") or exit 2; binmode O; print O $d; close O' "$xvnc"; fi \
            || fail without_admin_unsupported "This computer has no keyboard compiler (xkbcomp) and Circe couldn't adapt its private VNC server."
        if [[ -e "$xvnc.tmp" ]]; then chmod 755 "$xvnc.tmp"; mv -f "$xvnc.tmp" "$xvnc"; fi
        mkdir -p "$PREFIX/.circe"; ln -sf ../usr/bin/xkbcomp "$PREFIX/.circe/xkbcomp"
    fi
}

json_string() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//[$'\t\n\r']/ }"
    printf '"%s"' "${value//[[:cntrl:]]/}"
}
package_manager() {
    case "$1" in
        *debian*|*ubuntu*) printf apt ;;
        *rhel*|*fedora*|*rocky*|*almalinux*|*centos*) printf dnf ;;
        *arch*) printf pacman ;;
        *) printf none ;;
    esac
}
# The computer's own desktop: the X11 session its login screen, RDP (xrdp) or Chrome Remote Desktop offers, so
# Circe shows the same desktop and apps. Prints "id name DesktopNames Exec" (separated by \037) for the best one.
# Wayland-only sessions (no xsessions entry) can't run inside Xvnc. Also written out as Circe's system-session helper.
find_system_session() {
    local dirs="${CIRCE_XSESSIONS:-/usr/local/share/xsessions:/usr/share/xsessions}" dir file id line section seen=":"
    local name exec tryexec names hidden words program rank best_rank=1000 best="" i
    local IFS=:
    for dir in $dirs; do
        IFS=$' \t\n'
        for file in "$dir"/*.desktop; do
            [[ -f "$file" && -r "$file" ]] || continue
            id="${file##*/}"; id="${id%.desktop}"
            [[ "$seen" != *":$id:"* ]] || continue
            seen+="$id:"
            # Entries that run the account's own ~/.xsession, or a bare fallback, aren't a desktop to pick.
            case "$id" in default|custom|user-xsession|xinit-compat|lightdm-xsession|xsession|*failsafe*) continue ;; esac
            name=""; exec=""; tryexec=""; names=""; hidden=false; section=""
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%$'\r'}"
                case "$line" in
                    '['*']') section="$line"; continue ;;
                esac
                [[ "$section" == '[Desktop Entry]' ]] || continue
                case "$line" in
                    Name=*) name="${line#Name=}" ;;
                    Exec=*) exec="${line#Exec=}" ;;
                    TryExec=*) tryexec="${line#TryExec=}" ;;
                    DesktopNames=*) names="${line#DesktopNames=}" ;;
                    Hidden=true|NoDisplay=true) hidden=true ;;
                esac
            done < "$file"
            if [[ -z "$exec" ]] || $hidden; then continue; fi
            if [[ -n "$tryexec" ]] && ! command -v "$tryexec" >/dev/null 2>&1; then continue; fi
            read -r -a words <<< "$exec"
            i=0
            if [[ "${words[0]##*/}" == env ]]; then i=1; while [[ "${words[i]:-}" == *=* ]]; do i=$((i + 1)); done; fi
            program="${words[i]:-}"
            if [[ -z "$program" ]] || ! command -v "$program" >/dev/null 2>&1; then continue; fi
            # Full desktops first, the distribution's own flavor before the generic one; a window manager the
            # account chose (i3, Openbox…) is still the computer's desktop.
            case "$id" in
                ubuntu) rank=0 ;; ubuntu-xorg) rank=1 ;;
                pop|zorin*|elementary|pantheon) rank=5 ;;
                gnome-xorg) rank=10 ;; gnome) rank=11 ;; gnome*) rank=12 ;;
                plasmax11|plasma-x11) rank=20 ;; plasma*|kde*) rank=21 ;;
                cinnamon) rank=30 ;; cinnamon*) rank=31 ;;
                mate*) rank=40 ;; budgie*) rank=50 ;; xfce*) rank=60 ;;
                lxqt*|lxde*|LXDE*) rank=70 ;;
                *) rank=100 ;;
            esac
            if ((rank < best_rank)); then
                best_rank=$rank
                best="$id"$'\037'"${name//$'\037'/ }"$'\037'"${names//$'\037'/ }"$'\037'"${exec//$'\037'/ }"
            fi
        done
        IFS=:
    done
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}
# Which open session Circe's running desktop is showing (chrome-remote-desktop or rdp), if any.
shared_session_kind() {
    [[ -n "${RUNTIME:-}" && -r "$RUNTIME/circe/desktop.env" ]] || return 0
    sed -nE 's/^CIRCE_SHARED_KIND=(chrome-remote-desktop|rdp)$/\1/p' "$RUNTIME/circe/desktop.env" | head -1
}
probe() {
    local ID="" ID_LIKE="" PRETTY_NAME="" manager sudo_mode=none sudo_error admin=false installed=false running=false
    local display=null vnc="" sessions="" line address port process comm loopback rfb host xdisplays="" socket
    # shellcheck disable=SC1091
    if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
    manager="$(package_manager " ${ID:-} ${ID_LIKE:-} ")"
    if [[ "$manager" != none ]] && ! command -v "$manager" >/dev/null; then manager=none; fi
    if ((EUID == 0)); then sudo_mode=root
    elif command -v sudo >/dev/null; then
        if sudo -n true 2>/dev/null; then sudo_mode=passwordless
        else
            sudo_error="$(LC_ALL=C sudo -n true 2>&1 || true)"
            [[ "$sudo_error" == *"password is required"* ]] && sudo_mode=password
        fi
    fi
    if id -Gn "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then admin=true; fi
    local current=false shared=""
    if [[ -f "$CONFIG/host.conf" ]]; then
        installed=true; display="$DISPLAY_NUMBER"
        [[ "$(awk -F= '/^SETUP_GENERATION=[0-9]+$/ { print $2; exit }' "$CONFIG/host.conf")" == "$SETUP_GENERATION" ]] && current=true
        shared="$(shared_session_kind)"
        if as_user systemctl --user is-active --quiet circe-desktop.service 2>/dev/null; then running=true; fi
    fi
    if command -v ss >/dev/null; then
        while read -r line; do
            address="$(awk '{ print $4 }' <<< "$line")"; port="${address##*:}"
            [[ "$port" =~ ^59[0-9][0-9]$ ]] || continue
            process="$(sed -nE 's/.*users:\(\("([^"]+)".*/\1/p' <<< "$line")"
            address="${address%:*}"
            case "$address" in 127.0.0.1|"[::1]"|::1) loopback=true ;; *) loopback=false ;; esac
            # Read only the 12-byte RFB greeting (no sign-in, no pixels) to confirm the port is a VNC server.
            host=127.0.0.1; [[ "$address" == *::1* ]] && host=::1
            rfb=false
            # shellcheck disable=SC2016 # $0/$1 are the inner shell's arguments
            if [[ "$(timeout 2 bash -c 'exec 3<>"/dev/tcp/$0/$1" && head -c 12 <&3' "$host" "$port" 2>/dev/null || true)" =~ ^RFB\ [0-9]{3}\.[0-9]{3} ]]; then rfb=true; fi
            vnc+="${vnc:+,}{\"port\":$port,\"display\":$((port - 5900)),\"address\":$(json_string "$address"),\"loopback\":$loopback,\"rfb\":$rfb,\"process\":$(json_string "$process")}"
        done < <(ss -H -ltnp 2>/dev/null)
    fi
    for socket in /tmp/.X11-unix/X*; do
        [[ -e "$socket" && "${socket##*/X}" =~ ^[0-9]{1,3}$ ]] && xdisplays+="${xdisplays:+,}${socket##*/X}"
    done
    while read -r comm; do
        case "$comm" in
            Hyprland|gnome-shell|kwin_wayland|plasmashell|sway|xfce4-session|mate-session|cinnamon|wayvnc|x11vnc|Xvnc|Xtigervnc|xrdp|sunshine)
                [[ ",$sessions," == *",\"$comm\","* ]] || sessions+="${sessions:+,}\"$comm\"" ;;
        esac
    done < <(ps -u "$TARGET_USER" -o comm= 2>/dev/null | sort -u)
    # Only whether these services exist; no other user's process details are collected.
    if pgrep -u "$TARGET_USER" -f chrome-remote-desktop >/dev/null 2>&1; then sessions+="${sessions:+,}\"chrome-remote-desktop\""; fi
    if pgrep -x xrdp >/dev/null 2>&1 && [[ ",$sessions," != *'"xrdp"'* ]]; then sessions+="${sessions:+,}\"xrdp\""; fi
    printf 'CIRCE_PROBE_RESULT {"user":%s,"os":{"id":%s,"like":%s,"name":%s},"packageManager":"%s","sudo":"%s","adminGroup":%s,' \
        "$(json_string "$TARGET_USER")" "$(json_string "${ID:-}")" "$(json_string "${ID_LIKE:-}")" "$(json_string "${PRETTY_NAME:-}")" "$manager" "$sudo_mode" "$admin"
    printf '"withoutAdmin":%s,"selfLinger":%s,"lingering":%s,' "$(without_admin_possible && echo true || echo false)" "$(self_linger_allowed && echo true || echo false)" \
        "$([[ "$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || true)" == yes ]] && echo true || echo false)"
    local system_desktop=null session_id session_name
    if IFS=$'\037' read -r session_id session_name _ < <(find_system_session); then
        system_desktop="{\"id\":$(json_string "$session_id"),\"name\":$(json_string "${session_name:-$session_id}")}"
    fi
    printf '"systemd":%s,"ffmpeg":%s,"circe":{"installed":%s,"display":%s,"running":%s,"current":%s,"shared":%s},"vnc":[%s],"sessions":[%s],"xDisplays":[%s],"systemDesktop":%s}\n' \
        "$(command -v systemctl >/dev/null && echo true || echo false)" "$(command -v ffmpeg >/dev/null && echo true || echo false)" \
        "$installed" "$display" "$running" "$current" "$([[ -n "$shared" ]] && json_string "$shared" || echo null)" "$vnc" "$sessions" "$xdisplays" "$system_desktop"
}
# A desktop installed earlier without administrator access. Only the account itself reads its prefix.env:
# a root shell never runs or trusts files the account can write.
SETUP_BASE_PATH=$(awk -v RS=: -v private="$TARGET_HOME/.local/share/circe/" 'index($0, private) != 1 { printf "%s%s", separator, $0; separator=":" }' <<< "$PATH")
reset_runtime_environment() {
    export PATH="$SETUP_BASE_PATH"
    unset LD_LIBRARY_PATH CIRCE_PREFIX CIRCE_XKBDIR CIRCE_XVNC_CWD GSETTINGS_SCHEMA_DIR GDK_PIXBUF_MODULE_FILE FONTCONFIG_FILE XDG_DATA_DIRS XDG_CONFIG_DIRS
}
if $PROBE || $CHECK; then
    # shellcheck disable=SC1090
    if ((EUID == TARGET_UID)) && [[ -r "$PREFIX_ENV" ]]; then source "$PREFIX_ENV"; fi
    if $PROBE; then probe; exit 0; fi
    report_status; exit $?
fi
# Recover under system tools, then load the restored runtime. A failed candidate's loader variables
# must not influence recovery or tool detection on an ordinary repair.
reset_runtime_environment
acquire_setup_lock
setup_begin
read_host_settings
# shellcheck disable=SC1090
if ((EUID == TARGET_UID)) && [[ -r "$PREFIX_ENV" ]]; then source "$PREFIX_ENV"; fi
[[ -r /etc/os-release ]] || fail unsupported_distribution 'Cannot identify this Linux distribution.'
# shellcheck disable=SC1091
. /etc/os-release
FAMILY=" ${ID:-} ${ID_LIKE:-} "
command -v systemctl >/dev/null || fail not_systemd 'This installer requires a Linux VM with systemd.'
# A computer with its own desktop (GNOME, KDE…) keeps it: Circe shows that desktop and installs only TigerVNC.
SYSTEM_SESSION="$(find_system_session || true)"
# Root is only needed to install packages or enable lingering. If both are already done (e.g. restarting or
# repairing Circe's desktop), an account without sudo can still finish setup.
desktop_tools_present() {
    { command -v Xtigervnc || command -v Xvnc; } >/dev/null && { command -v tigervncpasswd || command -v vncpasswd; } >/dev/null || return 1
    [[ -n "$SYSTEM_SESSION" ]] || { command -v xfce4-session || command -v jwm || command -v openbox; } >/dev/null || return 1
    local tool; for tool in dbus-run-session xauth xdpyinfo pactl parec openssl; do command -v "$tool" >/dev/null || return 1; done
}
USERSPACE=false
NEED_ROOT=true
if $WITHOUT_ADMIN && ((EUID != 0)); then
    [[ "$(package_manager "$FAMILY")" != none ]] || fail unsupported_distribution "Circe cannot set up a desktop on ${PRETTY_NAME:-this system}."
    if [[ "$(package_manager "$FAMILY")" == pacman ]] && ! arch_verification_possible; then
        fail package_unverified "Circe needs readable Arch public keys and trust policy plus GnuPG to verify packages; no unverified packages were used."
    fi
    without_admin_possible || fail without_admin_unsupported "This computer can't get a desktop without administrator access (it needs xkbcomp and apt, dnf or pacman). Ask whoever manages it to install TigerVNC and XFCE."
    USERSPACE=true; NEED_ROOT=false
fi
if ! $USERSPACE && desktop_tools_present && [[ "$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || true)" == yes ]]; then NEED_ROOT=false; fi
if $NEED_ROOT && ((EUID != 0)); then
    command -v sudo >/dev/null || fail sudo_unavailable 'sudo is required to install packages.'
    if [[ -n "$SUDO_PASSWORD" ]]; then
        SUDO_ERROR="$(printf '%s\n' "$SUDO_PASSWORD" | LC_ALL=C sudo -k -S -p '' -v 2>&1)" || {
            case "$SUDO_ERROR" in
                *"not in the sudoers"*|*"not allowed"*|*"may not run sudo"*) fail sudo_not_allowed "This Linux account isn't allowed to install software (sudo)." ;;
                *) fail sudo_password_incorrect "The password for $TARGET_USER was not accepted by sudo." ;;
            esac
        }
        unset SUDO_ERROR
    elif [[ -t 0 && -t 2 ]]; then sudo -v || fail sudo_password_incorrect 'sudo did not accept the password.'
    elif ! sudo -n true 2>/dev/null; then
        fail sudo_password_required "Installing needs $TARGET_USER's password for sudo. In Circe, enter it when asked; in Terminal, run this script over an interactive SSH session."
    fi
fi
# The computer's own programs, not copies in Circe's private folder. Look through every PATH match:
# a previously sourced private PATH must not hide a sound server subsequently installed by an administrator.
system_command() {
    local found
    while IFS= read -r found; do
        [[ "$found" != "$PREFIX"/* && "$found" != "${CIRCE_PREFIX:-$PREFIX}"/* && "$found" != "$TARGET_HOME/.local/share/circe/"* ]] && return 0
    done < <(type -aP "$1" 2>/dev/null)
    return 1
}
select_audio_backend() {
    BACKEND=pulseaudio
    BACKEND_UNIT=pulseaudio.socket
    PRIVATE_PULSE=()
    if system_command pipewire-pulse; then
        BACKEND=pipewire-pulse; BACKEND_UNIT=pipewire-pulse.socket
    elif system_command pulseaudio; then :
    elif $USERSPACE || { ! $NEED_ROOT && [[ -r "$PREFIX_ENV" || -f "$UNITS/circe-pulse.service" ]]; }; then
        # Ordinary repair also reuses an installed private server; its mode doesn't depend on whether
        # --without-admin was supplied this time. Never ask for a nonexistent system PulseAudio socket.
        PRIVATE_PULSE=(pulseaudio); BACKEND_UNIT=circe-pulse.service
    fi
    AUDIO_PACKAGE=pulseaudio-utils
    if [[ "$BACKEND" == pulseaudio ]]; then AUDIO_PACKAGE=pulseaudio; fi
}
AUDIO_ACTIVATION_FAILED=false
select_audio_backend
if $USERSPACE; then
    # Always refresh the private copy: only missing packages are fetched, and this doubles as repair.
    if true; then
        case "$(package_manager "$FAMILY")" in
            # JWM brings its own taskbar and menu, configured by a file Circe writes (XFCE's panel and window
            # manager have /usr paths built in and don't work from a private folder). Openbox where JWM isn't packaged.
            apt) install_without_admin apt tigervnc-standalone-server tigervnc-tools OPTIONAL:tigervnc-scraping-server OPTIONAL:xclip LIGHT_WM xfce4-terminal thunar xfconf \
                     x11-utils x11-xserver-utils xauth fonts-dejavu-core pulseaudio-utils dbus-bin ${PRIVATE_PULSE[@]+"${PRIVATE_PULSE[@]}"} ;;
            dnf) install_without_admin dnf tigervnc-server-minimal LIGHT_WM xfce4-terminal Thunar xfconf \
                     xorg-x11-xauth xdpyinfo xset pulseaudio-utils dejavu-sans-fonts ${PRIVATE_PULSE[@]+"${PRIVATE_PULSE[@]}"} ;;
            pacman) install_without_admin pacman tigervnc LIGHT_WM xfce4-terminal thunar xfconf \
                     xorg-xauth xorg-xdpyinfo xorg-xset libpulse ttf-dejavu ${PRIVATE_PULSE[@]+"${PRIVATE_PULSE[@]}"} ;;
            *) fail unsupported_distribution "Circe can't install a desktop without administrator access on ${PRETTY_NAME:-this system}." ;;
        esac
        reset_runtime_environment
        # shellcheck disable=SC1090
        source "$PREFIX_ENV"
        command -v ffmpeg >/dev/null || printf "Smooth video needs FFmpeg, which isn't installed; the desktop uses VNC pixels.\n"
    fi
elif ! $NEED_ROOT; then
    printf 'Desktop software is already installed; no administrator access needed.\n'
elif [[ "$FAMILY" == *debian* || "$FAMILY" == *ubuntu* ]]; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update </dev/null
    VNC_TOOLS_PACKAGE=tigervnc-common
    if apt-cache show tigervnc-tools >/dev/null 2>&1; then VNC_TOOLS_PACKAGE=tigervnc-tools; fi
    DESKTOP_PACKAGES=(xfce4 xfce4-terminal); [[ -z "$SYSTEM_SESSION" ]] || DESKTOP_PACKAGES=()
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install \
        ${DESKTOP_PACKAGES[@]+"${DESKTOP_PACKAGES[@]}"} tigervnc-standalone-server tigervnc-common "$VNC_TOOLS_PACKAGE" dbus-x11 \
        xauth x11-utils pulseaudio-utils openssl iproute2 ca-certificates curl fonts-dejavu-core "$AUDIO_PACKAGE" </dev/null
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install ffmpeg </dev/null \
        || printf 'FFmpeg installation failed; the desktop will use VNC pixels until video is available.\n' >&2
    # Shows a desktop that's already open (Chrome Remote Desktop, RDP) instead of starting a second one.
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install tigervnc-scraping-server xclip </dev/null >/dev/null \
        || printf "TigerVNC's screen sharing isn't available; Circe starts a desktop of its own.\n" >&2
elif [[ "$FAMILY" == *rhel* || "$FAMILY" == *fedora* || "$FAMILY" == *rocky* || "$FAMILY" == *almalinux* ]]; then
    command -v dnf >/dev/null || die 'RHEL-family setup requires dnf and an enabled XFCE repository (usually EPEL/CRB).'
    DESKTOP_PACKAGES=(xfce4-session xfce4-panel xfce4-settings xfce4-terminal xfdesktop xfwm4 Thunar dbus-x11)
    [[ -z "$SYSTEM_SESSION" ]] || DESKTOP_PACKAGES=()
    if [[ "$FAMILY" != *fedora* && -z "$SYSTEM_SESSION" ]]; then
        as_root dnf -y install epel-release </dev/null || printf 'Enable EPEL/CRB for your distribution if XFCE packages are unavailable.\n' >&2
    fi
    as_root dnf -y install tigervnc-server ${DESKTOP_PACKAGES[@]+"${DESKTOP_PACKAGES[@]}"} xorg-x11-xauth xdpyinfo pulseaudio-utils \
        openssl iproute curl ca-certificates dejavu-sans-fonts "$AUDIO_PACKAGE" </dev/null || die 'Package installation failed; check EPEL/CRB availability. No VNC firewall rule is needed.'
    as_root dnf -y install ffmpeg </dev/null || printf 'FFmpeg with libx264 or NVENC is optional; enable a suitable codec repository yourself if required. VNC remains available.\n' >&2
    # The clipboard of an open session Circe shows (its screen-sharing server, x0vncserver, comes with tigervnc-server).
    as_root dnf -y install xclip </dev/null >/dev/null 2>&1 || true
elif [[ "$(package_manager "$FAMILY")" == pacman ]] && command -v pacman >/dev/null; then
    # Arch (and Omarchy, which pins its own mirror): install from the existing sync database. `pacman -Sy`
    # without a full upgrade is a partial upgrade, which Arch doesn't support, so never refresh here.
    ARCH_AUDIO_PACKAGE=libpulse
    if [[ "$BACKEND" == pulseaudio ]] && ! pacman -Qq pipewire-pulse >/dev/null 2>&1; then ARCH_AUDIO_PACKAGE=pulseaudio; fi
    DESKTOP_PACKAGES=(xfce4-session xfce4-panel xfce4-settings xfce4-terminal xfdesktop xfwm4 thunar)
    [[ -z "$SYSTEM_SESSION" ]] || DESKTOP_PACKAGES=()
    as_root pacman -S --needed --noconfirm tigervnc ${DESKTOP_PACKAGES[@]+"${DESKTOP_PACKAGES[@]}"} \
        dbus xorg-xauth xorg-xdpyinfo xorg-xset libpulse openssl iproute2 curl ca-certificates ttf-dejavu \
        "$ARCH_AUDIO_PACKAGE" </dev/null \
        || fail package_install_failed 'Package installation failed. If pacman could not download packages, update the system first (sudo pacman -Syu, or omarchy-update on Omarchy), then run setup again.'
    as_root pacman -S --needed --noconfirm ffmpeg </dev/null || printf 'FFmpeg is optional; the desktop will use VNC pixels until video is available.\n' >&2
    as_root pacman -S --needed --noconfirm xclip </dev/null >/dev/null 2>&1 || true
else fail unsupported_distribution "Unsupported distribution: ${PRETTY_NAME:-$FAMILY}. Use Debian/Ubuntu, Fedora/RHEL, or Arch, or prepare TigerVNC and XFCE manually."; fi

# A system install may have just added the selected daemon; private installs remain private.
select_audio_backend
VNC_SERVER="$(command -v Xtigervnc || command -v Xvnc)" || die 'TigerVNC X server was not installed.'
VNC_PASSWD="$(command -v tigervncpasswd || command -v vncpasswd)" || die 'TigerVNC password tool was not installed.'
desktop_tools_present || die 'The desktop software is incomplete (TigerVNC, XFCE or Openbox, xauth, xdpyinfo, pactl, parec, openssl).'
as_user mkdir -p "$CONFIG" "$LIBEXEC" "$UNITS" "$TARGET_HOME/.vnc"
as_user chmod 700 "$CONFIG" "$LIBEXEC" "$TARGET_HOME/.vnc"
write_user_file() {
    # Expansion belongs to the target user's shell; the arguments carry paths verbatim.
    # shellcheck disable=SC2016
    as_user bash -c 'set -e; temp=$(mktemp "${1}.XXXXXX"); trap '\''rm -f "$temp"'\'' EXIT; cat > "$temp"; chmod "$2" "$temp"; mv -f -- "$temp" "$1"' _ "$1" "$2"
}
RESULT_PASSWORD=null
if [[ ! -s "$PASSWORD_FILE" ]] || $RESET_PASSWORD; then
    NEW_PASSWORD="$(openssl rand -base64 6)"
    printf '%s\n' "$NEW_PASSWORD" | as_user "$VNC_PASSWD" -f | write_user_file "$PASSWORD_FILE" 600
    RESULT_PASSWORD="\"$NEW_PASSWORD\""
    # Hand the password to Circe now, so a later failure (services, linger) can't leave it unknown.
    printf 'CIRCE_SETUP_SECRET {"password":%s}\n' "$RESULT_PASSWORD"
    if [[ -t 1 ]]; then
        printf '\nNew VNC password (shown only this time): %s\nSave it; Circe asks for it on your first connection.\n\n' "$NEW_PASSWORD"
    fi
    unset NEW_PASSWORD
else
    as_user chmod 600 "$PASSWORD_FILE"
    printf 'Keeping the existing VNC password. Use --reset-password if you need a new one.\n'
fi
printf 'DISPLAY_NUMBER=%s\nGEOMETRY=%s\nVNC_SERVER=%q\nSETUP_GENERATION=%s\n' "$DISPLAY_NUMBER" "$GEOMETRY" "$VNC_SERVER" "$SETUP_GENERATION" | write_user_file "$CONFIG/host.conf" 600

write_user_file "$LIBEXEC/app-menu" 700 <<'APPS'
#!/usr/bin/env bash
# The light desktop's Applications menu: every app installed on the computer (its .desktop entries, including
# snaps and Flatpaks), grouped like other Linux menus. Generated each time the menu opens, so new apps appear.
# Usage: app-menu jwm|openbox
format="${1:-jwm}"
terminal="xfce4-terminal -x"; command -v xfce4-terminal >/dev/null || terminal="xterm -e"
dirs=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
IFS=: read -r -a data <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
for dir in ${data[@]+"${data[@]}"} /var/lib/snapd/desktop /var/lib/flatpak/exports/share "$HOME/.local/share/flatpak/exports/share"; do
    [[ -n "$dir" ]] && dirs+=("${dir%/}/applications")
done
files=()
for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for file in "$dir"/*.desktop; do [[ -f "$file" && -r "$file" ]] && files+=("$file"); done
done
xml() { local v="${1//&/&amp;}"; v="${v//</&lt;}"; v="${v//>/&gt;}"; printf '%s' "${v//\"/&quot;}"; }
entries() {
    ((${#files[@]})) || return 0
    # One line per app (unit-separated): group, name, terminal, try-exec, command. The first entry of an ID wins (the
    # account's own overrides the system's), hidden ones included.
    awk -v desktop=":${XDG_CURRENT_DESKTOP:-XFCE}:" '
    function shown_in(list,   n, i, parts) { n = split(list, parts, ";"); for (i = 1; i <= n; i++) if (parts[i] != "" && index(desktop, ":" parts[i] ":")) return 1; return 0 }
    # Field codes (%f, %U…) are for file managers; "%%" is a percent sign.
    function expand(text,   out, i, c) {
        out = ""
        for (i = 1; i <= length(text); i++) {
            c = substr(text, i, 1)
            if (c == "%") { i++; if (substr(text, i, 1) == "%") out = out "%"; continue }
            out = out c
        }
        return out
    }
    function flush(   group) {
        if (id == "" || (id in seen)) return
        seen[id] = 1
        if (type != "Application" || name == "" || command == "" || hidden) return
        if (only != "" && !shown_in(only)) return
        if (notin != "" && shown_in(notin)) return
        command = expand(command); gsub(/[ \t]+$/, "", command)
        if (cats ~ /(^|;)(Network|WebBrowser)(;|$)/) group = "Internet"
        else if (cats ~ /(^|;)Office(;|$)/) group = "Office"
        else if (cats ~ /(^|;)(Development|IDE)(;|$)/) group = "Development"
        else if (cats ~ /(^|;)Graphics(;|$)/) group = "Graphics"
        else if (cats ~ /(^|;)(AudioVideo|Audio|Video)(;|$)/) group = "Sound & Video"
        else if (cats ~ /(^|;)Game(;|$)/) group = "Games"
        else if (cats ~ /(^|;)(Education|Science)(;|$)/) group = "Education"
        else if (cats ~ /(^|;)Settings(;|$)/) group = "Settings"
        else if (cats ~ /(^|;)System(;|$)/) group = "System"
        else if (cats ~ /(^|;)Utility(;|$)/) group = "Accessories"
        else group = "Other"
        printf "%s\037%s\037%s\037%s\037%s\n", group, name, terminal, tryexec, command
    }
    FNR == 1 { flush(); id = FILENAME; sub(/.*\//, "", id); section = ""; type = ""; name = ""; command = ""; tryexec = ""; cats = ""; only = ""; notin = ""; terminal = "false"; hidden = 0 }
    { sub(/\r$/, "") }
    /^\[/ { section = $0; next }
    section != "[Desktop Entry]" { next }
    /^Type=/ { type = substr($0, 6) }
    /^Name=/ { name = substr($0, 6); gsub(/\037/, " ", name) }
    /^Exec=/ { command = substr($0, 6); gsub(/\037/, " ", command) }
    /^TryExec=/ { tryexec = substr($0, 9) }
    /^Categories=/ { cats = substr($0, 12) }
    /^OnlyShowIn=/ { only = substr($0, 12) }
    /^NotShowIn=/ { notin = substr($0, 11) }
    /^Terminal=true/ { terminal = "true" }
    /^(Hidden|NoDisplay)=true/ { hidden = 1 }
    END { flush() }' "${files[@]}" | LC_ALL=C sort -t $'\037' -k1,1 -k2,2f
}
group=""
case "$format" in openbox) printf '<openbox_pipe_menu>\n' ;; *) printf '<?xml version="1.0"?>\n<JWM>\n' ;; esac
while IFS=$'\037' read -r app_group app_name app_terminal app_try app_command; do
    if [[ -n "$app_try" ]] && ! command -v "$app_try" >/dev/null 2>&1; then continue; fi
    [[ "$app_terminal" == true ]] && app_command="$terminal $app_command"
    if [[ "$app_group" != "$group" ]]; then
        if [[ -n "$group" ]]; then case "$format" in openbox) printf '</menu>\n' ;; *) printf '</Menu>\n' ;; esac; fi
        group="$app_group"
        case "$format" in
            openbox) printf '<menu id="circe-apps-%s" label="%s">\n' "$(xml "${group// /-}")" "$(xml "$group")" ;;
            *) printf '<Menu label="%s">\n' "$(xml "$group")" ;;
        esac
    fi
    case "$format" in
        openbox) printf '<item label="%s"><action name="Execute"><command>%s</command></action></item>\n' "$(xml "$app_name")" "$(xml "$app_command")" ;;
        *) printf '<Program label="%s">%s</Program>\n' "$(xml "$app_name")" "$(xml "$app_command")" ;;
    esac
done < <(entries)
if [[ -n "$group" ]]; then case "$format" in openbox) printf '</menu>\n' ;; *) printf '</Menu>\n' ;; esac; fi
case "$format" in openbox) printf '</openbox_pipe_menu>\n' ;; *) printf '</JWM>\n' ;; esac
APPS

write_user_file "$LIBEXEC/clipboard" 700 <<'CLIPBOARD'
#!/usr/bin/env bash
# The clipboard of a session Circe's desktop is showing (Chrome Remote Desktop, RDP): its screen-sharing server
# has none, so Circe carries the clipboard over its own SSH channel. Runs only for Circe's display while it
# shows such a session (exit 69 otherwise: nothing to do). stdin "SET <base64>" lines set that session's
# clipboard; stdout "CLIP <base64>" lines report its changes. Text only, up to 1 MB.
set -u
display=""
while (($#)); do case "$1" in --display) display="${2:-}"; shift 2 ;; *) shift ;; esac; done
settings="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/circe/desktop.env"
config="$HOME/.config/circe/host.conf"
[[ -r "$settings" && -r "$config" ]] || exit 69
grep -qx "DISPLAY_NUMBER=$display" "$config" || exit 69
# shellcheck disable=SC1090
source "$settings"
[[ "${CIRCE_SHARED_DISPLAY:-}" =~ ^[0-9]+$ ]] || exit 69
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
command -v xclip >/dev/null || exit 69
export DISPLAY=":$CIRCE_SHARED_DISPLAY" XAUTHORITY="${CIRCE_SHARED_XAUTHORITY:-$HOME/.Xauthority}"
state="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/circe-clipboard.XXXXXX")" || exit 1
poller=
trap '[[ -z "$poller" ]] || kill "$poller" 2>/dev/null; rm -rf "$state"' EXIT
trap 'exit 0' HUP INT TERM
current() { timeout 2 xclip -o -selection clipboard -t UTF8_STRING 2>/dev/null | head -c 1048576 | base64 | tr -d '\n'; }
current > "$state/last"
(
    trap - EXIT
    while sleep 0.5; do
        now="$(current)"
        [[ -n "$now" && "$now" != "$(cat "$state/last" 2>/dev/null)" ]] || continue
        printf '%s' "$now" > "$state/last"
        printf 'CLIP %s\n' "$now"
    done
) &
poller=$!
printf 'CIRCE_CLIPBOARD_READY\n'
while IFS= read -r line; do
    [[ "$line" == "SET "* ]] || continue
    data="${line#SET }"
    [[ "$data" =~ ^[A-Za-z0-9+/=]*$ ]] || continue
    # Remembered first, so the change isn't echoed back to the Mac. xclip stays in the background to
    # serve the text, as a copying app would.
    printf '%s' "$data" > "$state/last"
    printf '%s' "$data" | base64 -d 2>/dev/null | xclip -selection clipboard -i >/dev/null 2>&1
done
CLIPBOARD

write_user_file "$LIBEXEC/light-session" 700 <<'LIGHT'
#!/usr/bin/env bash
# A small desktop for computers set up without administrator access: JWM (taskbar, menu, clock) with XFCE's
# terminal and file manager. Everything comes from PATH, so it works from Circe's private folder.
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
for candidate in "${CIRCE_PREFIX:-/nonexistent}"/usr/lib/*/xfce4/xfconf/xfconfd "${CIRCE_PREFIX:-/nonexistent}"/usr/lib/xfce4/xfconf/xfconfd \
                 "${CIRCE_PREFIX:-/nonexistent}"/usr/libexec/xfce4/xfconf/xfconfd /usr/lib/*/xfce4/xfconf/xfconfd /usr/lib/xfce4/xfconf/xfconfd /usr/libexec/xfce4/xfconf/xfconfd; do
    # D-Bus can't launch xfconfd from the private folder, so start it before Thunar asks for it.
    if [[ -x "$candidate" ]]; then "$candidate" & break; fi
done
terminal=xfce4-terminal; command -v "$terminal" >/dev/null || terminal=xterm
files=thunar
browser=""
for candidate in google-chrome google-chrome-stable chromium chromium-browser firefox; do command -v "$candidate" >/dev/null && { browser="$candidate"; break; }; done
if command -v jwm >/dev/null; then
    config="$HOME/.config/circe/jwmrc"
    {
        printf '<?xml version="1.0"?>\n<JWM>\n'
        printf '  <RootMenu onroot="123">\n    <Dynamic label="Applications">exec:%s jwm</Dynamic>\n    <Separator/>\n' "$HOME/.local/libexec/circe/app-menu"
        printf '    <Program label="Terminal">%s</Program>\n    <Program label="Files">%s</Program>\n' "$terminal" "$files"
        [[ -n "$browser" ]] && printf '    <Program label="Web browser">%s</Program>\n' "$browser"
        printf '    <Separator/>\n    <Restart label="Restart desktop"/>\n  </RootMenu>\n'
        printf '  <Tray x="0" y="-1" height="34" autohide="off">\n    <Spacer width="4"/>\n    <TrayButton label="Menu">root:1</TrayButton>\n'
        printf '    <Spacer width="10"/>\n    <TrayButton label="Terminal">exec:%s</TrayButton>\n    <Spacer width="10"/>\n    <TrayButton label="Files">exec:%s</TrayButton>\n' "$terminal" "$files"
        [[ -n "$browser" ]] && printf '    <Spacer width="10"/>\n    <TrayButton label="Browser">exec:%s</TrayButton>\n' "$browser"
        printf '    <Spacer width="16"/>\n    <TaskList maxwidth="260"/>\n    <Clock format="%%a %%H:%%M"/>\n    <Spacer width="4"/>\n  </Tray>\n'
        printf '  <Desktops width="1" height="1"><Background type="solid">#1b2433</Background></Desktops>\n'
        printf '  <Key mask="4" key="Return">exec:%s</Key>\n  <Key mask="4" key="e">exec:%s</Key>\n' "$terminal" "$files"
        printf '  <Key mask="A" key="Tab">nextstacked</Key>\n  <Key mask="A" key="F4">close</Key>\n  <Key mask="4" key="w">close</Key>\n'
        printf '</JWM>\n'
    } > "$config"
    exec jwm -f "$config"
fi
# Openbox + tint2 where JWM isn't packaged: right-click menu and a taskbar, configured in Circe's own folder.
xdg="$HOME/.config/circe/xdg"; mkdir -p "$xdg/openbox"
{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<openbox_menu xmlns="http://openbox.org/3.4/menu">\n<menu id="root-menu" label="Circe">\n'
    printf '  <menu id="circe-apps" label="Applications" execute="%s openbox"/>\n  <separator/>\n' "$HOME/.local/libexec/circe/app-menu"
    printf '  <item label="Terminal"><action name="Execute"><command>%s</command></action></item>\n' "$terminal"
    printf '  <item label="Files"><action name="Execute"><command>%s</command></action></item>\n' "$files"
    [[ -n "$browser" ]] && printf '  <item label="Web browser"><action name="Execute"><command>%s</command></action></item>\n' "$browser"
    printf '  <separator/>\n  <item label="Restart desktop"><action name="Restart"/></item>\n</menu>\n</openbox_menu>\n'
} > "$xdg/openbox/menu.xml"
if command -v tint2 >/dev/null; then
    # Text buttons, like the JWM taskbar: icon themes are unreliable from a private folder.
    button() { printf 'button = new\nbutton_text = %s\nbutton_lclick_command = %s\nbutton_padding = 8 4\nbutton_font_color = #ffffff 100\nbutton_background_id = 0\n' "$1" "$2"; }
    items=PP; [[ -n "$browser" ]] && items=PPP  # P is a button in tint2 (B is the battery)
    {
        printf 'rounded = 0\nborder_width = 0\nbackground_color = #2b2f3a 100\nborder_color = #000000 0\n'
        printf 'rounded = 2\nborder_width = 0\nbackground_color = #3d6fb6 100\nborder_color = #000000 0\n'
        printf 'panel_items = %sTC\npanel_size = 100%% 34\npanel_position = bottom center horizontal\npanel_background_id = 1\npanel_padding = 4 2 4\n' "$items"
        button Terminal "$terminal"
        button Files "$files"
        [[ -n "$browser" ]] && button Browser "$browser"
        printf 'taskbar_mode = single_desktop\ntask_text = 1\ntask_icon = 1\ntask_maximum_size = 260 30\ntask_active_background_id = 2\ntask_font_color = #ffffff 100\n'
        printf 'time1_format = %%a %%H:%%M\nclock_font_color = #ffffff 100\n'
    } > "$HOME/.config/circe/tint2rc"
    tint2 -c "$HOME/.config/circe/tint2rc" &
fi
command -v xsetroot >/dev/null && xsetroot -solid '#1b2433'
XDG_CONFIG_DIRS="$xdg:${XDG_CONFIG_DIRS:-/etc/xdg}" exec openbox
LIGHT

{
    printf '#!/usr/bin/env bash\n# Prints the computer'"'"'s own X11 desktop session (written by Circe'"'"'s setup).\n'
    declare -f find_system_session
    printf 'find_system_session\n'
} | write_user_file "$LIBEXEC/system-session" 700

write_user_file "$LIBEXEC/start-desktop" 700 <<'DESKTOP'
#!/usr/bin/env bash
set -euo pipefail
umask 077
# This file runs as the desktop account, never as root.
# shellcheck disable=SC1091
source "$HOME/.config/circe/host.conf"
# Circe's desktop is an X display of its own. A Wayland desktop open on this computer (Hyprland on Omarchy,
# GNOME, KDE) hands its settings to all of the account's services through systemd; with them, this desktop's
# panel and apps would open their windows on that Wayland desktop instead, leaving Circe's screen black.
unset WAYLAND_DISPLAY WAYLAND_SOCKET HYPRLAND_INSTANCE_SIGNATURE HYPRLAND_CMD SWAYSOCK I3SOCK NIRI_SOCKET \
    MOZ_ENABLE_WAYLAND ELECTRON_OZONE_PLATFORM_HINT OZONE_PLATFORM NIXOS_OZONE_WL CLUTTER_BACKEND \
    QT_WAYLAND_DISABLE_WINDOWDECORATION GBM_BACKEND __GLX_VENDOR_LIBRARY_NAME WLR_NO_HARDWARE_CURSORS \
    XDG_SESSION_DESKTOP DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_MENU_PREFIX
export XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SDL_VIDEODRIVER=x11
# The computer's own desktop runs with the computer's own programs and libraries, never Circe's private copies
# (those are only for Xvnc and the light desktop): keep the environment from before prefix.env.
SYSTEM_ENV=(env -u LD_LIBRARY_PATH -u CIRCE_PREFIX -u CIRCE_XKBDIR -u CIRCE_XVNC_CWD -u GSETTINGS_SCHEMA_DIR -u GDK_PIXBUF_MODULE_FILE
            -u FONTCONFIG_FILE -u XDG_DATA_DIRS -u XDG_CONFIG_DIRS "PATH=$PATH")
for variable in LD_LIBRARY_PATH GSETTINGS_SCHEMA_DIR GDK_PIXBUF_MODULE_FILE FONTCONFIG_FILE XDG_DATA_DIRS XDG_CONFIG_DIRS; do
    [[ -z "${!variable:-}" ]] || SYSTEM_ENV+=("$variable=${!variable}")
done
SESSION=""
[[ -x "$HOME/.local/libexec/circe/system-session" ]] && SESSION="$("$HOME/.local/libexec/circe/system-session" 2>/dev/null || true)"
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
X_PID=; DESKTOP_PID=; XAUTHORITY_FILE=
# What Circe's audio, microphone and video commands need to know about a shared session (see below).
SESSION_ENV="${XDG_RUNTIME_DIR:?}/circe/desktop.env"
mkdir -p "${SESSION_ENV%/*}"; chmod 700 "${SESSION_ENV%/*}"; rm -f "$SESSION_ENV"
cleanup() {
    trap - EXIT
    [[ -z "$DESKTOP_PID" ]] || kill "$DESKTOP_PID" 2>/dev/null || true
    [[ -z "$X_PID" ]] || kill "$X_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f "$SESSION_ENV" ${XAUTHORITY_FILE:+"$XAUTHORITY_FILE"}
}
trap cleanup EXIT
trap 'exit 0' TERM INT
PASSWORD_FILE="$HOME/.config/circe/vncpasswd"; [[ -s "$PASSWORD_FILE" ]] || PASSWORD_FILE="$HOME/.vnc/passwd"

# The account's desktop session that's already open on this computer — Chrome Remote Desktop's, or an RDP
# (xrdp) session's. Circe shows that same session, with its open windows, rather than starting a second
# desktop that would fight it over apps that run once per account (Chrome's profile, VS Code).
# Prints "display<US>X authority file<US>chrome-remote-desktop|rdp".
open_session() {
    local line pid ppid args words i j display auth cwd kind best="" parents
    parents="$(ps -u "$(id -un)" -o pid=,ppid=,args= 2>/dev/null)" || return 1
    while read -r pid ppid args; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        # The exact arguments where /proc has them (paths may contain spaces); else the listing's words.
        if [[ -r "/proc/$pid/cmdline" ]]; then mapfile -d '' -t words < "/proc/$pid/cmdline"; else read -r -a words <<< "$args"; fi
        ((${#words[@]})) || continue
        case "${words[0]##*/}" in
            Xvfb) kind=crd
                # Only Chrome Remote Desktop's virtual screen; other Xvfb servers (test runners) aren't desktops.
                line="$(awk -v p="$ppid" '$1 == p { $1 = ""; $2 = ""; print; exit }' <<< "$parents")"
                [[ "$line" == *chrome-remote-desktop* ]] || continue ;;
            Xorg) kind=rdp; [[ "$args" == *xrdp* ]] || continue ;;
            *) continue ;;
        esac
        display=""; auth=""
        for ((i = 1; i < ${#words[@]}; i++)); do
            case "${words[i]}" in
                -auth) auth="${words[i + 1]:-}"
                    # Rejoin a path the listing split at spaces.
                    for ((j = i + 2; j < ${#words[@]}; j++)); do
                        [[ ! -e "$auth" && "${words[j]}" != -* ]] || break
                        auth+=" ${words[j]}"
                    done ;;
                :*) if [[ -z "$display" && "${words[i]}" =~ ^:([0-9]+)$ ]]; then display="${BASH_REMATCH[1]}"; fi ;;
            esac
        done
        [[ -n "$display" && "$display" != "$DISPLAY_NUMBER" ]] || continue
        if [[ -n "$auth" && "$auth" != /* ]]; then cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue; auth="$cwd/$auth"; fi
        [[ -z "$auth" || -r "$auth" ]] || continue
        # Chrome Remote Desktop's session stays open, so it comes first; else the newest RDP session.
        if [[ "$kind" == crd ]]; then printf '%s\037%s\037chrome-remote-desktop\n' "$display" "$auth"; return 0; fi
        best="$display"$'\037'"$auth"$'\037'rdp
    done <<< "$parents"
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}
# The sound server and output that session's apps use (Chrome Remote Desktop runs its own), from the
# environment of one of its programs, so Circe hears and speaks into that session.
session_audio() {
    local display="$1" pid environment server="" runtime="" sink=""
    for pid in $(pgrep -u "$(id -u)" 2>/dev/null); do
        environment="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)" || continue
        grep -qx "DISPLAY=:$display\(\.0\)\?" <<< "$environment" || continue
        grep -qE '^PULSE_(SERVER|RUNTIME_PATH|SINK)=' <<< "$environment" || continue
        server="$(sed -n 's/^PULSE_SERVER=//p' <<< "$environment" | head -1)"
        runtime="$(sed -n 's/^PULSE_RUNTIME_PATH=//p' <<< "$environment" | head -1)"
        sink="$(sed -n 's/^PULSE_SINK=//p' <<< "$environment" | head -1)"
        break
    done
    if [[ -z "$server" && -n "$runtime" && -S "$runtime/native" ]]; then server="unix:$runtime/native"; fi
    printf '%s\037%s\n' "$server" "${sink:+$sink.monitor}"
}
SHARE=""
SHARE_TOOL="$(command -v x0vncserver || command -v X0tigervnc || true)"
if [[ -n "$SHARE_TOOL" ]]; then
    SHARE="$(open_session || true)"
    # At startup Chrome Remote Desktop may still be opening its session: give it a moment rather than
    # starting a second desktop next to it.
    if [[ -z "$SHARE" ]] && systemctl is-enabled --quiet "chrome-remote-desktop@$(id -un).service" 2>/dev/null; then
        for ((attempt = 0; attempt < 45; attempt++)); do sleep 2; SHARE="$(open_session || true)"; [[ -z "$SHARE" ]] || break; done
    fi
fi
if [[ -n "$SHARE" ]]; then
    IFS=$'\037' read -r shared_display shared_auth shared_kind <<< "$SHARE"
    IFS=$'\037' read -r audio_server audio_source <<< "$(session_audio "$shared_display")"
    printf 'Circe: showing the desktop that is already open on display :%s\n' "$shared_display"
    {
        printf 'CIRCE_SHARED_DISPLAY=%q\nCIRCE_SHARED_XAUTHORITY=%q\nCIRCE_SHARED_KIND=%q\n' "$shared_display" "$shared_auth" "$shared_kind"
        [[ -z "$audio_server" ]] || printf 'CIRCE_PULSE_SERVER=%q\n' "$audio_server"
        [[ -z "$audio_source" ]] || printf 'CIRCE_AUDIO_SOURCE=%q\n' "$audio_source"
    } > "$SESSION_ENV.new"
    chmod 600 "$SESSION_ENV.new"; mv -f "$SESSION_ENV.new" "$SESSION_ENV"
    # TigerVNC's screen-sharing server, under the same password and loopback-only port as Circe's own desktop.
    started=$SECONDS
    XAUTHORITY="$shared_auth" "$SHARE_TOOL" -display ":$shared_display" -rfbport "$((5900 + DISPLAY_NUMBER))" -localhost=1 -interface 127.0.0.1 \
        -SecurityTypes VncAuth -PasswordFile "$PASSWORD_FILE" -AcceptSetDesktopSize=1 &
    X_PID=$!
    wait "$X_PID" || true
    X_PID=
    rm -f "$SESSION_ENV"
    # It ends with that session (sign-out, restart): systemd starts Circe's desktop again, which looks again.
    # If it couldn't show the session at all, start a desktop of Circe's own instead of trying forever.
    if ((SECONDS - started >= 10)); then exit 1; fi
    printf "Circe: couldn't show display :%s; starting a desktop of its own instead.\n" "$shared_display" >&2
fi

export DISPLAY=":$DISPLAY_NUMBER" XDG_SESSION_TYPE=x11
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XAUTHORITY="${XDG_RUNTIME_DIR:?}/circe-Xauthority"; XAUTHORITY_FILE="$XAUTHORITY"
touch "$XAUTHORITY"; chmod 600 "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$(openssl rand -hex 16)"
XKB_ARGS=(); [[ -n "${CIRCE_XKBDIR:-}" ]] && XKB_ARGS=(-xkbdir "$CIRCE_XKBDIR")
# Apps in this desktop play to Circe's sink; the account's default output (other sessions) is left alone.
export PULSE_SINK=circe
cd "$HOME"
# A private Xvnc patched to run ./.circe/xkbcomp starts from the private folder (see setup); only Xvnc does,
# so terminals and file windows still open in the home folder.
(
    [[ -n "${CIRCE_XVNC_CWD:-}" ]] && cd "$CIRCE_XVNC_CWD"
    exec "$VNC_SERVER" "$DISPLAY" -localhost=1 -interface 127.0.0.1 -SecurityTypes VncAuth -PasswordFile "$PASSWORD_FILE" \
        -rfbport "$((5900 + DISPLAY_NUMBER))" -geometry "$GEOMETRY" -depth 24 -nolisten tcp -auth "$XAUTHORITY" -desktop "Circe — $(hostname)" ${XKB_ARGS[@]+"${XKB_ARGS[@]}"}
) &
X_PID=$!
ready=false
for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$X_PID" 2>/dev/null || { wait "$X_PID"; exit 1; }
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.1
done
$ready || { printf 'Circe: virtual display did not become ready.\n' >&2; exit 1; }
if command -v xset >/dev/null; then xset s off 2>/dev/null || true; xset -dpms 2>/dev/null || true; fi
start_light_desktop() {
    # No desktop of the computer's own: Circe's light desktop (JWM or Openbox with a taskbar and an
    # Applications menu), or XFCE where the system has its session. Both run from PATH, so they also work
    # from Circe's private folder.
    export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
    if [[ -n "${CIRCE_PREFIX:-}" ]] || ! command -v xfce4-session >/dev/null; then
        dbus-run-session -- "$HOME/.local/libexec/circe/light-session" &
    else
        dbus-run-session -- xfce4-session &
    fi
    DESKTOP_PID=$!
}
wait_for_desktop() {
    while kill -0 "$X_PID" 2>/dev/null && kill -0 "$DESKTOP_PID" 2>/dev/null; do sleep 1; done
    if ! kill -0 "$X_PID" 2>/dev/null; then wait "$X_PID" || true; exit 1; fi
}
if [[ -n "$SESSION" ]]; then
    IFS=$'\037' read -r session_id session_name session_names session_exec <<< "$SESSION"
    session_names="${session_names//;/:}"; session_names="${session_names%:}"
    printf 'Circe: starting this computer'"'"'s desktop: %s\n' "${session_name:-$session_id}"
    # Its own D-Bus session, like Chrome Remote Desktop and RDP sessions: a desktop already open elsewhere for
    # this account keeps its settings and apps, and the account's shared services never see this display.
    # Debian and Ubuntu start desktops through Xsession (input methods, ~/.xsessionrc, the desktop's data
    # folders), as their login screen and xrdp do.
    if [[ -x /etc/X11/Xsession && -d /etc/X11/Xsession.d ]]; then command=(/etc/X11/Xsession "$session_exec")
    else command=(/bin/sh -c "exec $session_exec"); fi
    started=$SECONDS
    "${SYSTEM_ENV[@]}" XDG_SESSION_TYPE=x11 XDG_SESSION_DESKTOP="$session_id" DESKTOP_SESSION="$session_id" \
        XDG_CURRENT_DESKTOP="${session_names:-$session_id}" dbus-run-session -- "${command[@]}" &
    DESKTOP_PID=$!
    wait_for_desktop
    status=0; wait "$DESKTOP_PID" || status=$?
    # A desktop that can't run inside Xvnc stops right away; show Circe's light desktop rather than nothing.
    if ((SECONDS - started >= 20)); then exit "$status"; fi
    printf 'Circe: %s stopped right away (status %s); starting Circe'"'"'s light desktop instead.\n' "${session_name:-$session_id}" "$status" >&2
    if ! { [[ -x "$HOME/.local/libexec/circe/light-session" ]] && { command -v jwm || command -v openbox || command -v xfce4-session; } >/dev/null; }; then exit 1; fi
fi
start_light_desktop
wait_for_desktop
wait "$DESKTOP_PID"
DESKTOP

# BEGIN GENERATED CIRCE VIDEO WRAPPER
write_user_file "$LIBEXEC/video" 700 <<'CIRCE_VIDEO_WRAPPER'
#!/usr/bin/env bash
# Run as the desktop account. Stream stdout is FLV; diagnostics belong on stderr.
main() {
# Tools installed by Circe without administrator access live in a private prefix.
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
set -euo pipefail
export LC_ALL=C
umask 077
failure() {
    printf 'CIRCE_VIDEO_ERROR {"code":%d,"reason":"%s"}\n' "$1" "$2" >&2
    printf 'Circe video: %s\n' "$3" >&2
    exit "$1"
}
usage() {
    cat <<'HELP'
Usage: video [--display 1] [--encoder auto|nvenc|x264] [--fps auto|1..120]
             [--bitrate-kbps auto|256..100000] [--threads auto|1..16]
             [--max-width 0..8192] [--max-height 0..8192] [--check]
Default stdout is video-only H.264/AVCC in FLV. --check prints JSON instead.
Native dimensions are retained unless a maximum size is explicitly supplied.
HELP
}
DISPLAY_NUMBER=
ENCODER=auto
FPS=auto
BITRATE=auto
THREADS=auto
MAX_WIDTH=0
MAX_HEIGHT=0
CHECK=false
while (($#)); do
    case "$1" in
        --display|--encoder|--fps|--bitrate-kbps|--threads|--max-width|--max-height)
            (($# >= 2)) || failure 64 invalid_arguments "Missing value for $1."
            case "$1" in
                --display) DISPLAY_NUMBER="${2#:}"; DISPLAY_NUMBER="${DISPLAY_NUMBER%.0}" ;;
                --encoder) ENCODER="$2" ;;
                --fps) FPS="$2" ;;
                --bitrate-kbps) BITRATE="$2" ;;
                --threads) THREADS="$2" ;;
                --max-width) MAX_WIDTH="$2" ;;
                --max-height) MAX_HEIGHT="$2" ;;
            esac
            shift 2 ;;
        --check) CHECK=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) failure 64 invalid_arguments "Unknown option: $1." ;;
    esac
done
integer() { [[ "$1" =~ ^[0-9]{1,6}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }
if [[ -z "$DISPLAY_NUMBER" && -r "$HOME/.config/circe/host.conf" ]]; then
    DISPLAY_NUMBER="$(awk -F= '/^DISPLAY_NUMBER=[0-9]+$/ { print $2; exit }' "$HOME/.config/circe/host.conf")"
fi
DISPLAY_NUMBER="${DISPLAY_NUMBER:-1}"
integer "$DISPLAY_NUMBER" 0 99 || failure 64 invalid_arguments 'Display must be a local X11 display from 0 to 99.'
DISPLAY_NUMBER=$((10#$DISPLAY_NUMBER))
case "$ENCODER" in auto|nvenc|x264) ;; *) failure 64 invalid_arguments 'Encoder must be auto, nvenc, or x264.' ;; esac
[[ "$FPS" == auto ]] || integer "$FPS" 1 120 || failure 64 invalid_arguments 'FPS must be auto or from 1 to 120.'
[[ "$BITRATE" == auto ]] || integer "$BITRATE" 256 100000 || failure 64 invalid_arguments 'Bitrate must be auto or from 256 to 100000 kb/s.'
[[ "$THREADS" == auto ]] || integer "$THREADS" 1 16 || failure 64 invalid_arguments 'Threads must be auto or from 1 to 16.'
if ! integer "$MAX_WIDTH" 0 8192 || ! integer "$MAX_HEIGHT" 0 8192; then failure 64 invalid_arguments 'Maximum dimensions must be from 0 to 8192.'; fi
MAX_WIDTH=$((10#$MAX_WIDTH)); MAX_HEIGHT=$((10#$MAX_HEIGHT))
[[ "$MAX_WIDTH" == 0 ]] || ((MAX_WIDTH >= 128)) || failure 64 invalid_arguments 'A nonzero maximum width must be at least 128.'
[[ "$MAX_HEIGHT" == 0 ]] || ((MAX_HEIGHT >= 128)) || failure 64 invalid_arguments 'A nonzero maximum height must be at least 128.'
[[ "$(uname -s)" == Linux ]] || failure 69 unsupported_platform 'Run this wrapper on the Linux desktop host.'
for tool in ffmpeg xdpyinfo timeout; do command -v "$tool" >/dev/null || failure 69 missing_tool "Missing $tool. Run Circe host setup again."; done
if ! $CHECK && [[ -t 1 ]]; then failure 64 terminal_output 'FLV output must go to Circe or a file, not an interactive terminal.'; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/circe-video.XXXXXX")"
CHILD_PID=
# Invoked by EXIT and signal traps.
# shellcheck disable=SC2329
cleanup() {
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$CHILD_PID" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        local attempt
        for ((attempt=0; attempt<10; attempt++)); do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 0.1
        done
        # FFmpeg can stall during graceful shutdown. This stream is being
        # discarded; do not wait indefinitely for a container trailer.
        if kill -0 "$CHILD_PID" 2>/dev/null; then kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Circe's desktop may be showing a session that was already open (Chrome Remote Desktop, RDP): capture that one.
if [[ -r "$RUNTIME/circe/desktop.env" && -r "$HOME/.config/circe/host.conf" ]] && grep -qx "DISPLAY_NUMBER=$DISPLAY_NUMBER" "$HOME/.config/circe/host.conf"; then
    SHARED="$(bash -c 'source "$1"; [[ "${CIRCE_SHARED_DISPLAY:-}" =~ ^[0-9]{1,2}$ ]] && printf "%s\n%s" "$CIRCE_SHARED_DISPLAY" "${CIRCE_SHARED_XAUTHORITY:-}"' _ "$RUNTIME/circe/desktop.env" 2>/dev/null || true)"
    if [[ -n "$SHARED" ]]; then
        DISPLAY_NUMBER="${SHARED%%$'\n'*}"
        if [[ "$SHARED" == *$'\n'?* ]]; then export XAUTHORITY="${SHARED#*$'\n'}"; fi
    fi
fi
if [[ -z "${XAUTHORITY:-}" && -r "$RUNTIME/circe-Xauthority" ]]; then export XAUTHORITY="$RUNTIME/circe-Xauthority"; fi
X_DISPLAY=":$DISPLAY_NUMBER.0"
if ! INFO="$(timeout 5 xdpyinfo -display "$X_DISPLAY" 2>"$WORK/display-error")"; then
    cat "$WORK/display-error" >&2
    failure 77 display_unavailable 'Cannot access the virtual desktop. Check its display number and Xauthority, or rerun host setup.'
fi
read -r SOURCE_WIDTH SOURCE_HEIGHT < <(awk '/^[[:space:]]*dimensions: / { split($2, a, "x"); print a[1], a[2]; exit }' <<< "$INFO") || failure 77 display_unavailable 'Cannot determine the X11 desktop dimensions.'
if ! integer "$SOURCE_WIDTH" 1 16384 || ! integer "$SOURCE_HEIGHT" 1 16384; then failure 77 display_unavailable 'Unsupported X11 desktop dimensions.'; fi
SOURCE_WIDTH=$((10#$SOURCE_WIDTH)); SOURCE_HEIGHT=$((10#$SOURCE_HEIGHT))
DEVICES="$(ffmpeg -hide_banner -devices 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list capture devices.'
awk '$2 == "x11grab" { found=1 } END { exit !found }' <<< "$DEVICES" || failure 69 missing_capture 'This FFmpeg build lacks x11grab.'
MUXERS="$(ffmpeg -hide_banner -muxers 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list muxers.'
awk '$2 == "flv" { found=1 } END { exit !found }' <<< "$MUXERS" || failure 69 missing_muxer 'This FFmpeg build lacks FLV output.'
ENCODERS="$(ffmpeg -hide_banner -encoders 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list encoders.'
has_encoder() { awk -v name="$1" '$2 == name { found=1 } END { exit !found }' <<< "$ENCODERS"; }
# Encoder presence alone is insufficient: drivers, device access, and NVENC sessions can fail.
probe() {
    timeout 5 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i color=c=black:s=128x128:r=1 \
        -frames:v 1 -pix_fmt yuv420p -c:v "$1" "${@:2}" -profile:v high -bf 0 -f null - \
        >/dev/null 2>"$WORK/probe-error"
}
REQUESTED_ENCODER="$ENCODER"
if [[ "$ENCODER" == auto || "$ENCODER" == nvenc ]]; then
    if has_encoder h264_nvenc && probe h264_nvenc -preset p1 -tune ull -rc-lookahead 0 -zerolatency 1; then
        ENCODER=nvenc
    elif [[ "$REQUESTED_ENCODER" == nvenc ]]; then
        cat "$WORK/probe-error" >&2 2>/dev/null || true
        failure 69 encoder_unavailable 'NVENC could not encode a frame. Check the NVIDIA driver and FFmpeg build.'
    else
        printf 'CIRCE_VIDEO_WARNING NVENC unavailable; trying software x264.\n' >&2
        ENCODER=x264
    fi
fi
if [[ "$ENCODER" == x264 ]]; then
    has_encoder libx264 || failure 69 encoder_unavailable 'This FFmpeg build has no libx264 encoder and NVENC is unavailable.'
    probe libx264 -preset ultrafast -tune zerolatency || { cat "$WORK/probe-error" >&2; failure 69 encoder_unavailable 'x264 could not encode a frame.'; }
fi
CPUS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 2)"
integer "$CPUS" 1 4096 || CPUS=2
CPUS=$((10#$CPUS))
if [[ "$FPS" == auto ]]; then
    if [[ "$ENCODER" == nvenc ]]; then FPS=60; elif ((CPUS <= 2)); then FPS=20; else FPS=30; fi
else FPS=$((10#$FPS)); fi
if [[ "$BITRATE" == auto ]]; then
    if [[ "$ENCODER" == nvenc ]]; then BITRATE=12000; elif ((CPUS <= 2)); then BITRATE=6000; else BITRATE=8000; fi
else BITRATE=$((10#$BITRATE)); fi
if [[ "$THREADS" == auto ]]; then
    if [[ "$ENCODER" == nvenc ]]; then THREADS=1
    else THREADS=$((CPUS / 2)); ((THREADS >= 1)) || THREADS=1; ((THREADS <= 4)) || THREADS=4; fi
else THREADS=$((10#$THREADS)); fi

# Preserve native text pixels by default. Explicit size limits retain aspect and never upscale.
WIDTH="$SOURCE_WIDTH"; HEIGHT="$SOURCE_HEIGHT"
if ((MAX_WIDTH > 0 && WIDTH > MAX_WIDTH)); then HEIGHT=$((HEIGHT * MAX_WIDTH / WIDTH)); WIDTH="$MAX_WIDTH"; fi
if ((MAX_HEIGHT > 0 && HEIGHT > MAX_HEIGHT)); then WIDTH=$((WIDTH * MAX_HEIGHT / HEIGHT)); HEIGHT="$MAX_HEIGHT"; fi
((WIDTH > 0 && HEIGHT > 0)) || failure 64 invalid_arguments 'Requested size is too small for this desktop aspect ratio.'
FILTER=""
if ((WIDTH != SOURCE_WIDTH || HEIGHT != SOURCE_HEIGHT)); then FILTER="scale=$WIDTH:$HEIGHT:flags=fast_bilinear,"; fi
WIDTH=$(((WIDTH + 1) / 2 * 2)); HEIGHT=$(((HEIGHT + 1) / 2 * 2))
FILTER+="format=bgr0,pad=ceil(iw/2)*2:ceil(ih/2)*2,scale=in_range=full:out_range=limited:out_color_matrix=bt709,format=yuv420p"
GOP=$((FPS * 10)) # TCP preserves frames; avoid a visible IDR quality pulse every second
VBV=$((BITRATE / 4)) # 250ms allows a more detailed IDR without burning idle bandwidth
MIN_VBV=$(((BITRATE + FPS - 1) / FPS))
((VBV >= MIN_VBV)) || VBV="$MIN_VBV" # never smaller than one frame at an explicit low FPS
CONFIG="{\"version\":1,\"codec\":\"h264\",\"container\":\"flv\",\"encoder\":\"$ENCODER\",\"sourceWidth\":$SOURCE_WIDTH,\"sourceHeight\":$SOURCE_HEIGHT,\"width\":$WIDTH,\"height\":$HEIGHT,\"fps\":$FPS,\"bitrateKbps\":$BITRATE,\"threads\":$THREADS}"
if $CHECK; then printf '%s\n' "$CONFIG"; exit 0; fi
printf 'CIRCE_VIDEO_CONFIG %s\n' "$CONFIG" >&2
ENCODER_ARGS=()
if [[ "$ENCODER" == nvenc ]]; then
    ENCODER_ARGS=(-c:v h264_nvenc -preset p1 -tune ull -rc vbr -cq 18 -b:v "${BITRATE}k" -rc-lookahead 0 -zerolatency 1 -delay 0)
else
    ENCODER_ARGS=(-c:v libx264 -preset ultrafast -tune zerolatency -crf 18 -threads "$THREADS"
        -x264-params "keyint=$GOP:min-keyint=$FPS:scenecut=0:rc-lookahead=0:sync-lookahead=0")
fi
# No -re: x11grab is paced at capture. One queued input frame, no B-frames, no audio or stdout logs.
# A fresh FFmpeg process is required on resize or encoder failure; never concatenate FLV streams.
ffmpeg -nostdin -hide_banner -loglevel warning -copyts -start_at_zero -thread_queue_size 1 \
    -use_wallclock_as_timestamps 1 -f x11grab -draw_mouse 0 \
    -framerate "$FPS" -video_size "${SOURCE_WIDTH}x${SOURCE_HEIGHT}" -i "$X_DISPLAY" \
    -map 0:v:0 -an -sn -dn -filter_threads 1 -vf "$FILTER" "${ENCODER_ARGS[@]}" \
    -profile:v high -pix_fmt yuv420p -bf 0 -g "$GOP" -maxrate "${BITRATE}k" -bufsize "${VBV}k" \
    -color_primaries bt709 -color_trc iec61966-2-1 -colorspace bt709 -color_range tv \
    -vsync 0 -f flv -flvflags no_duration_filesize -flush_packets 1 pipe:1 </dev/null &
CHILD_PID=$!
if wait "$CHILD_PID"; then STATUS=0; else STATUS=$?; fi
CHILD_PID=
((STATUS == 0)) || failure 75 encoder_failed "Capture/encoding stopped (FFmpeg status $STATUS)."
}
main "$@"; exit $?
CIRCE_VIDEO_WRAPPER
# END GENERATED CIRCE VIDEO WRAPPER

# BEGIN GENERATED CIRCE AUDIO WRAPPER
write_user_file "$LIBEXEC/audio" 700 <<'CIRCE_AUDIO_WRAPPER'
#!/usr/bin/env bash
# Run as the desktop account. Ogg/Opus on stdout; all diagnostics on stderr.
main() {
# Tools installed by Circe without administrator access live in a private prefix.
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
set -euo pipefail
export LC_ALL=C
umask 077
failure() {
    printf 'CIRCE_AUDIO_ERROR {"code":%d,"reason":"%s"}\n' "$1" "$2" >&2
    printf 'Circe audio: %s\n' "$3" >&2
    exit "$1"
}
usage() {
    cat <<'HELP'
Usage: audio [--bitrate-kbps 32..256] [--check]
Default stdout is Ogg/Opus, 48 kHz stereo, 10 ms packets, 128 kb/s.
--check verifies capabilities and PulseAudio access, then prints JSON instead.
HELP
}
BITRATE=128
CHECK=false
while (($#)); do
    case "$1" in
        --bitrate-kbps)
            (($# >= 2)) || failure 64 invalid_arguments 'Missing bitrate.'
            BITRATE="$2"; shift 2 ;;
        --check) CHECK=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) failure 64 invalid_arguments "Unknown option: $1." ;;
    esac
done
if [[ ! "$BITRATE" =~ ^[0-9]{1,3}$ ]] || ! ((10#$BITRATE >= 32 && 10#$BITRATE <= 256)); then
    failure 64 invalid_arguments 'Bitrate must be from 32 to 256 kb/s.'
fi
BITRATE=$((10#$BITRATE))
[[ "$(uname -s)" == Linux ]] || failure 69 unsupported_platform 'Run this helper on the Linux desktop host.'
for tool in ffmpeg pactl timeout; do command -v "$tool" >/dev/null || failure 69 missing_tool "Missing $tool; using PCM audio instead."; done
if ! $CHECK && [[ -t 1 ]]; then failure 64 terminal_output 'Ogg output must go to Circe or a file, not an interactive terminal.'; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/circe-audio.XXXXXX")"
CHILD_PID=
# Invoked by EXIT and signal traps.
# shellcheck disable=SC2329
cleanup() {
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$CHILD_PID" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        local attempt
        for ((attempt=0; attempt<10; attempt++)); do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 0.1
        done
        # Cancellation discards the stream; stalled graceful shutdown must
        # not retain an encoder or prevent an audio channel restart.
        if kill -0 "$CHILD_PID" 2>/dev/null; then kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PULSE_SERVER="${PULSE_SERVER:-unix:$XDG_RUNTIME_DIR/pulse/native}"
# Every exit 69 is before the live encoder starts and before any stdout bytes.
# The caller can safely fall through to parec on exactly this status.
if ! timeout 5 pactl info > /dev/null 2>"$WORK/pulse-error"; then
    cat "$WORK/pulse-error" >&2
    failure 69 audio_unavailable 'Cannot reach the PulseAudio/PipeWire-pulse server for this account.'
fi
DEVICES="$(ffmpeg -hide_banner -devices 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list capture devices.'
awk '$2 == "pulse" { found=1 } END { exit !found }' <<< "$DEVICES" || failure 69 missing_capture 'This FFmpeg build lacks PulseAudio input; using PCM instead.'
MUXERS="$(ffmpeg -hide_banner -muxers 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list muxers.'
awk '$2 == "ogg" { found=1 } END { exit !found }' <<< "$MUXERS" || failure 69 missing_muxer 'This FFmpeg build lacks Ogg output; using PCM instead.'
ENCODERS="$(ffmpeg -hide_banner -encoders 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list encoders.'
awk '$2 == "libopus" { found=1 } END { exit !found }' <<< "$ENCODERS" || failure 69 missing_encoder 'This FFmpeg build lacks libopus; using PCM instead.'
OPUS_ARGS=(-c:a libopus -application lowdelay -frame_duration 10 -b:a "${BITRATE}k"
    -vbr constrained -compression_level 5 -ar 48000 -ac 2 -mapping_family 0 -threads 1)
if ! timeout 5 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo \
    -frames:a 1 "${OPUS_ARGS[@]}" -f ogg -page_duration 20000 -flush_packets 1 pipe:1 \
    > /dev/null 2>"$WORK/probe-error"; then
    cat "$WORK/probe-error" >&2
    failure 69 encoder_unavailable 'Opus could not encode a packet; using PCM instead.'
fi
# Circe passes circe.monitor for its own desktop; anything else records the default output.
DEVICE="${CIRCE_AUDIO_DEVICE:-@DEFAULT_MONITOR@}"
[[ "$DEVICE" =~ ^(@DEFAULT_MONITOR@|[A-Za-z0-9_.-]{1,128})$ ]] || failure 64 invalid_arguments 'Invalid audio device.'
CONFIG="{\"version\":1,\"codec\":\"opus\",\"container\":\"ogg\",\"sampleRate\":48000,\"channels\":2,\"frameSamples\":480,\"frameDurationMs\":10,\"pageDurationMs\":20,\"bitrateKbps\":$BITRATE}"
if $CHECK; then printf '%s\n' "$CONFIG"; exit 0; fi
printf 'CIRCE_AUDIO_CONFIG %s\n' "$CONFIG" >&2
# 1920 bytes is 10 ms of s16 stereo. The audio server may negotiate a larger
# fragment; this is a request, not an end-to-end latency guarantee.
ffmpeg -nostdin -hide_banner -loglevel warning -thread_queue_size 2 \
    -probesize 32 -analyzeduration 1 -f pulse -sample_rate 48000 -channels 2 -fragment_size 1920 -i "$DEVICE" \
    -map 0:a:0 -vn -sn -dn "${OPUS_ARGS[@]}" \
    -f ogg -page_duration 20000 -flush_packets 1 pipe:1 </dev/null &
CHILD_PID=$!
if wait "$CHILD_PID"; then STATUS=0; else STATUS=$?; fi
CHILD_PID=
((STATUS == 0)) || failure 75 encoder_failed "Audio capture/encoding stopped (FFmpeg status $STATUS)."
}
main "$@"; exit $?
CIRCE_AUDIO_WRAPPER
# END GENERATED CIRCE AUDIO WRAPPER

write_user_file "$LIBEXEC/start-audio" 700 <<'AUDIO'
#!/usr/bin/env bash
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
set -euo pipefail
# Recover the virtual output if PulseAudio or PipeWire-pulse restarts.
while :; do
    if pactl info >/dev/null 2>&1; then
        if ! pactl list short sinks | awk '{ print $2 }' | grep -qx circe; then
            pactl load-module module-null-sink sink_name=circe sink_properties=device.description=Circe rate=48000 channels=2 >/dev/null || true
        fi
    fi
    sleep 3
done
AUDIO

if ((${#PRIVATE_PULSE[@]})); then
    write_user_file "$LIBEXEC/start-pulse" 700 <<'PULSE'
#!/usr/bin/env bash
# PulseAudio from Circe's private folder: its modules and configuration have /usr paths built in, so name them.
# shellcheck disable=SC1091
source "$HOME/.config/circe/prefix.env"
set -euo pipefail
modules=
for dir in "$CIRCE_PREFIX"/usr/lib*/pulse-*/modules "$CIRCE_PREFIX"/usr/lib*/pulseaudio/modules "$CIRCE_PREFIX"/usr/lib/*/pulse-*/modules; do
    [[ -e "$dir/module-null-sink.so" ]] && { modules="$dir"; break; }
done
[[ -n "$modules" ]] || { printf 'Circe: PulseAudio modules are missing from %s\n' "$CIRCE_PREFIX" >&2; exit 1; }
# Modules load helpers (libprotocol-native and friends) from their own folder through a built-in path.
export LD_LIBRARY_PATH="$modules${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
config="$HOME/.config/circe/pulse.pa"
printf '%s\n' '.fail' 'load-module module-native-protocol-unix' 'load-module module-null-sink sink_name=circe sink_properties=device.description=Circe rate=48000 channels=2' \
    'set-default-sink circe' > "$config.tmp" && mv -f "$config.tmp" "$config"
exec pulseaudio --daemonize=no --system=no --exit-idle-time=-1 --log-target=stderr --disallow-module-loading=no \
    --dl-search-path="$modules" -n -F "$config"
PULSE
    write_user_file "$UNITS/circe-pulse.service" 600 <<'UNIT'
[Unit]
Description=Circe private sound server (PulseAudio)

[Service]
Type=simple
ExecStart="%h/.local/libexec/circe/start-pulse"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
fi
write_user_file "$UNITS/circe-audio.service" 600 <<EOF
[Unit]
Description=Circe headless audio output
Wants=$BACKEND_UNIT
After=$BACKEND_UNIT

[Service]
Type=simple
Environment=PULSE_SERVER=unix:%t/pulse/native
ExecStart="%h/.local/libexec/circe/start-audio"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
write_user_file "$UNITS/circe-desktop.service" 600 <<'UNIT'
[Unit]
Description=Circe desktop
Wants=circe-audio.service
After=circe-audio.service

[Service]
Type=simple
ExecStart="%h/.local/libexec/circe/start-desktop"
# Signing out of the desktop starts a fresh one, like signing in again over RDP.
Restart=always
RestartSec=3
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=default.target
UNIT
PERSISTENT=true
if $NEED_ROOT; then
    as_root loginctl enable-linger "$TARGET_USER"
    as_root systemctl start "user@$TARGET_UID.service"
elif [[ "$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || true)" != yes ]]; then
    # Many systems let users keep their own services running (polkit set-self-linger); no sudo involved. Never
    # wait for a password prompt that nobody can see, and believe only the resulting state.
    timeout 20 loginctl --no-ask-password enable-linger "$TARGET_USER" </dev/null >/dev/null 2>&1 || true
    if [[ "$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || true)" != yes ]]; then
        PERSISTENT=false
        printf "This computer doesn't let %s keep the desktop running after disconnecting; Circe starts it again when you connect.\n" "$TARGET_USER"
    fi
fi
if $PERSISTENT; then rm -f "$CONFIG/connected-only"; else printf 'Circe starts this desktop when it connects.\n' | write_user_file "$CONFIG/connected-only" 600; fi
clean_user touch "$SETUP_TRANSACTION/services-touched"
as_user systemctl --user daemon-reload
# Optional sound is a separate stage: policy-denied/missing/masked audio units never prevent the desktop.
activate_audio() {
    AUDIO_ACTIVATION_FAILED=false
    if [[ "$BACKEND_UNIT" != circe-pulse.service && -f "$UNITS/circe-pulse.service" ]]; then
        # The administrator supplied a system server after our private install. Remove only Circe's
        # ownership of the shared native socket before activating that server; never stop PipeWire/PulseAudio.
        if ! as_user systemctl --user stop circe-pulse.service; then AUDIO_ACTIVATION_FAILED=true; fi
        if ! as_user systemctl --user disable circe-pulse.service; then AUDIO_ACTIVATION_FAILED=true; fi
    fi
    if ! $AUDIO_ACTIVATION_FAILED; then
        if ! as_user systemctl --user enable --now "$BACKEND_UNIT"; then AUDIO_ACTIVATION_FAILED=true; fi
        if [[ "$BACKEND_UNIT" == circe-pulse.service ]] && ! as_user systemctl --user restart circe-pulse.service; then AUDIO_ACTIVATION_FAILED=true; fi
    fi
    if ! as_user systemctl --user enable circe-audio.service; then AUDIO_ACTIVATION_FAILED=true; fi
    if ! as_user systemctl --user restart circe-audio.service; then AUDIO_ACTIVATION_FAILED=true; fi
    if $AUDIO_ACTIVATION_FAILED; then printf 'Sound could not be started; the desktop will work without it.\n'; fi
    return 0
}
activate_audio
as_user systemctl --user enable circe-desktop.service
as_user systemctl --user restart circe-desktop.service
READY=false
AUDIO_READY=false
for ((attempt=0; attempt<30; attempt++)); do
    if report_status false >/dev/null 2>&1; then READY=true; $AUDIO_READY && break; fi
    # Sound gets a few more seconds once the desktop is up, but never holds setup back.
    if $READY && ((attempt >= 10)); then break; fi
    sleep 1
done
if ! $READY; then
    report_status || true
    printf '\nSee: journalctl --user -u circe-desktop -u circe-audio -n 60 --no-pager\n' >&2
    die 'Setup files are installed, but a service is not ready. Fix the reported issue, then rerun this script.'
fi
report_status || die 'The desktop stopped before setup completed; restoring the previous desktop.'
if ! $AUDIO_READY; then
    printf "Sound isn't available on this computer (no working PulseAudio or PipeWire); the desktop works without it.\n"
fi
setup_commit
metadata() { curl -fsS --connect-timeout 1 --max-time 2 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null || true; }
INSTANCE="$(metadata instance/name)"
ZONE="$(metadata instance/zone)"; ZONE="${ZONE##*/}"
PROJECT="$(metadata project/project-id)"
printf '\nIn Circe, choose Add a computer, then enter:\n'
if [[ -n "$INSTANCE" && -n "$ZONE" ]]; then
    printf '  Connection: Google Cloud\n  Instance: %s\n  Zone: %s\n  Project: %s\n  Use IAP: on\n' "$INSTANCE" "$ZONE" "$PROJECT"
else
    printf '  Connection: SSH\n  Destination: %s@%s (or your SSH-config alias)\n  SSH port: 22\n' "$TARGET_USER" "$(hostname -f 2>/dev/null || hostname)"
fi
printf '  VNC display: %s\n\nUse the VNC password shown on the first install. VNC stays on localhost:%s.\n' "$DISPLAY_NUMBER" "$VNC_PORT"
printf 'Audio source: circe.monitor (parec --device=circe.monitor --format=s16le --rate=48000 --channels=2 --raw).\n'
printf 'No VNC firewall rule or public VNC address is needed. Existing SSH/IAP access is required.\n'
# Password is JSON-safe base64, and is returned only when this run created it.
SHARED_KIND="$(shared_session_kind)"
printf 'CIRCE_SETUP_RESULT {"display":%d,"password":%s,"audio":%s,"persistent":%s,"withoutAdmin":%s,"sharedSession":%s}\n' "$DISPLAY_NUMBER" "$RESULT_PASSWORD" \
    "$AUDIO_READY" "$PERSISTENT" "$USERSPACE" "$([[ -n "$SHARED_KIND" ]] && json_string "$SHARED_KIND" || echo null)"

}
main "$@"; exit $?

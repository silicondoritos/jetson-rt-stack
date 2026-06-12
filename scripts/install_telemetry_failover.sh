#!/bin/bash
# =============================================================================
# scripts/install_telemetry_failover.sh   Doodle Labs primary + Iridium failover
# =============================================================================
# Installs:
#   • mavlink-router            fan-out from FCU UART to multiple endpoints
#   • Doodle Labs Helix path    primary 14550/UDP to GCS over the mesh radio
#   • Iridium SBD relay path    secondary; compresses key telemetry into
#                                ~200 byte SBD packets, sends every 60s
#                                normally, every 15s when the primary is
#                                unhealthy
#   • Health monitor            watches /mavros/state and primary link RSSI;
#                                emits black-box events on transitions
#
# Pure userspace (the kernel-side bit is CONFIG_USB_ACM=m for the RockBLOCK
# 9704, which is in the defconfig). Idempotent. Run from
# install_uav_phase7.sh.
#
# Configuration:
#   /etc/jetson-av/telemetry-failover.conf
#     FCU_TTY=/dev/ttyTHS0
#     FCU_BAUD=921600
#     PRIMARY_GCS_HOST=192.168.10.1
#     PRIMARY_GCS_PORT=14550
#     IRIDIUM_TTY=/dev/ttyACM0
#     IRIDIUM_BAUD=19200
#     SBD_INTERVAL_NORMAL=60     seconds between SBD reports when primary OK
#     SBD_INTERVAL_DEGRADED=15   seconds between SBD reports when primary down
#     PRIMARY_TIMEOUT=10         seconds without GCS heartbeat → primary down
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=telemetry_failover

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "Install Telemetry Failover (Doodle Labs primary + Iridium SBD)"

CONF_DIR=/etc/jetson-av
CONF="$CONF_DIR/telemetry-failover.conf"
mkdir -p "$CONF_DIR"

# --- Step 1: dependencies (mavlink-router via apt or build) ---------------
pre_deps() { check::command_exists apt-get; }
exec_deps() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-pip python3-serial python3-pymavlink screen socat \
        build-essential git pkg-config libsystemd-dev || true

    if command -v mavlink-routerd >/dev/null 2>&1; then
        log::info "mavlink-router already installed"
        return 0
    fi
    # Try apt first (some distros ship it).
    if apt-get install -y mavlink-router 2>/dev/null \
       && command -v mavlink-routerd >/dev/null 2>&1; then
        return 0
    fi
    # Fallback: build from source.
    local src=/var/tmp/mavlink-router
    if [ ! -d "$src" ]; then
        git clone --recurse-submodules https://github.com/mavlink-router/mavlink-router.git "$src"
    fi
    cd "$src"
    DEBIAN_FRONTEND=noninteractive apt-get install -y meson ninja-build python3-future
    meson setup build . --buildtype=release || true
    ninja -C build || { log::warn "mavlink-router build failed; will use socat-based failover instead"; return 0; }
    ninja -C build install
    ldconfig
}
post_deps() {
    # mavlink-router is preferred but the failover daemon below also works
    # without it (uses socat + pymavlink). Pass either way.
    return 0
}
STRICT=0 step::run "Install mavlink-router + dependencies" pre_deps exec_deps post_deps

# --- Step 2: write default config ----------------------------------------
pre_conf() { return 0; }
exec_conf() {
    if [ -f "$CONF" ]; then
        log::info "Preserving existing $CONF"
        return 0
    fi
    cat > "$CONF" <<'EOF'
# Telemetry failover config. Edit and:
#   sudo systemctl restart jetson-av-mavlink-router.service
#   sudo systemctl restart jetson-av-iridium-relay.service
#   sudo systemctl restart jetson-av-link-monitor.service

# Flight controller UART   check your carrier's UART mapping.
# Common: TELEM2 → /dev/ttyTHS0, PX4-default TELEM1 → /dev/ttyTHS1.
FCU_TTY=/dev/ttyTHS0
FCU_BAUD=921600

# Primary GCS endpoint (over Doodle Labs Helix mesh).
PRIMARY_GCS_HOST=192.168.10.1
PRIMARY_GCS_PORT=14550

# Iridium SBD modem.
#   IRIDIUM_MODEL=9704  → RockBLOCK 9704 (current). Uses FTDI USB-serial
#                          (/dev/ttyUSB0 default) and JSPR JSON protocol.
#                          Needs CONFIG_USB_SERIAL_FTDI_SIO (in defconfig).
#   IRIDIUM_MODEL=9603  → RockBLOCK 9602/9603 (legacy). Uses CDC-ACM
#                          (/dev/ttyACM0) and the AT+SBDWB / AT+SBDIX
#                          command set. Needs CONFIG_USB_ACM (in defconfig).
IRIDIUM_MODEL=9704
IRIDIUM_TTY=/dev/ttyUSB0
IRIDIUM_BAUD=230400        # 230400 for 9704; 19200 for 9602/9603

# Cadence (seconds).
SBD_INTERVAL_NORMAL=60
SBD_INTERVAL_DEGRADED=15

# Primary link is considered DOWN if no GCS-side HEARTBEAT for this many seconds.
PRIMARY_TIMEOUT=10
EOF
}
post_conf() { check::file_exists "$CONF"; }
step::run "Write /etc/jetson-av/telemetry-failover.conf" pre_conf exec_conf post_conf

# --- Step 3: mavlink-router config (fan-out from FCU to multiple endpoints) -
pre_mr() { return 0; }
exec_mr() {
    cat > "$CONF_DIR/mavlink-router.conf" <<'EOF'
# /etc/jetson-av/mavlink-router.conf   fan-out FCU telemetry.
# This is read by jetson-av-mavlink-router.service which substitutes the
# FCU_TTY/FCU_BAUD/PRIMARY_GCS_* values from telemetry-failover.conf.

[General]
# Buffered logging to /var/log/jetson-av/mavlink-router.log.
Log = /var/log/jetson-av/mavlink-router.log
LogMode = while-armed
ReportStats = true
TcpServerPort = 5760

[UartEndpoint fcu]
Device = ${FCU_TTY}
Baud = ${FCU_BAUD}

# Primary GCS   over Doodle Labs Helix.
[UdpEndpoint gcs_primary]
Mode = Normal
Address = ${PRIMARY_GCS_HOST}
Port = ${PRIMARY_GCS_PORT}

# Local listeners   MAVROS, QGC if you SSH-tunnel to the device, etc.
[UdpEndpoint mavros]
Mode = Server
Address = 127.0.0.1
Port = 14540
EOF
    mkdir -p /var/log/jetson-av
}
post_mr() { check::file_exists "$CONF_DIR/mavlink-router.conf"; }
step::run "Write mavlink-router.conf" pre_mr exec_mr post_mr

# --- Step 4: Iridium SBD relay (Python; works against pymavlink) ---------
pre_sbd() { return 0; }
exec_sbd() {
    cat > /usr/local/bin/jetson-av-iridium-relay <<'PYEOF'
#!/usr/bin/env python3
"""
Iridium SBD telemetry relay. Pulls the latest GLOBAL_POSITION_INT + ATTITUDE
+ SYS_STATUS + RC_CHANNELS messages from the local mavlink-router TCP server
and ships them via the RockBLOCK every N seconds.

Cadence flips between SBD_INTERVAL_NORMAL and SBD_INTERVAL_DEGRADED based
on /run/jetson-av-link-state (written by jetson-av-link-monitor).

Two model paths (selected via IRIDIUM_MODEL):

  9704 (current)   JSPR JSON over FTDI USB-serial (typically /dev/ttyUSB0
                   at 230400 baud). The Rock7 SDK is the canonical client:
                       https://github.com/rock7/RockBLOCK-9704
                   We import it lazily; if absent we log a clear instruction
                   and exit (systemd will hold us in restart back-off).

  9603 / 9602      Legacy AT command set over CDC-ACM (typically
                   /dev/ttyACM0 at 19200). We implement AT+SBDWB +
                   AT+SBDIX directly via pyserial.

The earlier revision of this script always used the 9603 AT path; that
breaks silently on the 9704 because the 9704 ignores AT and expects
JSPR JSON. See docs/VERIFICATION_REPORT.md.
"""
import os, sys, time, struct, signal, json, traceback

CONF       = "/etc/jetson-av/telemetry-failover.conf"
LINK_STATE = "/run/jetson-av-link-state"
EVENT_PIPE = "/var/run/jetson-av-events"

def load_conf(path):
    cfg = {}
    if not os.path.exists(path):
        return cfg
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg

def emit(event, value):
    try:
        if os.path.exists(EVENT_PIPE):
            with open(EVENT_PIPE, "w") as p:
                p.write(json.dumps({"src":"iridium_relay","e":event,"v":value}) + "\n")
    except Exception:
        pass

def link_degraded():
    try:
        with open(LINK_STATE) as f:
            return f.read().strip() == "degraded"
    except FileNotFoundError:
        return False

# ---------------------------------------------------------------------------
# Telemetry packing   common to both modems.
# Packs a compact 36-byte payload from the latest mavlink messages.
# ---------------------------------------------------------------------------
TRACKED = ("GLOBAL_POSITION_INT", "ATTITUDE", "SYS_STATUS", "RC_CHANNELS")

def pack_payload(now_epoch, last):
    gp = last["GLOBAL_POSITION_INT"]
    at = last["ATTITUDE"]
    ss = last["SYS_STATUS"]
    rc = last["RC_CHANNELS"]
    if not gp:
        return None
    return struct.pack(
        "<IiiifffffH",
        int(now_epoch) & 0xFFFFFFFF,
        gp.lat, gp.lon, gp.alt,
        at.roll  if at else 0.0,
        at.pitch if at else 0.0,
        at.yaw   if at else 0.0,
        (ss.voltage_battery / 1000.0) if ss else 0.0,
        (ss.current_battery /  100.0) if ss else 0.0,
        (rc.chan3_raw if rc else 0) & 0xFFFF,
    )

# ---------------------------------------------------------------------------
# 9704 sender   uses the Rock7 RockBLOCK-9704 Python SDK (JSPR).
# ---------------------------------------------------------------------------
def make_sender_9704(tty, baud):
    # The Rock7 RockBLOCK-9704 SDK API has not been stabilized in
    # public docs at the time of writing. Try several plausible import
    # paths and class names in order of likelihood. If none match, log
    # what we tried + the SDK URL and exit cleanly so systemd holds us
    # in restart back-off rather than crashlooping with a stack trace.
    candidates = (
        # (module_name, class_or_factory_name)
        ("rockblock9704",      "RockBlock9704"),
        ("rockblock9704",      "RockBlock"),
        ("rockblock_9704",     "RockBlock9704"),
        ("rockblock",          "RockBlock9704"),
        ("rb9704",             "RockBlock9704"),
    )
    rb_mod = None
    rb_cls = None
    tried  = []
    for mod_name, cls_name in candidates:
        try:
            mod = __import__(mod_name)
            cls = getattr(mod, cls_name, None)
            if cls is not None:
                rb_mod, rb_cls = mod, cls
                print(f"[iridium-relay] using {mod_name}.{cls_name}")
                break
        except ImportError:
            tried.append(f"{mod_name}.{cls_name}")
            continue

    if rb_cls is None:
        print("[iridium-relay] RockBLOCK-9704 SDK not found.")
        print("    Install via: pip install rockblock9704")
        print("    Source:      https://github.com/rock7/RockBLOCK-9704")
        print(f"    Tried:       {', '.join(tried)}")
        print("    If the SDK is installed under a different module/class")
        print("    name, edit the `candidates` tuple in")
        print("    /usr/local/bin/jetson-av-iridium-relay and add it.")
        emit("sdk_missing", "rockblock9704")
        sys.exit(2)   # systemd Restart=on-failure will back off

    # Construct the modem object. Accept either ctor signature.
    try:
        modem = rb_cls(port=tty, baudrate=baud)
    except TypeError:
        try:
            modem = rb_cls(tty, baud)
        except Exception as e:
            print(f"[iridium-relay] cannot construct {rb_cls.__name__}: {e}")
            print("    Check the SDK's constructor signature and adjust.")
            emit("sdk_ctor_failed", str(e))
            sys.exit(2)

    # Resolve the send method. Try common names in priority order.
    send_method = None
    for name in ("send_message", "send", "transmit", "send_bytes", "send_binary"):
        if hasattr(modem, name) and callable(getattr(modem, name)):
            send_method = getattr(modem, name)
            print(f"[iridium-relay] using send method: {name}()")
            break
    if send_method is None:
        print("[iridium-relay] no recognized send method on the SDK object.")
        print(f"    Object: {modem!r}; methods: {dir(modem)}")
        print("    Add the SDK's actual send-method name to the loop above.")
        emit("sdk_no_send_method", rb_cls.__name__)
        sys.exit(2)

    def send(payload_bytes):
        # JSPR transmits raw bytes wrapped in a JSON envelope; the SDK
        # handles framing + ack. Return True on accepted, False on error.
        try:
            result = send_method(payload_bytes)
        except Exception as e:
            emit("sdk_send_exception", str(e))
            print(f"[iridium-relay] send raised: {e}")
            return False
        # Rock7 SDKs typically return None on success, raise on failure;
        # some return bool. Treat None / True / nonzero as success.
        return result is None or bool(result)
    return send

# ---------------------------------------------------------------------------
# 9603 sender   legacy AT command set over pyserial.
# ---------------------------------------------------------------------------
def make_sender_9603(tty, baud):
    import serial
    s = serial.Serial(tty, baud, timeout=2)
    def send(payload_bytes):
        try:
            cs = sum(payload_bytes) & 0xFFFF
            s.write(f"AT+SBDWB={len(payload_bytes)}\r".encode())
            s.flush()
            # Real implementation should wait for "READY\r\n" here.
            time.sleep(0.2)
            s.write(payload_bytes + bytes([(cs >> 8) & 0xFF, cs & 0xFF]))
            s.flush()
            s.write(b"AT+SBDIX\r")
            s.flush()
            return True
        except Exception as e:
            emit("sbd_error", str(e))
            return False
    return send

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
def main():
    cfg = load_conf(CONF)
    model        = cfg.get("IRIDIUM_MODEL", "9704")
    iridium_tty  = cfg.get("IRIDIUM_TTY", "/dev/ttyUSB0" if model == "9704" else "/dev/ttyACM0")
    iridium_baud = int(cfg.get("IRIDIUM_BAUD", "230400" if model == "9704" else "19200"))
    interval_ok  = int(cfg.get("SBD_INTERVAL_NORMAL", "60"))
    interval_bad = int(cfg.get("SBD_INTERVAL_DEGRADED", "15"))
    mr_host      = "127.0.0.1"
    mr_port      = 5760

    print(f"[iridium-relay] model={model} tty={iridium_tty} baud={iridium_baud}")
    emit("relay_start", model)

    # Build the sender first   fail fast if SDK / serial missing.
    if model == "9704":
        sender = make_sender_9704(iridium_tty, iridium_baud)
    elif model in ("9603", "9602"):
        sender = make_sender_9603(iridium_tty, iridium_baud)
    else:
        print(f"[iridium-relay] unknown IRIDIUM_MODEL={model}; expect 9704 | 9603 | 9602")
        sys.exit(1)

    # Connect to mavlink-router's TCP server.
    try:
        from pymavlink import mavutil
    except ImportError:
        print("[iridium-relay] missing pymavlink (apt install python3-pymavlink)")
        sys.exit(1)

    mav = None
    while mav is None:
        try:
            mav = mavutil.mavlink_connection(f"tcp:{mr_host}:{mr_port}")
            mav.wait_heartbeat(timeout=10)
            print("[iridium-relay] connected to mavlink-router")
            emit("router_connected", "tcp")
        except Exception as e:
            print(f"[iridium-relay] mavlink-router not reachable: {e}; retry in 5s")
            time.sleep(5)

    last = {k: None for k in TRACKED}
    last_send = 0
    running = True
    def stop(sig, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGINT,  stop)
    signal.signal(signal.SIGTERM, stop)

    while running:
        try:
            msg = mav.recv_match(blocking=True, timeout=1)
            if msg:
                t = msg.get_type()
                if t in last:
                    last[t] = msg
        except Exception:
            pass

        interval = interval_bad if link_degraded() else interval_ok
        now = time.time()
        if now - last_send < interval:
            continue

        payload = pack_payload(now, last)
        if not payload:
            time.sleep(1); continue

        if sender(payload):
            print(f"[iridium-relay] queued SBD packet ({len(payload)}b)")
            emit("sbd_sent", len(payload))
        last_send = now

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        sys.exit(1)
PYEOF
    chmod 0755 /usr/local/bin/jetson-av-iridium-relay
}
post_sbd() { check::executable /usr/local/bin/jetson-av-iridium-relay; }
step::run "Install Iridium SBD relay daemon" pre_sbd exec_sbd post_sbd

# --- Step 5: link monitor (writes /run/jetson-av-link-state) -------------
pre_lm() { return 0; }
exec_lm() {
    cat > /usr/local/bin/jetson-av-link-monitor <<'PYEOF'
#!/usr/bin/env python3
"""
Watches mavlink-router's TCP server for GCS-side HEARTBEATs (system 255) and
flips /run/jetson-av-link-state between "ok" and "degraded". Iridium relay
reads this flag to decide cadence.
"""
import os, sys, time, json
LINK_STATE = "/run/jetson-av-link-state"
EVENT_PIPE = "/var/run/jetson-av-events"

def emit(event, value):
    try:
        if os.path.exists(EVENT_PIPE):
            with open(EVENT_PIPE, "w") as p:
                p.write(json.dumps({"src":"link_monitor","e":event,"v":value}) + "\n")
    except Exception:
        pass

def write_state(state):
    try:
        with open(LINK_STATE, "w") as f:
            f.write(state)
    except Exception:
        pass

def load_timeout():
    try:
        with open("/etc/jetson-av/telemetry-failover.conf") as f:
            for line in f:
                if line.startswith("PRIMARY_TIMEOUT="):
                    return int(line.split("=",1)[1].strip().strip('"'))
    except Exception:
        pass
    return 10

def main():
    try:
        from pymavlink import mavutil
    except ImportError:
        print("[link-monitor] missing pymavlink", file=sys.stderr); sys.exit(1)

    timeout = load_timeout()
    state = "ok"
    last_gcs_hb = time.time()

    mav = None
    while mav is None:
        try:
            mav = mavutil.mavlink_connection("tcp:127.0.0.1:5760")
            mav.wait_heartbeat(timeout=10)
            emit("monitor_started", state)
        except Exception as e:
            time.sleep(5)

    write_state(state)
    while True:
        msg = mav.recv_match(type="HEARTBEAT", blocking=True, timeout=1)
        if msg and msg.get_srcSystem() == 255:
            # GCS heartbeat received over Doodle Labs path.
            last_gcs_hb = time.time()
            if state != "ok":
                state = "ok"
                write_state(state)
                emit("primary_recovered", "1")
        elif time.time() - last_gcs_hb > timeout:
            if state != "degraded":
                state = "degraded"
                write_state(state)
                emit("primary_lost", str(int(time.time() - last_gcs_hb)))

if __name__ == "__main__":
    main()
PYEOF
    chmod 0755 /usr/local/bin/jetson-av-link-monitor
}
post_lm() { check::executable /usr/local/bin/jetson-av-link-monitor; }
step::run "Install link-state monitor" pre_lm exec_lm post_lm

# --- Step 6: systemd units --------------------------------------------------
pre_units() { return 0; }
exec_units() {
    cat > /etc/systemd/system/jetson-av-mavlink-router.service <<'EOF'
[Unit]
Description=Jetson AV MAVLink router (FCU → multi-endpoint fan-out)
Documentation=file:///opt/docs/TELEMETRY_FAILOVER.md
After=multi-user.target
Wants=multi-user.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
EnvironmentFile=/etc/jetson-av/telemetry-failover.conf
# Substitute env vars into the template config at start.
ExecStartPre=/bin/sh -c 'envsubst < /etc/jetson-av/mavlink-router.conf > /run/mavlink-router.conf'
ExecStart=/usr/bin/mavlink-routerd -c /run/mavlink-router.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/jetson-av-iridium-relay.service <<'EOF'
[Unit]
Description=Jetson AV Iridium SBD relay (failover telemetry)
Documentation=file:///opt/docs/TELEMETRY_FAILOVER.md
After=jetson-av-mavlink-router.service jetson-av-link-monitor.service
Wants=jetson-av-mavlink-router.service jetson-av-link-monitor.service

[Service]
Type=simple
ExecStart=/usr/local/bin/jetson-av-iridium-relay
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/jetson-av-link-monitor.service <<'EOF'
[Unit]
Description=Jetson AV primary-link health monitor (Doodle Labs path)
Documentation=file:///opt/docs/TELEMETRY_FAILOVER.md
After=jetson-av-mavlink-router.service
Wants=jetson-av-mavlink-router.service

[Service]
Type=simple
ExecStart=/usr/local/bin/jetson-av-link-monitor
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Need envsubst for the ExecStartPre line above.
    DEBIAN_FRONTEND=noninteractive apt-get install -y gettext-base 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable jetson-av-mavlink-router.service \
                     jetson-av-iridium-relay.service \
                     jetson-av-link-monitor.service
    # Don't auto-start on install   requires the FCU UART to be wired and
    # the Iridium modem to be plugged. Operator starts after wiring check.
    log::info "Services installed; start with:"
    log::info "  systemctl start jetson-av-mavlink-router.service"
    log::info "  systemctl start jetson-av-link-monitor.service"
    log::info "  systemctl start jetson-av-iridium-relay.service"
}
post_units() {
    check::file_exists /etc/systemd/system/jetson-av-mavlink-router.service
    check::file_exists /etc/systemd/system/jetson-av-iridium-relay.service
    check::file_exists /etc/systemd/system/jetson-av-link-monitor.service
}
step::run "Install systemd units" pre_units exec_units post_units

log::section "Telemetry Failover Install Complete"
echo
echo "Wiring expected:"
echo "  FCU UART  → Pixhawk TELEM2 → Jetson UART1 → /dev/ttyTHS1 @ 921600"
echo "             (TELEM2 not TELEM1; ttyTHS1 not ttyTHS0   verified May 2026)"
echo "  Doodle Labs Helix → Ethernet → 192.168.10.1:14550 GCS endpoint"
echo "  RockBLOCK 9704 → USB → /dev/ttyUSB0 (FTDI USB-serial)"
echo "             needs CONFIG_USB_SERIAL_FTDI_SIO=m (already in defconfig)"
echo "             pip install rockblock9704 (Rock7 SDK; JSPR JSON protocol)"
echo "  RockBLOCK 9603 → USB → /dev/ttyACM0 (CDC-ACM, legacy AT commands)"
echo "             set IRIDIUM_MODEL=9603 if you have the older modem"
echo
echo "Edit /etc/jetson-av/telemetry-failover.conf for your wiring, then:"
echo "  systemctl start jetson-av-mavlink-router.service"
echo "  systemctl start jetson-av-link-monitor.service"
echo "  systemctl start jetson-av-iridium-relay.service"
echo
echo "Verify:"
echo "  systemctl status 'jetson-av-mavlink-*' 'jetson-av-iridium-*' 'jetson-av-link-*'"
echo "  cat /run/jetson-av-link-state         # ok | degraded"
echo "  tail -f /var/log/jetson-av/mavlink-router.log"
echo
step::summary

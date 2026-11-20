#!/usr/bin/env bash
# =============================================================================
#  🧪 Novu-Proxmox – Mock-Harness
#  Testet install/novu.sh End-to-End gegen gemockte Proxmox-/Docker-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/apt/docker/systemctl/ip/hostname/getent als Mocks (Fakebin)
#   - Inner-Script läuft ECHT (nur Pfade auf Mock-Root umgeschrieben, Docker &
#     systemctl gemockt) – inkl. Bootstrap-Reihenfolge (nacktes Debian: kein
#     curl, kein docker → apt "installiert" curl, get.docker.com docker)
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="/home/phil/Proxmox-Scripts/Novu-Proxmox/install/novu.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/novu-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"                       # Mock-Status (ct_list, Calls, Hebel)
HOSTBIN="$MK/bin-host"               # Mocks für das HOST-Script
INNERBIN="$MK/bin-inner"             # Mocks für pct-exec (im CT)
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.42"

echo "$CT_IP" > "$HS/ct_ip"
: > "$HS/ct_list"                    # Zeilen: "VMID Status Lock-Name(=Name letztes Feld)"
echo "getent_mode=ok" > "$HS/getent_mode"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }
skipnote() { echo "  – $CUR_NAME übersprungen: $1"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -f "$1" ]]; then pass "Datei: $1"
    else fail "Datei fehlt: $1"; fi
}
assert_no_file() {
    if [[ -f "$1" ]]; then fail "Datei existiert (sollte nicht): $1"
    else pass "Datei fehlt (korrekt): $1"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "$1 enthält: $2"
    else fail "$1 enthält NICHT: $2"; fi
}
assert_no_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then fail "$1 enthält (sollte nicht): $2"
    else pass "$1 ohne: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "$1 matcht: $2"
    else fail "$1 matcht NICHT: $2"; fi
}
assert_calls() { # COUNT needle in mock-calls log (host-mocks: pct/systemctl/apt)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_docker() { # COUNT needle in docker_calls.log (docker compose …)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/docker_calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Docker-Calls ≥$want: $needle (ist $got)"
    else fail "Docker-Calls <$want: $needle (ist $got)"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 40 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 25 "$HS/calls.log" 2>/dev/null
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() { # echte Binaries per Symlink verfügbar halten (Shadowing via PATH-Reihenfolge)
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id hostname
ln -sf "$MK/mock-uname" "$HOSTBIN/uname"
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"

# ── Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN docker) ──────
# PATH im Inner ist AUSSCHLIESSLICH $INNERBIN (kein /usr/bin!) – sonst würde
# ein echtes curl/docker des Desktops das Bootstrap-Design aushebeln.
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-ip"        "$INNERBIN/ip"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"

seed_inner_tools() { # simuliert bereits installiertes curl+docker (Update-Pfad)
    ln -sf "$MK/mock-curl"   "$INNERBIN/curl"
    ln -sf "$MK/mock-docker" "$INNERBIN/docker"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/docker"
}

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-uname" <<'EOF'
#!/usr/bin/env bash
# uname-Mock (HOST): Arch aus $HS/host_arch (Default x86_64 → amd64-Host)
set -u
HS="${HARNESS_STATE:?}"
if [[ "${1:-}" == "-m" ]]; then
    cat "$HS/host_arch" 2>/dev/null || echo "x86_64"
    exit 0
fi
echo "Linux novu-host 6.8.0 mock #1 SMP"; exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        # pct create ID TEMPLATE --flags...
        echo "pct $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        hostname="ct-$id"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${id}.status"
        echo "$hostname" > "$HS/ct_${id}.hostname"
        # Spawn-Fail-Grube (Live-Fund 2026-11-19, CT 211 ProxSmartHome):
        # pct create --start meldet Exit 0, Container läuft TROTZDEM nicht
        # (Arch-Mismatch). Exit 0 + Status stopped simulieren genau das.
        if [[ -f "$HS/create_spawn_fail" ]]; then
            echo "mock: sync_wait: 34 An error occurred in another process (expected sequence number 7)" >&2
            echo "__lxc_start: 2127 Failed to spawn container \"$id\"" >&2
            echo "stopped" > "$HS/ct_${id}.status"
            /bin/sed -i "s|^$id .*|$id stopped $hostname|" "$HS/ct_list"
        fi
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}.hostname"
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Inner-Script: /etc/ und /tmp/-Pfade auf Mock-Root umschreiben.
        # Reihenfolge WICHTIG: /tmp zuerst – die /etc-Ersetzung injiziert selbst
        # ein /tmp/ (Mock-Root liegt unter /tmp) und würde doppelt umgeschrieben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        # pct exec ID -- env K=V... cmd...   (Grube 10: gestoppter CT → Exit 255)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        # Quoted-Heredoc: INNERBIN erst zur LAUFZEIT ableiten ($MK = dirname($HS))
        INNERBIN="$MK/bin-inner"
        # Pfad-Umschreibung: Kommando-Args UND env-Args (Mock-Root).
        # /etc auch umschreiben – sonst schreibt der DNS-Fallback des Installers
        # ins echte /etc der Sandbox!
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/novu/$MK/opt/novu}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    config)
        if [[ ! -f "$HS/ct_${id}.hostname" ]]; then
            echo "mock: CT $id unbekannt" >&2
            exit 2
        fi
        printf 'arch: amd64\ncores: 4\nhostname: %s\nonboot: 1\n' "$(cat "$HS/ct_${id}.hostname")"
        exit 0 ;;
    enter|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
# pveam-Mock: `available` bietet BEIDE Architekturen an (wie ProxSmartHome:
# beide Templates im Cache!) – die arch-korrekte Wahl trifft der Installer.
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
case "${1:-}" in
    list)
        if [[ -s "$HS/downloaded_template" && ! -f "$HS/pveam_empty" ]]; then
            echo "local:vztmpl/$(cat "$HS/downloaded_template")  123456789"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            echo "system          debian-13-standard_13.6-1_arm64.tar.zst  999"
            echo "system          debian-13-standard_13.2-1_amd64.tar.zst  888"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        # Aufruf: pveam download <STORE> <vztmpl/NAME.tar.zst>
        # → $1=download, $2=STORE("local"), $3=NAME
        tname="${3##*/}"
        mkdir -p "$HS/templates"
        touch "$HS/templates/$tname"
        echo "$tname" > "$HS/downloaded_template"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Gesundheitschecks → 200/000; get.docker.com → Stub
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
url=""; outfile=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    https://get.docker.com)
        # get.docker.com-Stub: "installiert" docker + compose-plugin (Mock)
        [[ -n "$outfile" ]] || { echo "curl mock: get.docker.com ohne -o" >&2; exit 1; }
        cat > "$outfile" <<'STUB'
#!/usr/bin/env bash
# get.docker.com-Mock-Stub: installiert docker-CLI + compose-plugin
INNERBIN_DIR="${MKROOT:?MKROOT fehlt}/bin-inner"
ln -sf "$MKROOT/mock-docker" "$INNERBIN_DIR/docker" 2>/dev/null
exit 0
STUB
        chmod +x "$outfile"
        exit 0 ;;
esac

# Health-/HTTP-Checks nach PORT: 3000=API, 3002=WS, 4000(sonst)=Dashboard
code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
case "$url" in
    http://127.0.0.1:3000/*)
        [[ -f "$HS/fail_api" ]] && code="000" ;;
    http://127.0.0.1:3002/*)
        [[ -f "$HS/fail_ws" ]] && code="000" ;;
    http://127.0.0.1:*/)
        [[ -f "$HS/fail_ui" ]] && code="000" ;;
esac
echo "$code"
[[ "$code" == "200" ]] && exit 0 || exit 7
EOF

cat > "$MK/mock-docker" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "docker $*" >> "$HS/docker_calls.log"
sub="${1:-}"
case "$sub" in
    --version|-v) echo "Docker version 27.5.1, build mock"; exit 0 ;;
    info) exit 0 ;;
    ps)
        # `docker ps --filter label=… --format …` (lockfrei, Verifikation/Status)
        [[ -f "$HS/ps_empty" ]] && exit 0
        if [[ -f "$HS/stack_up" ]]; then
            printf 'novu-mongodb running\nnovu-redis running\nnovu-api running\nnovu-worker running\nnovu-ws running\nnovu-dashboard running\n'
        fi
        exit 0 ;;
    compose)
        shift  # "compose"
        # globale Flags mit Werten überspringen (--project-directory DIR, --file F)
        while [[ "${1:-}" == --* ]]; do
            case "$1" in
                --project-directory|--file|-f) shift 2 ;;
                *) shift ;;
            esac
        done
        c="${1:-}"
        case "$c" in
            version) echo "Docker Compose version v2.39.2"; exit 0 ;;
            config)
                [[ -f "$HS/docker_config_fail" ]] && exit 1
                exit 0 ;;
            pull)   exit 0 ;;
            up)
                if [[ -f "$HS/compose_up_fail" ]]; then
                    echo "Container novu-mongodb Error dependency mongodb failed to start" >&2
                    echo "dependency failed to start: container novu-mongodb is unhealthy" >&2
                    exit 1
                fi
                touch "$HS/stack_up"; exit 0 ;;
            stop)   rm -f "$HS/stack_up"; exit 0 ;;
            ps)
                [[ -f "$HS/ps_empty" ]] && exit 0
                if [[ -f "$HS/stack_up" ]]; then
                    printf 'mongodb running\nredis running\napi running\nworker running\nws running\ndashboard running\n'
                fi
                exit 0 ;;
            logs)   echo "mock-compose-log-line"; exit 0 ;;
            *)      exit 0 ;;
        esac ;;
    logs)
        # `docker logs --tail 25 novu-mongodb` (Mongo-Diagnose bei Stack-Fehler)
        echo "WARNING: MongoDB 5.0+ requires a CPU with AVX support"
        echo "/usr/local/bin/docker-entrypoint.sh: line 416: 26 Illegal instruction"
        exit 0 ;;
    *) echo "mock-docker: $sub (ignored)"; exit 0 ;;
esac
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
MKDIR_MOCK="$MK"
unitdir="$MKDIR_MOCK/etc/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable)
        mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start)
        if [[ "${2:-}" == "novu" ]]; then
            [[ -f "$unitdir/novu.service" ]] || { echo "mock: novu.service fehlt" >&2; exit 1; }
            touch "$HS/novu_active"
        elif [[ "${2:-}" == "docker" ]]; then
            touch "$HS/docker_active"
        fi
        exit 0 ;;
    stop)
        rm -f "$HS/novu_active" "$HS/docker_active"; exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ "$svc" == "novu" && -f "$HS/novu_active" ]]; then exit 0; fi
        if [[ "$svc" == "docker" && -f "$HS/docker_active" ]]; then exit 0; fi
        exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-ip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP group default qlen 1000\n'
printf '    inet %s/24 scope global eth0\n       valid_lft forever preferred_lft forever\n' "$IP"
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "novu"; exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | flaky (jeder 4. failt) | fail_then_ok (9x fail, dann ok)
set -u
HS="${HARNESS_STATE:?}"
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 4)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        # 9x fail → Loop bricht bei Try 10 ab → Fallback → Post-Check (Call 10) erfolgreich
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl real in der Inner-Fakebin (Bootstrap-Reihenfolge)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        if [[ "$a" == "curl" && ! -e "$INNERBIN_DIR/curl" ]]; then
            ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl"
        fi
        if [[ "$a" == docker* && ! -e "$INNERBIN_DIR/docker" ]]; then
            ln -sf "$MK/mock-docker" "$INNERBIN_DIR/docker"
        fi
    done
fi
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS"; mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/etc/dhcp" \
        "$MK/opt" "$MK/opt/novu" "$MK/root" "$MK/var/log" "$MK/tmp"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
    echo "x86_64" > "$HS/host_arch"      # Default: amd64-Host (aarch64-Cases setzen um)
}
run_installer() {
    # NOVU_FORCE_NO_AVX: Test-Haken des Installers (CPU ohne AVX simulieren),
    # muss durch env -i durchgereicht werden.
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        ${NOVU_FORCE_NO_AVX:+NOVU_FORCE_NO_AVX="$NOVU_FORCE_NO_AVX"} \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_stdin() {
    local input="$1"; shift
    ( printf '%s' "$input" | unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem Stack
    reset_state
    echo "200 running novu" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "novu" > "$HS/ct_200.hostname"
    mkdir -p "$MK/opt/novu" "$MK/etc/systemd/system" "$MK/etc" "$MK/var/log"
    seed_inner_tools
    touch "$HS/stack_up" "$HS/novu_active"
    touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
    echo "debian-13-standard_13.2-1_amd64.tar.zst" > "$HS/downloaded_template"
    touch "$MK/etc/systemd/system/novu.service"
    write_seed_env
}
write_seed_env() {
    cat > "$MK/opt/novu/.env" <<ENVSEED
NOVU_VERSION=3.20.0
JWT_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STORE_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
NOVU_SECRET_KEY=cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe
MONGO_INITDB_ROOT_USERNAME=root
MONGO_INITDB_ROOT_PASSWORD=abcdefabcdefabcdefabcdefabcdefab
MONGO_URL=mongodb://root:abcdefabcdefabcdefabcdefabcdefab@mongodb:27017/novu-db?authSource=admin
MONGO_MIN_POOL_SIZE=5
MONGO_MAX_POOL_SIZE=10
MONGO_AUTO_CREATE_INDEXES=true
NODE_ENV=local
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_CACHE_SERVICE_HOST=
REDIS_CACHE_SERVICE_PORT=6379
REDIS_PASSWORD=
REDIS_SKIP_VERSION_CHECK=false
S3_BUCKET_NAME=novu-local
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
API_PORT=3000
WS_PORT=3002
WORKER_PORT=3004
SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME=15d
NOVU_TOKEN_SIGNING_KEYS=
DISABLE_USER_REGISTRATION=false
IS_API_IDEMPOTENCY_ENABLED=false
IS_API_RATE_LIMITING_ENABLED=false
IS_NEW_MESSAGES_API_RESPONSE_ENABLED=true
IS_V2_ENABLED=true
IS_SELF_HOSTED=true
IS_EMAIL_INLINE_CSS_DISABLED=false
IS_USE_MERGED_DIGEST_ID_ENABLED=false
SENTRY_DSN=
NEW_RELIC_ENABLED=false
NEW_RELIC_APP_NAME=
NEW_RELIC_LICENSE_KEY=
BROADCAST_QUEUE_CHUNK_SIZE=100
MULTICAST_QUEUE_CHUNK_SIZE=100
UI_PORT=4000
HOST_NAME=http://$CT_IP
VITE_API_HOSTNAME=http://$CT_IP:3000
VITE_WEBSOCKET_HOSTNAME=http://$CT_IP:3002
API_ROOT_URL=http://$CT_IP:3000
FRONT_BASE_URL=http://$CT_IP:4000
S3_LOCAL_STACK=http://$CT_IP:4566
ENVSEED
}

ENV_PATH="$MK/opt/novu/.env"
COMPOSE_PATH="$MK/opt/novu/docker-compose.yml"

echo "════════════════════════════════════════════════════════════"
echo " 🧪 Novu-Proxmox Harness – $(date +%H:%M:%S)"
echo "════════════════════════════════════════════════════════════"

# ════════════════ A. Argumente & Grundlagen ════════════════
t "--help"
ec=$(run_installer --help); assert_exit 0 "$ec"
assert_out "Novu – Proxmox-Installer"
assert_out "--update"

t "unbekannte Option"
ec=$(run_installer --schnulli); assert_exit 1 "$ec"
assert_out "Unbekannte Option: --schnulli"

t "--port ungültig"
ec=$(run_installer --port abc); assert_exit 1 "$ec"
assert_out "Ungültiger UI-Port: 'abc'"

t "--port == API-Port (3000 fix)"
ec=$(run_installer --port 3000); assert_exit 1 "$ec"
assert_out "kollidiert mit API"

t "--port == WS-Port (3002 fix)"
ec=$(run_installer --port 3002); assert_exit 1 "$ec"
assert_out "kollidiert mit API"

t "--version ungültig"
ec=$(run_installer --versionXYZ 1.2); assert_exit 1 "$ec"
assert_out "Unbekannte Option: --versionXYZ"

t "\$0-Fallback (bash -c-Muster)"
ec=$( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
      bash -c "$(<"$SCRIPT")" --status > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 0 "$ec"
assert_out "Status Novu"

t "nächste freie CT-ID (200-202 belegt)"
reset_state
printf '200 running foo\n201 running bar\n202 running baz\n' > "$HS/ct_list"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Nächste freie CT-ID: 203"
assert_fcontains "$HS/ct_203.create" "hostname novu"

t "pct list ohne Lock-Spalte (Name \$NF)"
reset_state
printf '200 running novu\n' > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"; echo "novu" > "$HS/ct_200.hostname"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – novu"

t "pct list mit doppeltem Leerzeichen (Lock leer)"
reset_state
printf '200 running  novu\n' > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"; echo "novu" > "$HS/ct_200.hostname"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – novu"

# ════════════════ B. Install Happy Path ════════════════
t "Install End-to-End (nacktes Debian: curl+docker bootstrappen)"
reset_state
unseed_inner_tools
ec=$(run_installer); assert_exit 0 "$ec"

assert_out "Container-IP: $CT_IP"
assert_out "DNS im Container funktioniert (3x bestätigt)"
assert_out "debian-13-standard_13.2"
assert_calls 1 "pct create 200"
assert_fcontains "$HS/ct_200.create" "unprivileged"
assert_fcontains "$HS/ct_200.create" "nesting=1,keyctl=1"
assert_fcontains "$HS/ct_200.create" "onboot 1"
assert_fcontains "$HS/ct_200.create" "memory 4096"
assert_fcontains "$HS/ct_200.create" "swap 1024"
assert_fregex "$HS/ct_200.create" "rootfs local-lvm:20"
assert_fcontains "$HS/ct_200.create" "firewall=0"
assert_calls 1 "apt-get install -y -qq curl"
assert_calls 1 "get.docker.com"
assert_file "$COMPOSE_PATH"
assert_file "$MK/opt/novu/sync-env-urls.sh"
assert_file "$MK/etc/systemd/system/novu.service"
assert_file "$MK/var/log/novu-setup.log"
assert_calls 1 "systemctl enable novu"
assert_calls 1 "systemctl start novu"
[[ -f "$HS/novu_active" ]] && pass "Service aktiv nach Install" || fail "novu_active fehlt"
[[ -f "$HS/stack_up" ]] && pass "Compose-Stack up" || fail "stack_up fehlt"
# Compose ist EINGEBETTET – kein Download von raw.githubusercontent (aktuelles
# upstream-Compose pinnt noch 3.19.0 → wir pinnen selbst auf NOVU_VERSION)
assert_no_calls "raw.githubusercontent.com"

# Zusammenfassung-Asserts laufen im selben out.log wie Install E2E (t nicht neu anlegen)
assert_out "📣  Novu ist bereit!"
assert_out "http://$CT_IP:4000"
assert_out "http://$CT_IP:3000"
assert_out "http://$CT_IP:3002"
assert_out "Service novu läuft (systemctl is-active)"
assert_out "Alle Compose-Services laufen (mongodb, redis, api, worker, ws, dashboard)"
assert_out "API gesund (HTTP 200 auf Port 3000)"
assert_out "Web-Dashboard antwortet (HTTP 200 auf Port 4000)"
assert_out "WebSocket-Service gesund (HTTP 200 auf Port 3002)"
assert_out "Vom Host erreichbar: http://$CT_IP:4000 (HTTP 200)"
assert_out "Status:    bash -c"
assert_out "Update:    bash -c"
assert_out "Deinstall: bash -c"

t "Compose: 6 Services, Images gepinnt, Mongo/Redis ohne Ports"
assert_fcontains "$COMPOSE_PATH" 'image: "${IMAGE_PREFIX}/api:${NOVU_VERSION}"'
assert_fcontains "$COMPOSE_PATH" 'image: "${IMAGE_PREFIX}/worker:${NOVU_VERSION}"'
assert_fcontains "$COMPOSE_PATH" 'image: "${IMAGE_PREFIX}/ws:${NOVU_VERSION}"'
assert_fcontains "$COMPOSE_PATH" 'image: "${IMAGE_PREFIX}/dashboard:${NOVU_VERSION}"'
assert_fcontains "$COMPOSE_PATH" 'image: "mongo:${MONGO_VERSION}"'   # Pin aus .env
assert_fcontains "$ENV_PATH" "MONGO_VERSION=8.0.17"
assert_fcontains "$COMPOSE_PATH" 'image: "redis:alpine"'
assert_fcontains "$COMPOSE_PATH" '"${UI_PORT}:4000"'
assert_fcontains "$COMPOSE_PATH" '"${API_PORT}:${API_PORT}"'
assert_fcontains "$COMPOSE_PATH" '"${WS_PORT}:${WS_PORT}"'
assert_no_fcontains "$COMPOSE_PATH" '27017:27017'   # Mongo NICHT exponiert
assert_no_fcontains "$COMPOSE_PATH" '6379:6379'     # Redis NICHT exponiert
assert_fcontains "$COMPOSE_PATH" 'name: novu'
n_restart=$(/bin/grep -c 'restart: unless-stopped' "$COMPOSE_PATH" || true)
[[ "$n_restart" -ge 6 ]] && pass "6x restart: unless-stopped" || fail "restart-Policies: nur $n_restart"

t ".env vollständig & Secrets-Format"
assert_fregex "$ENV_PATH" '^NOVU_VERSION=3\.20\.0$'
assert_fregex "$ENV_PATH" '^JWT_SECRET=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH" '^STORE_ENCRYPTION_KEY=[0-9a-f]{32}$'   # EXAKT 32 Zeichen
assert_fregex "$ENV_PATH" '^NOVU_SECRET_KEY=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH" '^MONGO_INITDB_ROOT_PASSWORD=[0-9a-f]{32}$'
assert_fregex "$ENV_PATH" '^MONGO_URL=mongodb://root:[0-9a-f]{32}@mongodb:27017/novu-db\?authSource=admin$'
assert_fcontains "$ENV_PATH" "NODE_ENV=local"
assert_fcontains "$ENV_PATH" "IS_SELF_HOSTED=true"
assert_fcontains "$ENV_PATH" "IS_V2_ENABLED=true"
assert_fcontains "$ENV_PATH" "DISABLE_USER_REGISTRATION=false"
assert_fcontains "$ENV_PATH" "NEW_RELIC_ENABLED=false"
assert_fcontains "$ENV_PATH" "SENTRY_DSN="
assert_fcontains "$ENV_PATH" "UI_PORT=4000"
assert_fcontains "$ENV_PATH" "API_PORT=3000"
assert_fcontains "$ENV_PATH" "WS_PORT=3002"
assert_fcontains "$ENV_PATH" "HOST_NAME=http://$CT_IP"
assert_fcontains "$ENV_PATH" "VITE_API_HOSTNAME=http://$CT_IP:3000"
assert_fcontains "$ENV_PATH" "VITE_WEBSOCKET_HOSTNAME=http://$CT_IP:3002"
assert_fcontains "$ENV_PATH" "API_ROOT_URL=http://$CT_IP:3000"
assert_fcontains "$ENV_PATH" "FRONT_BASE_URL=http://$CT_IP:4000"
assert_fcontains "$ENV_PATH" "S3_LOCAL_STACK=http://$CT_IP:4566"
perms=$(stat -c '%a' "$ENV_PATH" 2>/dev/null || echo "?")
[[ "$perms" == "600" ]] && pass ".env chmod 600" || fail ".env chmod: $perms (600 erwartet)"

t "systemd-Unit: detached Bootstrap + Prod-Pfade"
UNIT="$MK/etc/systemd/system/novu.service"
assert_fcontains "$UNIT" "Type=oneshot"
assert_fcontains "$UNIT" "RemainAfterExit=yes"
assert_fcontains "$UNIT" "ExecStartPre=/opt/novu/sync-env-urls.sh"
assert_fcontains "$UNIT" "ExecStart=/usr/bin/docker compose --project-directory /opt/novu up -d --pull=missing"
assert_fcontains "$UNIT" "After=network-online.target docker.service"
assert_fcontains "$UNIT" "TimeoutStartSec=900"
assert_fcontains "$UNIT" "WantedBy=multi-user.target"

t "Sync-Script: dirname-basiert + ausführbar"
SYNC="$MK/opt/novu/sync-env-urls.sh"
assert_fcontains "$SYNC" 'BASH_SOURCE[0]'
assert_no_fcontains "$SYNC" "cd /opt/novu"
assert_fcontains "$SYNC" 'HOST_NAME'
assert_fcontains "$SYNC" 'VITE_API_HOSTNAME'
assert_fcontains "$SYNC" 'VITE_WEBSOCKET_HOSTNAME'
perms=$(stat -c '%a' "$SYNC" 2>/dev/null || echo "?")
[[ "$perms" == "755" || "$perms" == "775" ]] && pass "sync-env-urls.sh chmod $perms" || fail "sync chmod: $perms"

t "Install mit --port 4400"
reset_state; unseed_inner_tools
ec=$(run_installer --port 4400); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "UI_PORT=4400"
assert_fcontains "$COMPOSE_PATH" '"${UI_PORT}:4000"'   # Container-intern fix 4000
assert_out "http://$CT_IP:4400"

t "Install mit --version Pin-Override"
reset_state; unseed_inner_tools
ec=$(run_installer --version 3.21.0); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "NOVU_VERSION=3.21.0"

t "Install mit --mongo-version 4.4.29 (AVX-freie Linie)"
reset_state; unseed_inner_tools
ec=$(run_installer --mongo-version 4.4.29); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "MONGO_VERSION=4.4.29"
assert_fcontains "$COMPOSE_PATH" 'image: "mongo:${MONGO_VERSION}"'

t "AVX fehlt + Mongo >= 5 → Abbruch VOR Container-Anlage (Live-Grube CT 204)"
reset_state; unseed_inner_tools
ec=$(NOVU_FORCE_NO_AVX=1 run_installer); assert_exit 1 "$ec"
assert_out "Diese CPU hat KEIN AVX"
assert_out "Option A – auf anderer Hardware installieren (EMPFOHLEN)"
assert_out "--mongo-version 4.4.29"
assert_no_calls "pct create"

t "AVX fehlt + --mongo-version 4.4.29 → läuft durch (Notausgang)"
reset_state; unseed_inner_tools
ec=$(NOVU_FORCE_NO_AVX=1 run_installer --mongo-version 4.4.29); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "MONGO_VERSION=4.4.29"

t "Compose-Start scheitert → Mongo-Logs + AVX-Hinweis (Live-Grube Exit 132)"
seed_ct
touch "$HS/compose_up_fail"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "--- docker logs novu-mongodb (letzte 25 Zeilen) ---"
assert_out "docker compose up -d fehlgeschlagen"
assert_out "Illegal instruction"
rm -f "$HS/compose_up_fail"

t "--mongo-version ungültig → die"
ec=$(run_installer --mongo-version abc); assert_exit 1 "$ec"
assert_out "Ungültige MongoDB-Version: 'abc'"

t "Install mit statischer IP (--ip)"
reset_state; unseed_inner_tools
echo "192.168.178.77" > "$HS/ct_ip"   # ip/hostname-Mock liefern die statische IP
ec=$(run_installer --ip 192.168.178.77/24 --gateway 192.168.178.1); assert_exit 0 "$ec"
cp "$HS/ct_200.create" "$CUR_DIR/create.snapshot" 2>/dev/null || true
assert_fcontains "$CUR_DIR/create.snapshot" "ip=192.168.178.77/24,gateway=192.168.178.1"
assert_out "http://192.168.178.77:4000"
assert_fcontains "$ENV_PATH" "HOST_NAME=http://192.168.178.77"

# ════════════════ C. Update / Idempotenz ════════════════
t "--update: Secrets bleiben erhalten"
seed_ct
cat > "$ENV_PATH" <<ENVSEED
NOVU_VERSION=3.20.0
JWT_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STORE_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
NOVU_SECRET_KEY=cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe
MONGO_INITDB_ROOT_USERNAME=root
MONGO_INITDB_ROOT_PASSWORD=abcdefabcdefabcdefabcdefabcdefab
MONGO_URL=mongodb://root:abcdefabcdefabcdefabcdefabcdefab@mongodb:27017/novu-db?authSource=admin
DISABLE_USER_REGISTRATION=true
UI_PORT=4000
API_PORT=3000
WS_PORT=3002
HOST_NAME=http://$CT_IP
VITE_API_HOSTNAME=http://$CT_IP:3000
VITE_WEBSOCKET_HOSTNAME=http://$CT_IP:3002
API_ROOT_URL=http://$CT_IP:3000
FRONT_BASE_URL=http://$CT_IP:4000
S3_LOCAL_STACK=http://$CT_IP:4566
ENVSEED
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "JWT_SECRET=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
assert_fcontains "$ENV_PATH" "STORE_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef"
assert_fcontains "$ENV_PATH" "NOVU_SECRET_KEY=cafebabe"
assert_fcontains "$ENV_PATH" "MONGO_INITDB_ROOT_PASSWORD=abcdefabcdefabcdefabcdefabcdefab"
assert_fcontains "$ENV_PATH" "DISABLE_USER_REGISTRATION=true"   # Nutzer-Änderung erhalten
assert_docker 1 "docker compose pull"
assert_docker 1 "docker compose up -d"
assert_calls 1 "systemctl stop novu"
assert_calls 1 "systemctl start novu"
assert_out "Daten (MongoDB-Volume) blieben erhalten"

t "--update: NOVU_VERSION wird auf Installer-Pin gezogen"
seed_ct
/bin/sed -i 's/^NOVU_VERSION=.*/NOVU_VERSION=3.19.0/' "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "NOVU_VERSION=3.20.0"

t "--update --port 4400 überschreibt UI_PORT"
seed_ct
ec=$(run_installer --update --port 4400); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "UI_PORT=4400"

t "--update: UI_PORT aus .env bleibt (ohne --port)"
seed_ct
/bin/sed -i 's/^UI_PORT=.*/UI_PORT=4545/' "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "UI_PORT=4545"

t "--update mit IP-Wechsel: sync-env-urls aktualisiert .env"
seed_ct
/bin/sed -i "s|^HOST_NAME=.*|HOST_NAME=http://10.0.0.99|" "$ENV_PATH"
/bin/sed -i "s|^VITE_API_HOSTNAME=.*|VITE_API_HOSTNAME=http://10.0.0.99:3000|" "$ENV_PATH"
/bin/sed -i "s|^API_ROOT_URL=.*|API_ROOT_URL=http://10.0.0.99:3000|" "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "HOST_NAME=http://$CT_IP"
assert_fcontains "$ENV_PATH" "VITE_API_HOSTNAME=http://$CT_IP:3000"
assert_fcontains "$ENV_PATH" "VITE_WEBSOCKET_HOSTNAME=http://$CT_IP:3002"
assert_fcontains "$ENV_PATH" "API_ROOT_URL=http://$CT_IP:3000"
assert_fcontains "$ENV_PATH" "FRONT_BASE_URL=http://$CT_IP:4000"
assert_fcontains "$ENV_PATH" "S3_LOCAL_STACK=http://$CT_IP:4566"
assert_out "novu-sync: CT-IP geändert"

t "sync-env-urls: gleiche IP → unverändert"
seed_ct
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "novu-sync: CT-IP unverändert"
assert_fcontains "$ENV_PATH" "HOST_NAME=http://$CT_IP"

t "sync-env-urls: keine IPv4 → .env unangetastet, exit 0"
seed_ct
touch "$HS/no_ip"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "keine globale IPv4 an eth0"
assert_fcontains "$ENV_PATH" "HOST_NAME=http://$CT_IP"
rm -f "$HS/no_ip"

# ════════════════ D. Fehlerpfade ════════════════
t "docker compose config-Fehler → Kette + bash -x-Hinweis"
seed_ct
touch "$HS/docker_config_fail"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Installationsfehler – Exit-Code 1"
assert_out "docker compose config meldet Fehler"
assert_out "Vollständiges Log:"
assert_out "Neu ausführen mit vollem bash -x-Trace"
rm -f "$HS/docker_config_fail"

t "API-Health tot → die mit Debug-Hinweis"
seed_ct
touch "$HS/fail_api"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "API antwortet nicht mit 200"
assert_out "docker compose logs --tail 50 api"
rm -f "$HS/fail_api"

t "Dashboard-Health tot → die"
seed_ct
touch "$HS/fail_ui"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Web-Dashboard antwortet nicht mit 200"
rm -f "$HS/fail_ui"

t "WS-Health tot → die"
seed_ct
touch "$HS/fail_ws"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "WebSocket-Service antwortet nicht mit 200"
rm -f "$HS/fail_ws"

t "Compose-Services fehlen (ps leer trotz up)"
seed_ct
touch "$HS/ps_empty"
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Compose-Services fehlen oder sind nicht hochgekommen"
rm -f "$HS/ps_empty"

t "keine Container-IP → Fehlerkette (on_error)"
reset_state
touch "$HS/no_hostname_ip"   # hostname -I bleibt leer → Poll läuft 60x leer → on_error
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Container hat nach 60 s keine IP bekommen"
assert_out "Installationsfehler – Exit-Code 1"
assert_out "Fehlgeschlagener Befehl"
assert_out "Container 200 wurde NICHT gelöscht"
assert_out "pct enter 200"
rm -f "$HS/no_hostname_ip"

t "pct exec Exit 255 (Grube 10) → Kette"
reset_state
touch "$HS/exec_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Installationsfehler – Exit-Code 1"
rm -f "$HS/exec_fail"

t "DNS total defekt → die mit Fallback-Diagnose"
reset_state
echo "getent_mode=fail" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "DNS im Container weiterhin ohne Funktion"
assert_out "ausgehende DNS-Anfragen (Port 53)"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"

t "DNS flaky → Fallback + dhclient-Hook, dann Erfolg"
reset_state
echo "getent_mode=fail_then_ok" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt"
assert_file "$MK/etc/dhcp/dhclient-enter-hooks.d/no-dns"

t "Template komplett fehlend → die"
reset_state
touch "$HS/pveam_empty"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Kein debian-12/13-standard-Template für amd64 gefunden"
rm -f "$HS/pveam_empty"

t "Template-Download-Pfad (list leer, available da)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Kein Debian-12/13-amd64-Template im Cache – lade es herunter"
assert_calls 1 "pveam download local"
assert_calls 1 "pct create 200"

t "aarch64-Host wählt ARM64-Template (ProxSmartHome-Grube, Arch-Filter)"
reset_state; unseed_inner_tools
echo "aarch64" > "$HS/host_arch"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Host-Architektur: arm64"
assert_fcontains "$HS/ct_200.create" "debian-13-standard_13.6-1_arm64.tar.zst"
assert_no_fcontains "$HS/ct_200.create" "_amd64"

t "amd64-Host wählt NICHT das neuere arm64-Template (Live-Fund CT 211)"
reset_state; unseed_inner_tools
echo "x86_64" > "$HS/host_arch"     # available: 13.6-1_arm64 NEUER als 13.2-1_amd64
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Host-Architektur: amd64"
assert_fcontains "$HS/ct_200.create" "debian-13-standard_13.2-1_amd64.tar.zst"
assert_no_fcontains "$HS/ct_200.create" "_arm64"

t "Spawn-Fehler trotz pct create Exit 0 → sofort die mit Aufräumen-Hinweis (CT 211-Grube)"
reset_state; unseed_inner_tools
touch "$HS/create_spawn_fail"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Container 200 startet nicht (Status: stopped"
assert_out "meldete trotzdem Exit 0"
assert_out "pct destroy 200 --purge"
# Kein sinnloser IP-Poll (Live: 60 s Wartezeit):
assert_no_out "Warte auf Netzwerk im Container"
rm -f "$HS/create_spawn_fail"

t "existierender CT ohne --force → die mit Update-Hinweis"
seed_ct
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "existiert bereits"
assert_out "--update"

t "--force: destroy + recreate"
seed_ct
ec=$(run_installer --force); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_calls 1 "pct create 200"
assert_out "existiert – --force: lösche und lege neu an"

t "--update ohne CT → die"
reset_state
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Kein Novu-Container gefunden"
assert_out "Erst installieren"
assert_out "--update --id 204"

t "--update mit expliziter --id (Hostname-Suche leer)"
seed_ct
: > "$HS/ct_list"          # List-Suche findet nichts – --id zwingt die ID durch
ec=$(run_installer --update --id 200); assert_exit 0 "$ec"
assert_docker 1 "docker compose pull"
assert_out "Update abgeschlossen"

t "--update mit unbekannter --id → die"
seed_ct
ec=$(run_installer --update --id 999); assert_exit 1 "$ec"
assert_out "--id 999 unbekannt"

t "pct list Format-Abweichung → pct config-Fallback"
seed_ct
printf '200 running vm200-irgendwas\n' > "$HS/ct_list"   # $NF != novu → Fallback
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Service:   novu läuft"

t "nicht-root (EUID-Check via env ohne unshare)"
ec=$( env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" HARNESS_STATE="$HS" HOME=/root TERM=dumb \
      bash "$SCRIPT" > "$CUR_DIR/out.log" 2>&1; echo $? )
assert_exit 1 "$ec"
assert_out "Bitte als root ausführen"

# ════════════════ E. Uninstall ════════════════
t "--uninstall ohne CT"
reset_state
ec=$(run_installer --uninstall); assert_exit 0 "$ec"
assert_out "nichts zu tun"

t "--uninstall mit Bestätigung 'ja'"
seed_ct
ec=$(run_installer_stdin $'ja\n' --uninstall); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_no_file "$HS/ct_200.status"
assert_out "Container 200 entfernt."

t "--uninstall mit 'nein' → Abbruch"
seed_ct
ec=$(run_installer_stdin $'nein\n' --uninstall); assert_exit 0 "$ec"
assert_out "Abgebrochen – nichts gelöscht."
assert_file "$HS/ct_200.status"
assert_no_calls "pct destroy"

t "--uninstall nicht-interaktiv → die"
seed_ct
ec=$(run_installer_devnull --uninstall); assert_exit 1 "$ec"
assert_out "Keine Bestätigung erhalten"
assert_out "--uninstall --yes"
assert_file "$HS/ct_200.status"

t "--uninstall --yes (ohne Rückfrage)"
seed_ct
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_out "Container 200 entfernt."

# ════════════════ F. Update-Verwaltungswege ════════════════
t "--update auf gestopptem CT → startet ihn selbst (Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s/^200 .*/200 stopped novu/" "$HS/ct_list"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_calls 1 "pct start 200"
assert_out "läuft nicht (Status: stopped) – starte ihn"
assert_out "Update abgeschlossen"

t "--status: laufender Stack + Signup offen"
seed_ct
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Service:   novu läuft"
assert_out "Stack:     novu-mongodb running"
assert_out "Version:   Novu 3.20.0"
assert_out "Signup:    OFFEN"
assert_out "Dashboard: http://$CT_IP:4000  (HTTP 200)"
assert_out "API:       http://$CT_IP:3000  (HTTP 200)"

t "--status: Signup geschlossen"
seed_ct
/bin/sed -i 's/^DISABLE_USER_REGISTRATION=.*/DISABLE_USER_REGISTRATION=true/' "$ENV_PATH"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Signup:    geschlossen"

t "--status: gestoppter CT"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i "s/^200 .*/200 stopped novu/" "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "nicht gestartet (stopped)"
assert_out "pct start 200"

t "--status: CT fehlt"
reset_state
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Kein Novu-Container gefunden"
assert_out "Installieren:  bash -c"
assert_out "--status --id 204"

t "Host-Check tot → warn, install trotzdem exit 0"
seed_ct
touch "$HS/host_curl_fail"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_out "vom Proxmox-Host nicht erreichbar (HTTP 000"
rm -f "$HS/host_curl_fail"

t "sshkey-Install (--sshkey Datei)"
reset_state; unseed_inner_tools
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@host\n' > "$MK/testkey.pub"
ec=$(run_installer --sshkey "$MK/testkey.pub"); assert_exit 0 "$ec"
assert_fcontains "$HS/ct_200.create" "ssh-public-keys"

t "sshkey-Datei fehlt → die"
reset_state
ec=$(run_installer --sshkey /nicht/da.pub); assert_exit 1 "$ec"
assert_out "SSH-Key-Datei nicht gefunden"

# ════════════════ G. Bootstrap-Reihenfolge (Grube 21) ════════════════
t "nacktes CT: apt curl-Install VOR get.docker.com-Download"
reset_state
unseed_inner_tools
: > "$HS/calls.log"
ec=$(run_installer); assert_exit 0 "$ec"
first_apt=$(/bin/grep -n '^apt-get ' "$HS/calls.log" | head -1 | cut -d: -f1 || echo 99999)
first_curl_docker=$(/bin/grep -n '^curl .*get.docker.com' "$HS/calls.log" | head -1 | cut -d: -f1 || echo 0)
if [[ "$first_apt" -lt "$first_curl_docker" ]]; then
    pass "apt-get (Zeile $first_apt) vor get.docker.com (Zeile $first_curl_docker)"
else
    fail "Bootstrap-Reihenfolge: apt=$first_apt, get.docker=$first_curl_docker"
fi

t "Update-CT: kein apt/get.docker nötig (bereits installiert)"
seed_ct
: > "$HS/calls.log"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_no_calls "apt-get"
assert_no_calls "get.docker.com"

# ════════════════ Zusammenfassung ════════════════
echo "════════════════════════════════════════════════════════════"
echo " 📊 Ergebnis: $PASSED bestanden, $FAILED fehlgeschlagen"
echo "════════════════════════════════════════════════════════════"
if [[ $FAILED -gt 0 ]]; then
    echo "✘ Harness ROT"
    exit 1
fi
echo "✔ Harness GRÜN"
exit 0

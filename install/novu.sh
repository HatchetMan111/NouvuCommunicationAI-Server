#!/usr/bin/env bash
# =============================================================================
#  📣 Novu – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/NouvuCommunicationAI-Server
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Novu (https://github.com/novuhq/novu): die Open-Source-Notification-
#  Infrastruktur – Multi-Channel-Notifications (In-App, E-Mail, SMS, Push,
#  Chat) über eine einzige API, mit Workflow-Dashboard und Embedded
#  Notification Center. Nach dem Vorbild der Proxmox VE Community Scripts.
#
#  Architektur im Container: Docker CE + die OFFIZIELLE Novu-Community-
#  Compose (docker/community, v3.x – Images von ghcr.io/novuhq, GEPINNT auf
#  NOVU_VERSION) + systemd-Unit `novu`. Im Stack: dashboard (Web-UI, :4000),
#  api (:3000), ws (WebSockets, :3002), worker + redis + mongo (intern,
#  NICHT exponiert). UI, API und WS lauschen auf 0.0.0.0 – von jedem Gerät
#  im LAN erreichbar. KEINE Cloud-Dienste, Telemetrie (Sentry/New Relic) AUS.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NouvuCommunicationAI-Server/main/install/novu.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 4096 --port 4000
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.1"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="novu"
UPSTREAM_OWNER="novuhq"
UPSTREAM_REPO="novu"
NOVU_VERSION="3.20.0"       # GEPINNT (offizielle ghcr.io-Release-Images, kein Build im CT)
IMAGE_PREFIX="ghcr.io/novuhq/novu"
APP_DIR="/opt/novu"         # Projektverzeichnis im Container
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="novu"
CT_STORAGE="local-lvm"
CT_ROOTFS=20                # GB – Docker-Images (~2,5 GB) + Mongo-Daten
CT_CORES=4                  # API + Worker + Mongo profitieren von Kernen
CT_MEMORY=4096              # MB – Mongo 8 + 4 Node-Services
CT_SWAP=1024                # MB Puffer für Pull/Entpacken-Spitzen
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
UI_PORT=4000                # Novu-Dashboard (Web-UI) – Container-intern fix 4000
API_PORT=3000               # Novu-API – fix, Browser braucht sie (VITE_API_HOSTNAME)
WS_PORT=3002                # Novu-WebSockets – fix, Browser braucht sie
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NouvuCommunicationAI-Server/main/install/novu.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Docker-Compose), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Docker):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/novu-setup.log 2>/dev/null
            echo "--- docker ps (Projekt-Container) ---"
            timeout 15 docker ps -a --filter '"'"'label=com.docker.compose.project=novu'"'"' 2>/dev/null || true
            echo "--- docker compose logs (letzte 25 Zeilen, timeout 15s) ---"
            timeout 15 docker compose --project-directory /opt/novu logs --tail 25 2>/dev/null || true
            echo "--- journalctl -u novu -u docker ---"
            journalctl -u novu --no-pager 2>/dev/null | tail -n 10 || true
            journalctl -u docker --no-pager 2>/dev/null | tail -n 10 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

detect_host_arch() {
    # Template-Arch muss zur Host-CPU passen – ein Arch-Mismatch spawn-failt
    # (Live-Fund 2026-11-19, CT 211 ProxSmartHome: rV-Sortierung wählte das
    # NEUERE arm64-Template auf amd64-Host → "sync_wait: 34 ... Failed to
    # spawn"). NIEMALS über Architekturen hinweg sortieren!
    local m
    m=$(uname -m 2>/dev/null || echo "unknown")
    case "$m" in
        x86_64)        echo "amd64" ;;
        aarch64|armv8*) echo "arm64" ;;
        *) die "Unbekannte Host-Architektur '$m' – passendes Debian-Template nicht bestimmbar." ;;
    esac
}

find_ct_id_by_hostname() {
    # Schneller Weg: `pct list`, Name ist (meist) die LETZTE Spalte
    local id
    id=$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}' || true)
    if [[ -n "$id" ]]; then
        echo "$id"
        return 0
    fi
    # Fallback: Spaltenformat variiert zwischen PVE-Versionen → jede VMID
    # einzeln über `pct config` gegen den Hostname prüfen (Live-Fund 2026-11-19:
    # ProxSmartHome-Host fand den laufenden CT nicht über die Liste).
    local cand
    for cand in $(pct list 2>/dev/null | awk 'NR>1 {print $1}' || true); do
        if pct config "$cand" 2>/dev/null | grep -q "^hostname: ${CT_HOSTNAME}$"; then
            echo "$cand"
            return 0
        fi
    done
    return 0
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Docker-Images + ghcr-Registry brauchen Namensauflösung.
    # Live-Fall (2026-11-10, CT 200): DNS ist FLAKY – ein einzelner getent-Erfolg
    # reichte, Stunden später war wieder alles tot. Deshalb: 3 Erfolge in Folge
    # verlangen; eine einzige Störung in diesem Fenster → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts ghcr.io >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts ghcr.io >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    # pct status liefert "status: <wert>" – Prefix abschneiden für saubere Meldungen
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          UI_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --version)       NOVU_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Ports hart validieren – sie landen direkt in der Compose-Config im Container.
    if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
        die "Ungültiger UI-Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 4000)"
    fi
    if [[ "$UI_PORT" == "$API_PORT" || "$UI_PORT" == "$WS_PORT" ]]; then
        die "UI-Port ($UI_PORT) kollidiert mit API ($API_PORT) / WS ($WS_PORT) – API und WS sind fix (Browser braucht beide)."
    fi
    if ! [[ "$NOVU_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Ungültige Version: '$NOVU_VERSION' (erwartet z. B. 3.20.0)"
    fi
    NOVU_VERSION="${NOVU_VERSION#v}"
}

print_help() {
    cat <<'EOF'
📣 Novu – Proxmox-Installer (Open-Source-Notification-Infrastruktur, novuhq/novu)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NouvuCommunicationAI-Server/main/install/novu.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: novu)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 20 – Docker-Images + Mongo-Daten)
  --cores N        vCPUs (Default: 4)
  --memory MB      RAM (Default: 4096 – Mongo 8 + API/Worker/WS/Dashboard)
  --swap MB        Swap (Default: 1024)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                   Empfehlenswert: feste IP (oder DHCP-Reservierung), damit die
                   vom Browser genutzten API-/WS-URLs dauerhaft stimmen.
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      Web-UI-Port im Container (Default: 4000; API fix 3000, WS fix 3002)
  --version V      Novu-Version (Default: 3.20.0, gepinnt auf ghcr.io-Release-Images)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         Novu im bestehenden Container aktualisieren (Images neu ziehen)
  --uninstall      Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (Ports, Version, DNS) kommen als Umgebungsvariablen via
# `pct exec -- env …` in den Container. Das vermeidet die Escaping-Grube bei
# Compose-/Shell-Sonderzeichen komplett. Die Compose-Datei ist im Inner-Script
# EINGEBETTET (offizielles docker/community-Compose, adaptiert: container_name
# novu-*, Image-Pins via ${NOVU_VERSION} aus .env, Mongo/Redis ohne Ports).
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Novu In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_DIR, NOVU_VERSION, UI_PORT, API_PORT, WS_PORT,
#                    HOST_DNS, APPLY_UI_PORT
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo -e "✘ $1" >&2; }
ok(){ echo "✔ $1"; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${NOVU_VERSION:?NOVU_VERSION fehlt (env)}"
: "${UI_PORT:?UI_PORT fehlt (env)}"
: "${API_PORT:?API_PORT fehlt (env)}"
: "${WS_PORT:?WS_PORT fehlt (env)}"
: "${IMAGE_PREFIX:?IMAGE_PREFIX fehlt (env)}"

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability,
#  Live-Fund 2026-11-10: CT-DNS war nach Stunden wieder kaputt.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# Novu: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Docker installieren / prüfen ..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL --retry 3 "https://get.docker.com" -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1 || sh /tmp/get-docker.sh
else
    echo "    Docker bereits vorhanden: $(docker --version 2>/dev/null || echo 'unbekannt')"
fi
if ! docker compose version >/dev/null 2>&1; then
    die "docker compose (v2-Plugin) fehlt – get.docker.com hätte es installieren müssen.\n  Debug: docker --version; ls /usr/libexec/docker/cli-plugins/"
fi
# Docker-Daemon muss laufen (Debian startet ihn bei apt-Install meist schon)
systemctl enable docker >/dev/null 2>&1 || true
if ! docker info >/dev/null 2>&1; then
    systemctl start docker
    for _ in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then break; fi
        sleep 1
    done
    docker info >/dev/null 2>&1 || die "Docker-Daemon startet nicht.\n  Debug: journalctl -u docker -e"
fi

echo ">>> Verzeichnis anlegen + offizielles Novu-Compose schreiben ..."
mkdir -p "$APP_DIR"
cat > "${APP_DIR}/docker-compose.yml" <<'COMPOSEEOF'
name: novu

services:
  mongodb:
    image: "mongo:8.0.17"
    container_name: novu-mongodb
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_INITDB_ROOT_USERNAME}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_INITDB_ROOT_PASSWORD}
    volumes:
      - mongodb:/data/db
    healthcheck:
      test:
        [
          "CMD",
          "mongosh",
          "--quiet",
          "--username",
          "${MONGO_INITDB_ROOT_USERNAME}",
          "--password",
          "${MONGO_INITDB_ROOT_PASSWORD}",
          "--eval",
          "db.adminCommand('ping').ok",
        ]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 20s

  redis:
    image: "redis:alpine"
    container_name: novu-redis
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  api:
    image: "${IMAGE_PREFIX}/api:${NOVU_VERSION}"
    depends_on:
      mongodb:
        condition: service_healthy
      redis:
        condition: service_healthy
    container_name: novu-api
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    environment:
      NODE_ENV: ${NODE_ENV}
      API_ROOT_URL: ${API_ROOT_URL}
      PORT: ${API_PORT}
      FRONT_BASE_URL: ${FRONT_BASE_URL}
      MONGO_URL: ${MONGO_URL}
      MONGO_MIN_POOL_SIZE: ${MONGO_MIN_POOL_SIZE}
      MONGO_MAX_POOL_SIZE: ${MONGO_MAX_POOL_SIZE}
      REDIS_HOST: ${REDIS_HOST}
      REDIS_PORT: ${REDIS_PORT}
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      REDIS_DB_INDEX: 2
      REDIS_CACHE_SERVICE_HOST: ${REDIS_CACHE_SERVICE_HOST}
      REDIS_CACHE_SERVICE_PORT: ${REDIS_CACHE_SERVICE_PORT}
      S3_LOCAL_STACK: ${S3_LOCAL_STACK}
      S3_BUCKET_NAME: ${S3_BUCKET_NAME}
      S3_REGION: ${S3_REGION}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      JWT_SECRET: ${JWT_SECRET}
      STORE_ENCRYPTION_KEY: ${STORE_ENCRYPTION_KEY}
      NOVU_SECRET_KEY: ${NOVU_SECRET_KEY}
      NOVU_TOKEN_SIGNING_KEYS: ${NOVU_TOKEN_SIGNING_KEYS:-}
      SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME: ${SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME}
      DISABLE_USER_REGISTRATION: ${DISABLE_USER_REGISTRATION}
      SENTRY_DSN: ${SENTRY_DSN}
      NEW_RELIC_ENABLED: ${NEW_RELIC_ENABLED}
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME}
      NEW_RELIC_LICENSE_KEY: ${NEW_RELIC_LICENSE_KEY}
      API_CONTEXT_PATH: ${API_CONTEXT_PATH:-}
      MONGO_AUTO_CREATE_INDEXES: ${MONGO_AUTO_CREATE_INDEXES}
      IS_API_IDEMPOTENCY_ENABLED: ${IS_API_IDEMPOTENCY_ENABLED}
      IS_API_RATE_LIMITING_ENABLED: ${IS_API_RATE_LIMITING_ENABLED}
      IS_NEW_MESSAGES_API_RESPONSE_ENABLED: ${IS_NEW_MESSAGES_API_RESPONSE_ENABLED}
      IS_V2_ENABLED: ${IS_V2_ENABLED}
      IS_SELF_HOSTED: ${IS_SELF_HOSTED}
    ports:
      - "${API_PORT}:${API_PORT}"
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "wget --no-verbose --tries=1 --spider http://localhost:$${PORT}/v1/health-check || exit 1",
        ]
      interval: 20s
      timeout: 10s
      retries: 3
      start_period: 40s

  worker:
    image: "${IMAGE_PREFIX}/worker:${NOVU_VERSION}"
    depends_on:
      mongodb:
        condition: service_healthy
      redis:
        condition: service_healthy
    container_name: novu-worker
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    environment:
      NODE_ENV: ${NODE_ENV}
      PORT: ${WORKER_PORT:-3004}
      MONGO_URL: ${MONGO_URL}
      MONGO_MIN_POOL_SIZE: ${MONGO_MIN_POOL_SIZE}
      MONGO_MAX_POOL_SIZE: ${MONGO_MAX_POOL_SIZE}
      REDIS_HOST: ${REDIS_HOST}
      REDIS_PORT: ${REDIS_PORT}
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      REDIS_DB_INDEX: 2
      REDIS_CACHE_SERVICE_HOST: ${REDIS_CACHE_SERVICE_HOST}
      REDIS_CACHE_SERVICE_PORT: ${REDIS_CACHE_SERVICE_PORT}
      S3_LOCAL_STACK: ${S3_LOCAL_STACK}
      S3_BUCKET_NAME: ${S3_BUCKET_NAME}
      S3_REGION: ${S3_REGION}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      STORE_ENCRYPTION_KEY: ${STORE_ENCRYPTION_KEY}
      SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME: ${SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME}
      SENTRY_DSN: ${SENTRY_DSN}
      NEW_RELIC_ENABLED: ${NEW_RELIC_ENABLED}
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME}
      NEW_RELIC_LICENSE_KEY: ${NEW_RELIC_LICENSE_KEY}
      BROADCAST_QUEUE_CHUNK_SIZE: ${BROADCAST_QUEUE_CHUNK_SIZE}
      MULTICAST_QUEUE_CHUNK_SIZE: ${MULTICAST_QUEUE_CHUNK_SIZE}
      API_ROOT_URL: http://api:${API_PORT}
      IS_EMAIL_INLINE_CSS_DISABLED: ${IS_EMAIL_INLINE_CSS_DISABLED}
      IS_USE_MERGED_DIGEST_ID_ENABLED: ${IS_USE_MERGED_DIGEST_ID_ENABLED}
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "wget --no-verbose --tries=1 --spider http://localhost:$${PORT:-3004}/v1/health-check || exit 1",
        ]
      interval: 20s
      timeout: 10s
      retries: 3
      start_period: 20s

  ws:
    image: "${IMAGE_PREFIX}/ws:${NOVU_VERSION}"
    depends_on:
      mongodb:
        condition: service_healthy
      redis:
        condition: service_healthy
    container_name: novu-ws
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    environment:
      PORT: ${WS_PORT}
      NODE_ENV: ${NODE_ENV}
      MONGO_URL: ${MONGO_URL}
      MONGO_MIN_POOL_SIZE: ${MONGO_MIN_POOL_SIZE}
      MONGO_MAX_POOL_SIZE: ${MONGO_MAX_POOL_SIZE}
      REDIS_HOST: ${REDIS_HOST}
      REDIS_PORT: ${REDIS_PORT}
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      JWT_SECRET: ${JWT_SECRET}
      WS_CONTEXT_PATH: ${WS_CONTEXT_PATH:-}
      NEW_RELIC_ENABLED: ${NEW_RELIC_ENABLED}
      NEW_RELIC_APP_NAME: ${NEW_RELIC_APP_NAME}
      NEW_RELIC_LICENSE_KEY: ${NEW_RELIC_LICENSE_KEY}
    ports:
      - "${WS_PORT}:${WS_PORT}"
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "wget --no-verbose --tries=1 --spider http://localhost:$${PORT}/v1/health-check || exit 1",
        ]
      interval: 20s
      timeout: 10s
      retries: 3
      start_period: 40s

  dashboard:
    image: "${IMAGE_PREFIX}/dashboard:${NOVU_VERSION}"
    depends_on:
      api:
        condition: service_healthy
      worker:
        condition: service_healthy
    container_name: novu-dashboard
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    environment:
      VITE_API_HOSTNAME: ${VITE_API_HOSTNAME}
      VITE_WEBSOCKET_HOSTNAME: ${VITE_WEBSOCKET_HOSTNAME}
    ports:
      - "${UI_PORT}:4000"
    healthcheck:
      test:
        [
          "CMD-SHELL",
          'node -e "const http = require(''http''); const req = http.get({hostname: ''localhost'', port: 4000, path: ''/'', timeout: 5000}, (res) => { process.exit(res.statusCode === 200 ? 0 : 1); }); req.on(''error'', () => process.exit(1)); req.on(''timeout'', () => { req.destroy(); process.exit(1); });"',
        ]
      interval: 20s
      timeout: 10s
      retries: 3
      start_period: 20s

volumes:
  mongodb: ~
COMPOSEEOF

# ── .env: Secrets idempotent erzeugen (bestehende bleiben erhalten) ─────────
generate_secret() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$1"; return 0; fi
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}
dotenv_get() {
    # Wert eines Keys aus .env lesen (leer, wenn nicht vorhanden)
    local key=$1 line
    [[ -f .env ]] || { return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < .env
    return 0
}
dotenv_set() {
    # Key setzen/ersetzen; fehlende .env wird erzeugt
    local key=$1 value=$2 tmp=".env.tmp.$$" line updated=false
    if [[ -f .env ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "$key"=*) printf '%s=%s\n' "$key" "$value"; updated=true ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < .env > "$tmp"
        if [[ "$updated" != "true" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$tmp"
    fi
    mv -f "$tmp" .env
}

cd "$APP_DIR"

echo ">>> .env erzeugen/prüfen (Secrets bleiben bei Update erhalten) ..."
# Novu-Version (gepinnt) – wird bei JEDEM Lauf auf den Installer-Pin gesetzt,
# damit ein --update die Version sauber nachzieht.
dotenv_set NOVU_VERSION "$NOVU_VERSION"
if [[ -z "$(dotenv_get JWT_SECRET)" ]]; then
    dotenv_set JWT_SECRET "$(generate_secret 32)"
    echo "    JWT_SECRET erzeugt"
else
    echo "    JWT_SECRET vorhanden"
fi
# Muss EXAKT 32 Zeichen sein (AES-256-Key) – openssl rand -hex 16.
if [[ -z "$(dotenv_get STORE_ENCRYPTION_KEY)" ]]; then
    dotenv_set STORE_ENCRYPTION_KEY "$(generate_secret 16)"
    echo "    STORE_ENCRYPTION_KEY erzeugt"
else
    echo "    STORE_ENCRYPTION_KEY vorhanden"
fi
if [[ -z "$(dotenv_get NOVU_SECRET_KEY)" ]]; then
    dotenv_set NOVU_SECRET_KEY "$(generate_secret 32)"
    echo "    NOVU_SECRET_KEY erzeugt"
else
    echo "    NOVU_SECRET_KEY vorhanden"
fi
if [[ -z "$(dotenv_get MONGO_INITDB_ROOT_PASSWORD)" ]]; then
    dotenv_set MONGO_INITDB_ROOT_PASSWORD "$(generate_secret 16)"
    echo "    MONGO_INITDB_ROOT_PASSWORD erzeugt"
else
    echo "    MONGO_INITDB_ROOT_PASSWORD vorhanden"
fi
if [[ -z "$(dotenv_get MONGO_INITDB_ROOT_USERNAME)" ]]; then
    dotenv_set MONGO_INITDB_ROOT_USERNAME "root"
fi
# Mongo-URL (Enthält Zugangsdaten – nur setzen, wenn noch nicht vorhanden)
if [[ -z "$(dotenv_get MONGO_URL)" ]]; then
    dotenv_set MONGO_URL "mongodb://$(dotenv_get MONGO_INITDB_ROOT_USERNAME):$(dotenv_get MONGO_INITDB_ROOT_PASSWORD)@mongodb:27017/novu-db?authSource=admin"
    echo "    MONGO_URL erzeugt"
fi
# Nicht-geheime Werte (bei Update nur setzen, wenn noch nicht vorhanden –
# Nutzer-Änderungen in der .env bleiben damit erhalten):
[[ -n "$(dotenv_get NODE_ENV)" ]]                            || dotenv_set NODE_ENV "local"
[[ -n "$(dotenv_get MONGO_MIN_POOL_SIZE)" ]]                 || dotenv_set MONGO_MIN_POOL_SIZE "5"
[[ -n "$(dotenv_get MONGO_MAX_POOL_SIZE)" ]]                 || dotenv_set MONGO_MAX_POOL_SIZE "10"
[[ -n "$(dotenv_get MONGO_AUTO_CREATE_INDEXES)" ]]           || dotenv_set MONGO_AUTO_CREATE_INDEXES "true"
[[ -n "$(dotenv_get REDIS_HOST)" ]]                          || dotenv_set REDIS_HOST "redis"
[[ -n "$(dotenv_get REDIS_PORT)" ]]                          || dotenv_set REDIS_PORT "6379"
[[ -n "$(dotenv_get REDIS_CACHE_SERVICE_PORT)" ]]            || dotenv_set REDIS_CACHE_SERVICE_PORT "6379"
[[ -n "$(dotenv_get REDIS_SKIP_VERSION_CHECK)" ]]            || dotenv_set REDIS_SKIP_VERSION_CHECK "false"
[[ -n "$(dotenv_get S3_BUCKET_NAME)" ]]                      || dotenv_set S3_BUCKET_NAME "novu-local"
[[ -n "$(dotenv_get S3_REGION)" ]]                           || dotenv_set S3_REGION "us-east-1"
[[ -n "$(dotenv_get AWS_ACCESS_KEY_ID)" ]]                   || dotenv_set AWS_ACCESS_KEY_ID "test"
[[ -n "$(dotenv_get AWS_SECRET_ACCESS_KEY)" ]]               || dotenv_set AWS_SECRET_ACCESS_KEY "test"
[[ -n "$(dotenv_get API_PORT)" ]]                            || dotenv_set API_PORT "$API_PORT"
[[ -n "$(dotenv_get WS_PORT)" ]]                             || dotenv_set WS_PORT "$WS_PORT"
[[ -n "$(dotenv_get WORKER_PORT)" ]]                         || dotenv_set WORKER_PORT "3004"
[[ -n "$(dotenv_get SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME)" ]] || dotenv_set SUBSCRIBER_WIDGET_JWT_EXPIRATION_TIME "15d"
[[ -n "$(dotenv_get NOVU_TOKEN_SIGNING_KEYS)" ]]             || dotenv_set NOVU_TOKEN_SIGNING_KEYS ""
[[ -n "$(dotenv_get DISABLE_USER_REGISTRATION)" ]]           || dotenv_set DISABLE_USER_REGISTRATION "false"
[[ -n "$(dotenv_get IS_API_IDEMPOTENCY_ENABLED)" ]]          || dotenv_set IS_API_IDEMPOTENCY_ENABLED "false"
[[ -n "$(dotenv_get IS_API_RATE_LIMITING_ENABLED)" ]]        || dotenv_set IS_API_RATE_LIMITING_ENABLED "false"
[[ -n "$(dotenv_get IS_NEW_MESSAGES_API_RESPONSE_ENABLED)" ]] || dotenv_set IS_NEW_MESSAGES_API_RESPONSE_ENABLED "true"
[[ -n "$(dotenv_get IS_V2_ENABLED)" ]]                       || dotenv_set IS_V2_ENABLED "true"
[[ -n "$(dotenv_get IS_SELF_HOSTED)" ]]                      || dotenv_set IS_SELF_HOSTED "true"
[[ -n "$(dotenv_get IS_EMAIL_INLINE_CSS_DISABLED)" ]]        || dotenv_set IS_EMAIL_INLINE_CSS_DISABLED "false"
[[ -n "$(dotenv_get IS_USE_MERGED_DIGEST_ID_ENABLED)" ]]     || dotenv_set IS_USE_MERGED_DIGEST_ID_ENABLED "false"
[[ -n "$(dotenv_get SENTRY_DSN)" ]]                          || dotenv_set SENTRY_DSN ""
[[ -n "$(dotenv_get NEW_RELIC_ENABLED)" ]]                   || dotenv_set NEW_RELIC_ENABLED "false"
[[ -n "$(dotenv_get NEW_RELIC_APP_NAME)" ]]                  || dotenv_set NEW_RELIC_APP_NAME ""
[[ -n "$(dotenv_get NEW_RELIC_LICENSE_KEY)" ]]               || dotenv_set NEW_RELIC_LICENSE_KEY ""
[[ -n "$(dotenv_get BROADCAST_QUEUE_CHUNK_SIZE)" ]]          || dotenv_set BROADCAST_QUEUE_CHUNK_SIZE "100"
[[ -n "$(dotenv_get MULTICAST_QUEUE_CHUNK_SIZE)" ]]          || dotenv_set MULTICAST_QUEUE_CHUNK_SIZE "100"
if [[ "${APPLY_UI_PORT:-0}" == "1" ]]; then
    dotenv_set UI_PORT "$UI_PORT"
else
    [[ -n "$(dotenv_get UI_PORT)" ]] || dotenv_set UI_PORT "$UI_PORT"
fi
chmod 600 .env

echo ">>> IP-URL-Sync-Script schreiben (passt .env bei IP-Wechsel an) ..."
cat > "${APP_DIR}/sync-env-urls.sh" <<SYNCEOF
#!/usr/bin/env bash
# Synchronisiert die IP-abhängigen Einträge in .env mit der aktuellen CT-IP.
# Läuft als ExecStartPre vor jedem Novu-Start – DHCP-IP-Hüpfer brechen damit
# die vom Browser genutzten API-/WS-URLs nicht. Fehlende Keys werden
# ERGÄNZT (Frisch-Install ohne IP-Werte wird damit automatisch vervollständigt).
set -euo pipefail
SELF_DIR=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
cd "\$SELF_DIR"
set_key() { # KEY VALUE – ersetzen oder anhängen (idempotent)
    if /bin/grep -q "^\$1=" .env; then
        /bin/sed -i "s|^\$1=.*|\$1=\$2|" .env
    else
        printf '%s=%s\n' "\$1" "\$2" >> .env
    fi
}
IP=\$(ip -4 addr show eth0 scope global 2>/dev/null | awk '/inet /{print \$2; exit}' | cut -d/ -f1 || true)
[[ -n "\$IP" ]] || { echo "novu-sync: keine globale IPv4 an eth0 – .env bleibt unverändert"; exit 0; }
WANT="http://\${IP}"
CURRENT=\$(sed -n 's/^HOST_NAME=//p' .env 2>/dev/null | head -1 || true)
if [[ "\$CURRENT" != "\$WANT" ]]; then
    echo "novu-sync: CT-IP geändert (\${CURRENT:-unbekannt} → \${IP}) – aktualisiere .env"
else
    echo "novu-sync: CT-IP unverändert (\${IP})"
fi
set_key HOST_NAME "\$WANT"
set_key VITE_API_HOSTNAME "http://\${IP}:${API_PORT}"
set_key VITE_WEBSOCKET_HOSTNAME "http://\${IP}:${WS_PORT}"
set_key API_ROOT_URL "http://\${IP}:${API_PORT}"
set_key FRONT_BASE_URL "http://\${IP}:${UI_PORT}"
set_key S3_LOCAL_STACK "http://\${IP}:4566"
SYNCEOF
chmod +x "${APP_DIR}/sync-env-urls.sh"

echo ">>> systemd-Unit 'novu' schreiben (detached Bootstrap) ..."
cat > /etc/systemd/system/novu.service <<UNITEOF
[Unit]
Description=Novu Notification-Infrastruktur (docker compose)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
# DETACHED Bootstrap (oneshot): startet/synchronisiert den Stack einmalig
# (idempotent, wendet .env-Änderungen an). Die DAUERHAFTE Ausfallsicherung
# übernehmen die Container selbst (restart: unless-stopped in der
# Compose-Datei). Ein ATTACHED compose up als Service-Main-Prozess würde
# das Compose-Projekt-Lock DAUERHAFT halten und alle weiteren
# docker-compose-Aufrufe (Verifikation/Status/Logs) endlos blockieren
# (Live-Fund 2026-11-18: Installer hing in der Verifikation am Lock).
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/novu
ExecStartPre=/opt/novu/sync-env-urls.sh
ExecStart=/usr/bin/docker compose --project-directory /opt/novu up -d --pull=missing
ExecStop=/usr/bin/docker compose --project-directory /opt/novu stop
TimeoutStartSec=900
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable novu >/dev/null 2>&1 || true

echo ">>> IP-abhängige .env-Einträge synchronisieren ..."
"${APP_DIR}/sync-env-urls.sh"

echo ">>> Compose-Konfiguration validieren ..."
docker compose config -q || die "docker compose config meldet Fehler (Compose-Datei/.env prüfen).\n  Debug: cd $APP_DIR && docker compose config"

echo ">>> Docker-Images ziehen (api, worker, ws, dashboard, mongo, redis) ..."
systemctl stop novu >/dev/null 2>&1 || true
docker compose pull

echo ">>> Novu-Stack starten (docker compose up -d) ..."
docker compose up -d

echo ">>> systemd-Service starten (übernimmt den laufenden Stack) ..."
systemctl start novu

echo ">>> Warte auf API-Gesundheit (http://127.0.0.1:${API_PORT}/v1/health-check) ..."
API_OK=""
for _ in $(seq 1 60); do
    code=$(curl -sL -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${API_PORT}/v1/health-check" || true)
    if [[ "$code" == "200" ]]; then
        API_OK=1
        break
    fi
    sleep 5
done
if [[ -z "$API_OK" ]]; then
    die "API antwortet nicht mit 200 auf /v1/health-check (letzter Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps && docker compose logs --tail 50 api"
fi
ok "API gesund (HTTP 200)"

echo ">>> Warte auf Web-Dashboard (http://127.0.0.1:${UI_PORT}/) ..."
UI_OK=""
for _ in $(seq 1 40); do
    code=$(curl -sL -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${UI_PORT}/" || true)
    if [[ "$code" == "200" ]]; then
        UI_OK=1
        break
    fi
    sleep 3
done
if [[ -z "$UI_OK" ]]; then
    die "Web-Dashboard antwortet nicht mit 200 (letzter Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps && docker compose logs --tail 50 dashboard"
fi
ok "Web-Dashboard antwortet (HTTP 200)"

echo ">>> Warte auf WebSocket-Service (http://127.0.0.1:${WS_PORT}/v1/health-check) ..."
WS_OK=""
for _ in $(seq 1 30); do
    code=$(curl -sL -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${WS_PORT}/v1/health-check" || true)
    if [[ "$code" == "200" ]]; then
        WS_OK=1
        break
    fi
    sleep 3
done
if [[ -z "$WS_OK" ]]; then
    die "WebSocket-Service antwortet nicht mit 200 (letzter Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps && docker compose logs --tail 50 ws"
fi
ok "WebSocket-Service gesund (HTTP 200)"

echo ">>> Aufräumen ..."
rm -f /tmp/get-docker.sh

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Novu im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (Grube 14).
    # APPLY_UI_PORT: bei Installation immer setzen; bei Update nur, wenn --port
    # explizit vom Default abweicht (Nutzer-Änderungen in .env bleiben erhalten).
    local apply_ui_port=0
    if [[ "$UI_PORT" != "4000" ]]; then
        apply_ui_port=1
    fi
    pct exec "$ct_id" -- env APP_DIR="$APP_DIR" NOVU_VERSION="$NOVU_VERSION" \
        UI_PORT="$UI_PORT" API_PORT="$API_PORT" WS_PORT="$WS_PORT" \
        HOST_DNS="${HOST_DNS:-1.1.1.1}" IMAGE_PREFIX="$IMAGE_PREFIX" APPLY_UI_PORT="$apply_ui_port" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/novu-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet novu 2>/dev/null; then
            ok "Service novu läuft (systemctl is-active)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service novu läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u novu -e && pct exec $ct_id -- systemctl status novu"
        fi
        sleep 1
    done

    # Alle 6 Compose-Services oben? – ACHTUNG: bewusst `docker ps` mit
    # Projekt-Label statt `docker compose ps`: compose-Befehle blockieren
    # gegenseitig über das Projekt-Lock; docker ps ist lockfrei.
    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker ps --filter 'label=com.docker.compose.project=novu' --format '{{.Names}} {{.State}}' 2>/dev/null || true)
    local missing=""
    for svc in novu-mongodb novu-redis novu-api novu-worker novu-ws novu-dashboard; do
        if ! grep -q "$svc" <<<"$ps_out"; then
            missing+="${svc} "
        fi
    done
    if [[ -n "$missing" ]]; then
        die "Compose-Services fehlen oder sind nicht hochgekommen: ${missing}\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/novu ps -a\n  Logs:  pct exec $ct_id -- docker compose --project-directory /opt/novu logs --tail 50"
    fi
    ok "Alle Compose-Services laufen (mongodb, redis, api, worker, ws, dashboard)"

    # Health-Checks (Grube: curl -w gibt bei Verbindungsfehler bereits
    # 000 aus – NIE zusätzlich || echo 000 anhängen, sonst falsch-positiv.)
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -sL -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${API_PORT}/v1/health-check" || true)
        if [[ "$code" == "200" ]]; then
            ok "API gesund (HTTP 200 auf Port ${API_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "API antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/novu logs --tail 50 api"
        fi
        sleep 2
    done

    tries=0
    code=""
    while true; do
        code=$(pct exec "$ct_id" -- curl -sL -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-Dashboard antwortet (HTTP 200 auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-Dashboard antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/novu logs --tail 50 dashboard"
        fi
        sleep 2
    done

    tries=0
    code=""
    while true; do
        code=$(pct exec "$ct_id" -- curl -sL -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${WS_PORT}/v1/health-check" || true)
        if [[ "$code" == "200" ]]; then
            ok "WebSocket-Service gesund (HTTP 200 auf Port ${WS_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "WebSocket-Service antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory /opt/novu logs --tail 50 ws"
        fi
        sleep 2
    done

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${UI_PORT}/" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${UI_PORT} (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "📣  Novu ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-Dashboard:  http://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  🔌 API:           http://${ct_ip}:${API_PORT}  (benötigt der Browser im Hintergrund)${NC}"
    echo -e "  ${GREEN}  🔔 WebSockets:    http://${ct_ip}:${WS_PORT}  (benötigt der Browser im Hintergrund)${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:      pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:       ${CT_PASSWORD}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer:     v${INSTALLER_VERSION} (Novu ${NOVU_VERSION}, gepinnt – upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO})${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte:${NC}"
    echo "  1. http://${ct_ip}:${UI_PORT} öffnen und den ersten Account anlegen"
    echo "     (Signup ist offen – danach schließen: in ${APP_DIR}/.env"
    echo "      DISABLE_USER_REGISTRATION=true setzen und --update ausführen)"
    echo "  2. Im Dashboard einen Workflow bauen (Trigger → E-Mail/Chat/SMS/…)"
    echo "     und den Environment-API-Key (Settings) für deine Apps kopieren"
    echo "  3. Senden aus deinen Anwendungen: POST http://${ct_ip}:${API_PORT}/v1/events/trigger"
    echo "     mit dem API-Key (Novu-SDKs: @novu/node, @novu/api, …)"
    echo ""
    echo -e "  ${CYAN}Lokal & privat:${NC}"
    echo "  Läuft komplett im CT – keine Cloud-Pflicht. Kanäle wie E-Mail/SMS"
    echo "  brauchen Provider-Credentials (SMTP, Resend, Twilio, …), die du in"
    echo "  der UI hinterlegst – In-App-Benachrichtigungen gehen ohne Provider."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Stack-Logs: pct exec ${CT_ID} -- docker compose --project-directory /opt/novu logs -f"
    echo ""
    warn "Daten (MongoDB-Volume) liegen in Docker-Volumes im CT – ein --update"
    warn "erhält sie, pct destroy löscht sie. Für Backups: pct backup / vzdump."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – bei IP-Wechsel sync'd das System die .env beim Boot selbst,"
        warn "trotzdem empfohlen: DHCP-Reservierung im Router (oder --ip beim Install)."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "📣 Installiere Novu (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION} (Novu ${NOVU_VERSION})"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen – ARCH-KORREKT (Host-CPU via uname -m).
    # ProxSmartHome hat beide Arch-Templates im Cache; reine Versions-Sortierung
    # (rV) nimmt das neuere arm64 auf einem amd64-Host → Spawn-Fail. Innerhalb
    # der passenden Architektur gilt: 13 vor 12 (rV), Fallback bleibt.
    header "🧱 Container-Template"
    local template="" CT_ARCH=""
    CT_ARCH=$(detect_host_arch)
    info "Host-Architektur: $CT_ARCH"
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o 'debian-1[23]-standard[^ ]*' \
               | grep -E "_${CT_ARCH}\.tar\.zst$" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-12/13-${CT_ARCH}-Template im Cache – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o 'debian-1[23]-standard[^ ]*' \
                   | grep -E "_${CT_ARCH}\.tar\.zst$" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard-Template für ${CT_ARCH} gefunden (pveam available leer?).\n  Prüfe: pveam available --section system | grep standard"
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="nv-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    # pct create --start 1 meldet Exit 0, AUCH wenn der Spawn fehlschlägt
    # (Live-Fund 2026-11-19, CT 211: "sync_wait: 34 ... Failed to spawn" im
    # pct-Output, dann 60 s sinnloser IP-Poll). Deshalb Status EXPLIZIT prüfen.
    sleep 2
    local cstate=""
    cstate=$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$cstate" != "running" ]]; then
        die "Container $CT_ID startet nicht (Status: ${cstate:-unbekannt} – pct create meldete trotzdem Exit 0).\n  Typische Ursache: Template-Architektur ≠ Host-CPU (Install-Suche ist jetzt arch-korrekt via uname -m).\n  Details im pct-Output oben (sync_wait/Failed to spawn) und in: grep -i 'lxc-start' /var/log/syslog | tail -20\n  Aufräumen: pct destroy $CT_ID --purge\n  Danach Installer erneut ausführen (bei bestehendem CT mit --force)."
    fi
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update Novu (Images neu ziehen – Novu ${NOVU_VERSION})"

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_ct_id_by_hostname || true)
    fi
    if [[ -z "$CT_ID" ]] || ! pct status "$CT_ID" &>/dev/null; then
        die "Kein Novu-Container gefunden (${CT_ID:+--id $CT_ID unbekannt; }Hostname-Suche '$CT_HOSTNAME' leer).\n  Erst installieren:  ${ONE_LINER}\n  CT-ID explizit angeben:  ${ONE_LINER} --update --id 204"
    fi
    local ct_id="$CT_ID"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Daten (MongoDB-Volume) blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere Novu"

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_ct_id_by_hostname || true)
    fi
    if [[ -z "$CT_ID" ]] || ! pct status "$CT_ID" &>/dev/null; then
        warn "Kein Novu-Container gefunden (${CT_ID:+--id $CT_ID unbekannt; }Hostname-Suche '$CT_HOSTNAME' leer) – nichts zu tun."
        return 0
    fi
    local ct_id="$CT_ID"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: Accounts, Workflows, Nachrichten, MongoDB."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status Novu"
    info "Installer-Version: v${INSTALLER_VERSION} (Novu-Pin: ${NOVU_VERSION})"

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_ct_id_by_hostname || true)
    fi
    if [[ -z "$CT_ID" ]] || ! pct status "$CT_ID" &>/dev/null; then
        warn "Kein Novu-Container gefunden (${CT_ID:+--id $CT_ID unbekannt; }Hostname-Suche '$CT_HOSTNAME' leer)."
        info "Installieren:  ${ONE_LINER}"
        info "CT-ID explizit:  ${ONE_LINER} --status --id 204"
        return 0
    fi
    local ct_id="$CT_ID"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Stack/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet novu 2>/dev/null; then
        ok "Service:   novu läuft (systemctl is-active)"
    else
        err "Service:   novu läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u novu -e"
    fi

    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker ps --filter 'label=com.docker.compose.project=novu' --format '{{.Names}} {{.State}}' 2>/dev/null || true)
    if [[ -n "$ps_out" ]]; then
        info "Stack:     $(echo "$ps_out" | tr '\n' ' ' | sed 's/ $//')"
    else
        warn "Stack:     keine Container mit Projekt-Label novu (Stack noch nie gestartet?)"
    fi

    local version reg ip code=""
    version=$(pct exec "$ct_id" -- sed -n 's/^NOVU_VERSION=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    if [[ -n "$version" ]]; then
        ok "Version:   Novu ${version}"
    else
        warn "Version:   unbekannt (${APP_DIR}/.env ohne NOVU_VERSION)"
    fi
    reg=$(pct exec "$ct_id" -- sed -n 's/^DISABLE_USER_REGISTRATION=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    if [[ "$reg" == "true" ]]; then
        ok "Signup:    geschlossen (DISABLE_USER_REGISTRATION=true)"
    else
        warn "Signup:    OFFEN (nach dem ersten Account schließen: DISABLE_USER_REGISTRATION=true in ${APP_DIR}/.env + --update)"
    fi

    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${UI_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Dashboard: http://${ip}:${UI_PORT}  (HTTP 200)"
        else
            warn "Dashboard: HTTP-Code ${code:-unbekannt} von http://${ip}:${UI_PORT}"
        fi
        code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${API_PORT}/v1/health-check" || true)
        if [[ "$code" == "200" ]]; then
            ok "API:       http://${ip}:${API_PORT}  (HTTP 200)"
        else
            warn "API:       HTTP-Code ${code:-unbekannt} von http://${ip}:${API_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi

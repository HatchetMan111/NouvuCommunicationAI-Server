# 📣 Novu – Proxmox LXC Installer

Ein-Klick-Installer für [Novu](https://github.com/novuhq/novu) (Open-Source-Notification-Infrastruktur) als LXC-Container auf Proxmox VE – nach dem Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

Novu macht Multi-Channel-Notifications (In-App, E-Mail, SMS, Push, Chat) über eine einzige API: Workflows im Dashboard bauen, Environment-API-Key in die eigene App, `POST /v1/events/trigger` senden. Läuft komplett lokal – keine Cloud-Pflicht, Telemetrie (Sentry/New Relic) default AUS.

## 🚀 Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Novu-Proxmox/main/install/novu.sh)"
```

**Mit Optionen** (hinter dem schließenden Anführungszeichen anhängen):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Novu-Proxmox/main/install/novu.sh)" --id 210 --port 4000
```

Das Script:

- erzeugt einen **unprivilegierten LXC** (Debian 13, `nesting=1`, `onboot=1`, Name `novu`, nächste freie ID ab 200)
- Defaults: **4 vCPU / 4096 MB RAM / 1024 MB Swap / 20 GB Disk** (MongoDB 8 + 4 Node-Services – weniger RAM führt zu OOM beim ersten Start)
- installiert Docker CE + den Novu-Stack (offizielle `ghcr.io/novuhq/novu`-Images, **gepinnt auf 3.20.0**)
- erzeugt Secrets (`JWT_SECRET`, `STORE_ENCRYPTION_KEY`, `NOVU_SECRET_KEY`, Mongo-Passwort) per `openssl rand -hex` im Container, `.env` mit `chmod 600`
- richtet den **systemd-Service `novu`** ein (detached `compose up`, `Restart` über `restart: unless-stopped` der Container) → **Reboot-sicher**
- verifiziert sich selbst (Service aktiv, alle 6 Container oben, API/WS/Dashboard HTTP 200) und gibt die finale URL aus

## 🌐 Ports

| Port | Dienst | Erreichbarkeit |
|---|---|---|
| **4000** | Dashboard (Web-UI) | Browser – Haupt-UI (`--port` ändert diesen) |
| **3000** | API | Browser + deine Apps (`VITE_API_HOSTNAME`) – fix |
| **3002** | WebSockets | Browser (Live-Updates im Dashboard) – fix |
| intern | worker, redis, mongo | **nicht exponiert** (nur Docker-Netz) |

Die URL fürs Dashboard lautet: `http://<LXC-IP>:4000` (IP wird am Ende der Installation angezeigt).

> Die API/WS-Ports müssen vom Browser aus erreichbar sein (das Dashboard baut die URLs aus `HOST_NAME` = CT-IP). Bei IP-Wechsel synchronisiert ein Script (`sync-env-urls.sh`, läuft als `ExecStartPre`) die `.env` automatisch neu.

## 🔧 Verwaltung

```bash
# Status (Service, Stack-Container, Version, Signup-Status, URLs)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Novu-Proxmox/main/install/novu.sh)" --status

# Update (Images neu ziehen, Secrets/Daten bleiben erhalten)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Novu-Proxmox/main/install/novu.sh)" --update

# Deinstallieren (Container + ALLE Daten löschen; --yes überspringt Rückfrage)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Novu-Proxmox/main/install/novu.sh)" --uninstall --yes

# Fehlerdiagnose: voller bash -x-Trace
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Novu-Proxmox/main/install/novu.sh)" --debug
```

Weitere Optionen: `--id`, `--hostname`, `--storage`, `--rootfs`, `--cores`, `--memory`, `--swap`, `--bridge`, `--ip`, `--gateway`, `--password`, `--sshkey`, `--port`, `--version`, `--force` – siehe `--help`.

## 📣 Erste Schritte in Novu

1. **Account anlegen:** `http://<LXC-IP>:4000` öffnen, ersten Account registrieren.
   Signup danach schließen: in `/opt/novu/.env` `DISABLE_USER_REGISTRATION=true` setzen und `--update` ausführen (Status zeigt „Signup: OFFEN" solange offen).
2. **Workflow bauen:** Dashboard → Workflows → neuen Workflow anlegen (Trigger → E-Mail/Chat/SMS/Push-Schritte).
3. **Aus der eigenen App senden:** Settings → API-Key kopieren, dann:
   ```bash
   curl -X POST http://<LXC-IP>:3000/v1/events/trigger \
     -H "Authorization: ApiKey <DEIN_API_KEY>" \
     -H "Content-Type: application/json" \
     -d '{"name":"mein-workflow","to":{"subscriberId":"user-1"},"payload":{"firstName":"Phil"}}'
   ```
   SDKs: `@novu/node` (Node), `@novu/api` (REST), Community-SDKs für Python/Go/PHP.
4. **Kanäle:** In-App-Benachrichtigungen gehen ohne Provider. E-Mail/SMS/Push brauchen Provider-Credentials (SMTP, Resend, Twilio, …) – in der UI unter Integrationen hinterlegen.

## 🗂️ Wo liegt was?

| Pfad (im CT) | Inhalt |
|---|---|
| `/opt/novu/docker-compose.yml` | Offizielles Community-Compose (adaptiert: `novu-*`-Container-Namen, Image-Pins) |
| `/opt/novu/.env` | Secrets + Konfiguration (chmod 600; IP-URLs sync't `sync-env-urls.sh`) |
| `/etc/systemd/system/novu.service` | systemd-Unit (detached Bootstrap, `onboot` macht den CT-Teil) |
| `/var/log/novu-setup.log` | Setup-Log des letzten Laufs |
| Docker-Volume `novu_mongodb` | Alle Daten (Accounts, Workflows, Nachrichten) |

Logs live: `pct exec <CT-ID> -- docker compose --project-directory /opt/novu logs -f`

## 🧪 Testen

```bash
bash harness/run.sh          # Mock-Harness (unshare + Fakebin), Exit 0 = grün
shellcheck install/novu.sh
```

## ⚠️ Hinweise

- **Novu-Version ist gepinnt** (`--version 3.20.0` Default). Ein `--update` setzt den Pin auf die im Installer hinterlegte Version und zieht die Images neu.
- Novu v3 = die aktuelle Hauptversion (Dashboard, API, WS, Worker). Die alte 0.x-Compose (`web` auf :4200) ist obsolet.
- Bei `docker compose`-Nutzwarnungen im ersten Start: Mongo braucht beim ersten Boot ~20–40 s (Index-Build), die Healthchecks der Compose-Datei handeln das.
- Lizenz Novu: MIT (Community) – siehe `LICENSE-MIT` im Upstream-Repo.

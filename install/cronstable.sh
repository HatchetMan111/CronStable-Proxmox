#!/usr/bin/env bash
#
# Cronstable Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Cronstable – Job-Scheduler mit Retries, Alerts, Run-History,
#           Workflows und Dashboard (Web + TUI + iOS)
# Upstream: https://github.com/ptweezy/cronstable (PyPI: cronstable)
# Stack:    Python (>=3.10) + venv + pip, ohne Docker, ohne Cloud.
#           Web-UI + REST auf :8080, bind 0.0.0.0 im Container.
# Laeuft:   vollstaendig lokal im LXC, keine externen Cloud-Dienste noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CronStable-Proxmox/main/install/cronstable.sh)"
#   CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CronStable-Proxmox/main/install/cronstable.sh)"
#   bash cronstable.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
# Hinweis: Unit + Config werden live aus diesem Repo geladen (SERVICE_URL,
# CONFIG_URL unten). Ohne Netz zum Repo greift der Inline-Fallback im Skript.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="cronstable"                              # Container-Hostname + Service-Name
APP_PORT="8080"                               # Cronstable Web-UI + REST API
UPSTREAM_REPO="https://github.com/ptweezy/cronstable"
INSTALLER_REPO="https://github.com/HatchetMan111/CronStable-Proxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/CronStable-Proxmox/main/systemd/cronstable.service"
CONFIG_URL="https://raw.githubusercontent.com/HatchetMan111/CronStable-Proxmox/main/config/cronstable.yaml"

DEFAULT_CORES="2"                             # vCPU (Scheduler + Web-UI + Workflows)
DEFAULT_RAM="2048"                            # RAM in MB
DEFAULT_SWAP="512"                            # Swap in MB
DEFAULT_DISK="8"                              # Disk in GB (State + History)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie
UNPRIVILEGED="1"                              # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                          # nesting fuer pip/venv Robustheit

APP_USER="cronstable"
APP_DIR="/opt/cronstable"
VENV_DIR="/opt/cronstable/.venv"
CONFIG_DIR="/etc/cronstable"
CONFIG_FILE="/etc/cronstable/cronstable.yaml"
STATE_DIR="/var/lib/cronstable"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=2048 DISK=8 ./cronstable.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash cronstable.sh [OPTIONEN]
  CT_ID=150 bash cronstable.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/../raw/main/install/cronstable.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer naechste freie ID, ausser --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfuegbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell pruefen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Cronstable im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Cronstable im Container (pip + venv, ohne Docker) ..."
# Hinweis: aeussere Single-Quotes – der Block laeuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping noetig).
pct exec "$CT_ID" -- bash -c '
# shellcheck disable=SC2034,SC2154
# SC2034: Pfad-Variablen unten sind Doku + Single-Source (Container-Block nutzt
# Literale, da aeussere Vars nicht per pct exec vererbt werden).
# SC2154: ec im trap-Handler ist Laufzeit, kein ungesetztes Literal.
set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 python3-venv python3-pip curl ca-certificates
  id cronstable >/dev/null 2>&1 || useradd -m -s /bin/bash cronstable
  # ACHTUNG: In diesem Block sind KEINE einfachen Anfuehrungszeichen erlaubt,
  # weder in Befehlen noch in Kommentaren – sie wuerden den aeusseren
  # bash -c Block der Host-Shell sprengen und den Rest still abschneiden.
  if [ ! -x /opt/cronstable/.venv/bin/python ]; then
    mkdir -p /opt/cronstable
    python3 -m venv /opt/cronstable/.venv
  fi
  /opt/cronstable/.venv/bin/pip install --upgrade pip
  /opt/cronstable/.venv/bin/pip install --upgrade cronstable
  mkdir -p /etc/cronstable /var/lib/cronstable
  chown -R cronstable:cronstable /opt/cronstable /var/lib/cronstable
'
# Hinweis: bewusst kein "| tail" hier – mit pipefail wuerde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# Host-seitiger Guard: bricht laut ab, falls das venv unvollstaendig ist.
pct exec "$CT_ID" -- test -x /opt/cronstable/.venv/bin/cronstable \
  || { msg_error "Installation unvollstaendig: /opt/cronstable/.venv/bin/cronstable fehlt im Container."; exit 1; }
msg_ok "Checkout ok (cronstable-Binary im venv vorhanden)."

# Config aus diesem Repo uebernehmen (faellt auf Inline-Config zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/cronstable/cronstable.yaml "$CONFIG_URL" 2>/dev/null; then
  msg_ok "cronstable.yaml aus Repo uebernommen."
else
  msg_warn "Config-URL nicht erreichbar – schreibe Inline-Config."
  pct push "$CT_ID" /dev/stdin /etc/cronstable/cronstable.yaml <<CONFIG
state:
  path: /var/lib/cronstable

jobs:
  - name: hello
    command: echo hello from cronstable
    schedule: "* * * * *"
    captureStdout: true

web:
  listen:
    - http://0.0.0.0:8080
CONFIG
fi
pct exec "$CT_ID" -- chown cronstable:cronstable /etc/cronstable/cronstable.yaml
pct exec "$CT_ID" -- chmod 640 /etc/cronstable/cronstable.yaml

# Config validieren (komplette Fehlermeldungskette bei Fehlern)
if ! pct exec "$CT_ID" -- /opt/cronstable/.venv/bin/cronstable --validate-config -c /etc/cronstable/cronstable.yaml; then
  msg_error "Config-Validierung fehlgeschlagen (--validate-config)."
  pct exec "$CT_ID" -- cat /etc/cronstable/cronstable.yaml || true
  exit 1
fi
msg_ok "Config validiert (--validate-config ok)."

# systemd-Unit aus diesem Repo uebernehmen (faellt auf Inline-Unit zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/cronstable.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "cronstable.service aus Repo uebernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/cronstable.service <<UNIT
[Unit]
Description=Cronstable – Job-Scheduler mit Web-Dashboard
Documentation=https://github.com/ptweezy/cronstable
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cronstable
Group=cronstable
WorkingDirectory=/var/lib/cronstable
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/cronstable/.venv/bin/cronstable -c /etc/cronstable/cronstable.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now cronstable
msg_ok "systemd-Service cronstable aktiviert (enable --now)."

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active cronstable || { msg_error "systemd-Service cronstable ist nicht active."; pct exec "$CT_ID" -- systemctl status cronstable --no-pager || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active cronstable = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."; pct exec "$CT_ID" -- systemctl status cronstable --no-pager || true; pct exec "$CT_ID" -- journalctl -u cronstable --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Cronstable – Job-Scheduler + Dashboard"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  API          : http://${CT_IP}:${APP_PORT}/api (siehe Upstream-Doku)"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, un Veraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status cronstable  (im Container via: pct enter $CT_ID)"
echo "  Config       : /etc/cronstable/cronstable.yaml (validiert mit --validate-config)"
echo "  Update       : Skript erneut laufen lassen (idempotent, pip upgrade + restart)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"

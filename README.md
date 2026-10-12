# Cronstable auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/ptweezy/cronstable`
> (PyPI: `cronstable` – Job-Scheduler mit Retries, Alerts, Run-History, Workflows, Dashboard)
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit + Starter-Config.
> Die App läuft nativ (Python + venv + pip, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CronStable-Proxmox/main/install/cronstable.sh)"
```

Installer-Repo: `https://github.com/HatchetMan111/CronStable-Proxmox`
(Unit + Config lädt das Script von dort; ohne Netz greift der Inline-Fallback).

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CronStable-Proxmox/main/install/cronstable.sh)"
bash cronstable.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash cronstable.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/cronstable-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `cronstable` |
| Zweck | Job-Scheduler: Cron-Jobs mit Retries/Backoff, Alerts, Run-History, DAG-Workflows, Web-Dashboard |
| Tech-Stack | Python ≥3.10 + venv `/opt/cronstable/.venv` + `pip install cronstable`, Config `/etc/cronstable/cronstable.yaml` |
| GitHub-Repo (Upstream) | `https://github.com/ptweezy/cronstable` |
| Web UI | `http://<LXC-IP>:8080` (bind `0.0.0.0:8080`), Health = `GET /` |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `cronstable` (`onboot: 1`, unprivilegiert),
3. installiert im Container Python+venv, legt User `cronstable` an,
   installiert `pip install cronstable` nach `/opt/cronstable/.venv`,
   legt `/etc/cronstable/cronstable.yaml` (Starter-Job `hello` + `web.listen 0.0.0.0:8080`)
   und `/var/lib/cronstable` (State) an, validiert mit `--validate-config`,
   schreibt `cronstable.service`, `systemctl enable --now cronstable`,
4. verifiziert `systemctl is-active cronstable` + HTTP auf `localhost:8080/`
   und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active cronstable = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8080/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Cronstable – Job-Scheduler + Dashboard
  Container    : CT 100 (Hostname: cronstable, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Web UI       : http://192.168.1.100:8080
  ...
  Log          : /tmp/cronstable-install-2026-....log
══════════════════════════════════════════════════════════
```

Eigene Jobs: `/etc/cronstable/cronstable.yaml` im Container editieren
(`pct enter <CT>`), dann `systemctl restart cronstable`.
Vollständige Syntax (Retries, DAGs, Alerts, TLS): Upstream-Wiki
`https://github.com/ptweezy/cronstable/wiki`.

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active cronstable
curl -fs http://<LXC-IP>:8080/ >/dev/null && echo WEB_UI_OK
```

Erwartet: `active` + `WEB_UI_OK`. Beleg: `journalctl -u cronstable -n 50`
im Container zeigt Neustart + hello-Job-Läufe nach Reboot.

## Update / Deinstall

```bash
bash cronstable.sh --ctid 100            # Update: idempotent (pip upgrade + restart)
pct stop 100 && pct destroy 100          # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/cronstable-install-*.log`.
- `bash cronstable.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status cronstable --no-pager`, `journalctl -u cronstable -n 100`,
  Config prüfen: `/opt/cronstable/.venv/bin/cronstable --validate-config -c /etc/cronstable/cronstable.yaml`.

## Dateien

- `install/cronstable.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/cronstable.service` – Unit (`After=network-online.target`, `Restart=always`, User `cronstable`).
- `config/cronstable.yaml` – Starter-Config (`hello`-Job + `0.0.0.0:8080` + State-Pfad).

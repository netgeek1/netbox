# NetBox Auto-Deploy & Network Discovery Suite

A single Bash script that deploys NetBox, discovers a network using many
protocols, and keeps NetBox populated with devices, VMs, IPs, MACs, interfaces,
clusters, and cabling — automatically and idempotently.

> **Version:** 2.5.51 · **Platform:** Ubuntu 24.04 · **License:** see [License](#license)
>
> The authoritative, per-version history lives in CHANGELOG.
> This README describes current behavior.

---

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The menu](#the-menu)
- [Credentials](#credentials)
- [Testing credentials](#testing-credentials)
- [Configuration](#configuration)
- [How it works (architecture)](#how-it-works-architecture)
- [What gets created in NetBox](#what-gets-created-in-netbox)
- [Non-interactive / scheduled scans](#non-interactive--scheduled-scans)
- [Auto-start on boot](#auto-start-on-boot)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [File & directory layout](#file--directory-layout)
- [Security notes](#security-notes)
- [License](#license)

---

## What it does

1. **Deploys NetBox** — installs Docker + Docker Compose, brings up the
   NetBox Docker stack, creates an admin account and API token, and writes its
   configuration.
2. **Discovers the network** — sweeps subnets with ARP, fping, Nmap/RustScan,
   SNMP (v1/v2c/v3), SSH, WinRM, mDNS, NetBIOS, DNS, HTTP banners, and LLDP/CDP.
3. **Reconciles and syncs** — folds duplicates across hosts, then writes a single
   coordinated model to NetBox: devices, virtual machines, clusters, IP
   addresses, MAC addresses, interfaces, and cables. Re-running is safe.
4. **Imports virtualization** — queries Windows **Hyper-V** hosts over WinRM and
   imports clusters, VMs, vNICs, virtual disks, and per-host hardware inventory;
   can also deploy NetBox Agent to discovered Linux hosts.

---

## Requirements

- **OS:** Ubuntu 24.04 (uses `apt` and systemd).
- **Privileges:** run with `sudo`/root — it installs packages, manages Docker,
  and writes a systemd unit.
- **Network:** outbound internet for Docker images and `apt`, and reachability
  to the targets you want to scan.
- **Resources:** enough for the NetBox Docker stack (NetBox + PostgreSQL + Redis
  + workers). Plan for a few GB of RAM and several GB of disk; more is better for
  larger inventories.
- **Tooling:** the script installs everything it needs (Docker, Nmap, Masscan,
  ARP-Scan, fping, net-snmp, SSH tools, jq, plus Python libraries such as
  pynetbox, netmiko, napalm, pysnmp, paramiko, scapy, and pywinrm). **Nmap is a
  hard dependency** — its `nmap-mac-prefixes` file powers the OUI/MAC vendor
  lookup.

---

## Quick start

```bash
# 1. Get the script
git clone https://github.com/netgeek1/netbox.git
cd netbox
chmod +x netbox-discovery.sh

# 2. Run it (root required)
sudo ./netbox-discovery.sh
```

First-run flow from the menu:

1. **8) Quick Setup** — installs dependencies and deploys NetBox in one step
   (or run **1** then **2** separately).
2. Open NetBox at `http://<host-ip>:8000`, confirm it's up. The script captures
   an API token automatically; you can re-set it under **6) NetBox Management**.
3. **4) Manage Credentials** — add SNMP / SSH / WinRM credentials and test them.
4. **5) Run Network Discovery** — scan one or more subnets.
5. Review the dry-run, then confirm the sync to NetBox.

---

## The menu

```
1  Install / Update Dependencies
2  Deploy / Update NetBox
3  Discovery Settings
4  Manage Credentials
5  Run Network Discovery
6  NetBox Management
7  View Logs
8  Quick Setup (Install + Deploy)
9  Import / Agent Deployment
0  Exit
```

- **Discovery Settings** — scan/SNMP/SSH timeouts, parallel threads, default
  site, NetBox port, Debug Mode, **Cred Test Stop-on-Pass**, and cron scheduling.
- **NetBox Management** — container status/lifecycle, API token, and
  **Enable Auto-Start on Boot**.
- **Import / Agent Deployment** — Hyper-V import and NetBox Agent push to Linux
  hosts.

---

## Credentials

Stored **encrypted** (AES-256-CBC via OpenSSL) in `/opt/netbox-discovery/.credentials.enc`,
separate from the main config. Manage them under **4) Manage Credentials**:

```
 1) Add SNMP v2c Community      2) Remove SNMP v2c Community
 3) Add SNMP v3 Account         4) Remove SNMP v3 Account
 5) Add SSH Credential          6) Remove SSH Credential
 7) Add Windows Credential      8) Remove Windows Credential
 9) Add Device Override        10) Remove Device Override
11) Import credentials JSON    12) Export credentials (plaintext)
13) Test credentials against an IP
```

- **SNMP v1/v2c** — community strings.
- **SNMP v3** — username + auth (e.g. SHA) + priv (e.g. AES) credentials.
- **SSH** — username with password and/or key file (+ optional enable password).
- **Windows (WinRM)** — username/password, workgroup or domain.
- **Device overrides** — pin specific credentials to a specific IP when the
  global set shouldn't apply.

When you add an SNMP community, SNMP v3 account, SSH, or Windows credential, you
are offered an **inline test** against an IP (leave blank to skip).

---

## Testing credentials

Credential mistakes are the most common cause of a host coming in with degraded
data (e.g. a Hyper-V host that fails WinRM shows up as a plain "Microsoft"
device). Two ways to catch that:

- **Inline** — test a credential against an IP as you enter it.
- **Bulk** — *Manage Credentials → 13) Test credentials against an IP* runs the
  stored credentials against one IP and reports the device's response.

Test order is **SNMP v2c → SNMP v3 → SSH → WinRM**. Behavior is governed by the
`CRED_TEST_STOP_ON_PASS` setting (*Discovery Settings → Cred Test Stop-on-Pass*):

- **ON (default)** — stop at the first credential that passes (quick "is it
  reachable" check).
- **OFF** — test every protocol/credential and print a `passed / failed`
  summary, so a single bad credential is flagged even when another protocol
  already works.

A passing test shows just the device response, e.g.:

```
PASS  public   Ubiquiti UniFi UCG-Fiber 5.1.19 Linux 5.4.213 ipq9574
```

---

## Configuration

Settings persist in `/opt/netbox-discovery/config.conf` (chmod 600). Most are
editable from **Discovery Settings**; a couple are environment toggles.

| Key | Default | Meaning |
| --- | --- | --- |
| `NETBOX_PORT` | `8000` | Port NetBox is published on. |
| `NETBOX_API_URL` | `http://<host>:8000` | Base API URL. |
| `NETBOX_API_TOKEN` | *(set on deploy)* | API token used for all writes. |
| `DEFAULT_SITE_NAME` | `Default Site` | Site new objects are created under. |
| `SCAN_TIMEOUT` | `5` | Per-host scan timeout (s). |
| `SNMP_TIMEOUT` | `3` | SNMP timeout (s). |
| `SSH_TIMEOUT` | `10` | SSH timeout (s). |
| `MAX_THREADS` | `20` | Parallel discovery workers. |
| `DEBUG_MODE` | `0` | Verbose debug logging. |
| `RAW_CAPTURE` | `1` | Keep every probe's raw output per host for review. |
| `CRED_TEST_STOP_ON_PASS` | `1` | Stop credential test at first pass (see above). |

Environment toggle (not stored): `SYNC_HTTP_LOG=0` disables the per-sync HTTP
trace (on by default).

---

## How it works (architecture)

The discovery → NetBox pipeline has three stages:

```
scan  ─►  reconcile  ─►  plan  ─►  write (single coordinated writer)
```

A few design points explain most of the behavior:

- **The scanner is Layer-3 only.** It runs from a NAT'd context (Nmap `-Pn`) and
  does not see device MAC addresses directly. A device's MAC is resolved by
  matching its IP against the **gateway/router ARP tables**. This is why a host
  must be in the gateway's ARP table for its MAC (and OUI-derived vendor) to
  appear.
- **SNMP runs in an ephemeral container** for clean, repeatable v1/v2c/v3
  collection.
- **Single coordinated writer.** All sync paths funnel through one reconciled
  writer, so the model is consistent and **idempotent** — re-running upserts by
  IP/name instead of duplicating.
- **Persistent identity cache.** Known-good identity (hostname, model,
  manufacturer, serial, Hyper-V status, VM inventory) is remembered across runs,
  so an intermittent SNMP/LLDP miss on a later scan doesn't blank out a device
  that was already identified.
- **OUI / MAC-vendor resolution.** Devices whose type can't be identified get a
  manufacturer from a MAC-prefix lookup (Nmap's `nmap-mac-prefixes`) against the
  ARP-derived MAC, instead of a wrong default.
- **HTTP sync trace.** Every NetBox request/response during a write is logged to
  `<results>.sync_http.log` for debugging.

---

## What gets created in NetBox

- **Devices** with role, manufacturer/device-type, serial, primary + secondary
  IPs, interfaces, and MAC addresses (NetBox 4.x MAC object model).
- **Virtual machines** with vCPU / memory / disk, a vNIC, and its IP; associated
  with a **cluster** named after the Hyper-V host.
- **Clusters** and cluster types (Hyper-V).
- **Cables** from LLDP/CDP neighbor data (reciprocal, deduplicated).
- **Custom fields** on devices/VMs: `cpu_model`, `cpu_cores`, `vcpus`,
  `memory_mb`, `memory_gb`, `disk_total_gb`, `disk_count`, `os_version`,
  `discovered_ports`, `discovery_methods`, and per-disk `disk_N_size_gb` /
  `disk_N_media` / `disk_N_interface`.

---

## Non-interactive / scheduled scans

```bash
# Scan + reconcile + sync one or more targets (CIDRs, ranges, or a file)
sudo ./netbox-discovery.sh --auto-scan '192.168.0.0/24'

# Scan a single host and print the raw results JSON (no sync)
sudo ./netbox-discovery.sh --scan 192.168.0.241
```

Recurring scans can be scheduled from **Discovery Settings → Schedule Recurring
Scan (cron)**, which installs a root crontab entry calling `--auto-scan`.

---

## Auto-start on boot

NetBox is brought back up automatically after a host reboot via a systemd unit
(`netbox-discovery.service`, a oneshot `docker compose up -d` that runs after
`docker.service`). It is installed automatically on deploy. For an existing
deployment, enable it once from **NetBox Management → Enable Auto-Start on Boot**
(requires root, since it writes to `/etc/systemd/system/`).

---

## Troubleshooting

- **HTTP sync trace** — after a sync, read `<results>.sync_http.log` in the
  discovery directory. It records each request (method, endpoint, body) and
  response (status, body). The end-of-sync summary reports request/error counts
  and only warns on *unexpected* errors (recovered "already exists" collisions
  are reported separately and are normal).
- **Credential test** — *Manage Credentials → 13* to confirm which credential
  actually authenticates against a host before relying on it.
- **Debug Mode** — *Discovery Settings → Debug Mode* for verbose logging.
- **Raw capture** — with `RAW_CAPTURE=1`, each host's raw probe output (Nmap XML,
  SNMP/SSH/HTTP/WinRM JSON, OS fingerprints) is kept for inspection.
- **A host came in wrong (e.g. "Microsoft"/no VMs)** — almost always a failed
  WinRM/SNMP credential on that run; fix the credential, re-scan, and re-sync.

---

## Known limitations

- **L3-only scanning** — a device must appear in the gateway/router ARP table
  for its MAC and OUI-derived vendor to be resolved.
- **Intermittent SNMP/LLDP** — a device that doesn't answer SNMP or omits its
  LLDP table on a given run may have partial data that run; the identity cache
  mitigates this for previously-seen hosts.
- **Partial rescans** don't resurrect hosts that weren't scanned — the cache
  fills missing fields on hosts that *are* present, it doesn't recreate absent
  ones.

---

## File & directory layout

| Path | Purpose |
| --- | --- |
| `/opt/netbox-discovery/` | Base directory. |
| `/opt/netbox-discovery/config.conf` | Persisted settings. |
| `/opt/netbox-discovery/.credentials.enc` | Encrypted credentials. |
| `/opt/netbox-discovery/discovery/` | Scan results, reconciled/plan JSON, HTTP traces, caches. |
| `/opt/netbox-docker/` | NetBox Docker stack. |
| `/var/log/netbox-discovery/` | Logs. |

---

## Security notes

- Credentials are encrypted (AES-256-CBC) and stored separately from config; the
  config and credential files are `chmod 600`.
- NetBox writes use an **API token**, not a password.
- This tool **scans networks and stores infrastructure credentials** — run it
  only against networks you are authorized to scan, and protect the host it runs
  on accordingly.

---

## License

Add your chosen license here (e.g. MIT). Until then, treat as
all-rights-reserved by the repository owner.

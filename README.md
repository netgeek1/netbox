This script is a **large Bash-based automation suite for deploying, discovering, and synchronizing network infrastructure into NetBox** on Ubuntu 24.04. According to its header, it's called **"NetBox Auto-Deploy & Network Discovery Suite"** and is currently version 2.1.4. ([GitHub][1])

### High-level purpose

It combines four major functions:

1. **Deploy NetBox automatically**

   * Installs Docker and Docker Compose.
   * Downloads and configures NetBox Docker.
   * Creates an admin account and API token automatically.
   * Generates configuration files and stores credentials. ([GitHub][1])

2. **Discover devices on networks**

   * Scans one or more subnets.
   * Supports CIDRs, IP ranges, and files containing targets.
   * Uses tools such as Nmap, Masscan, ARP scanning, SNMP, SSH, LLDP/CDP, DNS, and banner probing to identify devices and collect inventory data. ([GitHub][1])

3. **Populate and maintain NetBox**

   * Creates and updates:

     * Sites
     * Manufacturers
     * Device types
     * Device roles
     * VLANs
     * Interfaces
     * IP addresses
     * MAC addresses
     * Cables and topology relationships
   * Uses the NetBox REST API extensively and is designed to be idempotent (safe to rerun). ([GitHub][1])

4. **Import servers, VMs, and Hyper-V environments**

   * Integrates with NetBox Agent.
   * Can deploy NetBox Agent to discovered Linux hosts.
   * Can query Windows Hyper-V hosts via WinRM and PowerShell.
   * Imports virtualization clusters, VMs, NICs, disks, MAC addresses, and IPs into NetBox. ([GitHub][1])

---

### What it installs

The script installs a large set of network and automation tools, including:

* Docker
* Nmap
* Masscan
* ARP-Scan
* Fping
* SNMP tools
* LLDP daemon
* SSH tools
* Netmiko
* NAPALM
* PySNMP
* Paramiko
* Pynetbox
* Scapy
* NetBox Agent
* PyWinRM

along with many supporting utilities. ([GitHub][1])

---

### Network discovery capabilities

The changelog and dependency list indicate it can gather:

* SNMP device information
* Interface inventories
* VLAN assignments
* CDP and LLDP neighbors
* Device serial numbers
* Manufacturer/model information
* CPU and memory statistics
* Storage information
* PoE status
* Cisco-specific CPU and memory metrics
* Interface speeds, duplex settings, and descriptions

and then synchronize that data into NetBox. ([GitHub][1])

---

### Hyper-V and virtualization support

Recent versions added substantial virtualization support:

* Discover Hyper-V hosts.
* Enumerate virtual machines.
* Sync VM interfaces and MAC addresses.
* Sync virtual disks.
* Create clusters and cluster types.
* Associate VMs with hosts and clusters.
* Collect physical host hardware inventory:

  * CPU model
  * Processor count
  * RAM
  * OS version
  * Disk inventory and capacities

using NetBox custom fields. ([GitHub][1])

---

### Security-related features

The script:

* Encrypts stored credentials using AES-256-CBC with OpenSSL.
* Generates an encryption key file.
* Stores credentials separately from configuration.
* Automatically manages Docker group membership.
* Uses API tokens rather than passwords for NetBox API access. ([GitHub][1])

---

### Operational model

The workflow appears to be:

1. Install dependencies.
2. Deploy NetBox.
3. Discover network devices.
4. Classify devices.
5. Collect inventory and topology information.
6. Create/update objects in NetBox.
7. Optionally deploy NetBox Agent to discovered Linux systems.
8. Optionally import Hyper-V infrastructure and virtual machines. ([GitHub][1])

### In one sentence

This script is essentially a **turnkey network source-of-truth platform installer and discovery engine**: it deploys NetBox, scans networks using multiple protocols, gathers infrastructure inventory and topology information, and automatically builds and maintains a populated NetBox environment with devices, IPs, VLANs, interfaces, servers, and virtual machines. ([GitHub][1])

[1]: https://raw.githubusercontent.com/netgeek1/netbox/refs/heads/main/netbox-discovery.sh "raw.githubusercontent.com"

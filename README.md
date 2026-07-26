# tailmox
cluster proxmox over tailscale -- move virtual machines and containers across geographically distant nodes

![GitHub Release](https://img.shields.io/github/v/release/willjasen/tailmox)
![GitHub Repo stars](https://img.shields.io/github/stars/willjasen/tailmox)

[read more about the idea of darkclouds](https://willjasen.com/posts/create-your-own-darkcloud/)

---

### ‼️ DANGER ‼️ 

In the interest of complete transparency, if you follow this guide or use this project, there’s a very minuscule but non-zero chance that you may violate the Bekenstein bound, at which the resulting black hole may swallow the earth whole. You have been warned!

---

### ⚠️ WARNING ⚠️
- This project is for development, testing, and research purposes only. This guide comes with no guarantee or warranty that these steps will work within your environment. Should you attempt within a production environment, any negative outcomes are not the fault of this guide or its author.
- It is recommended to use this script within a testing or development environment on freshly installed Proxmox v8 or v9 hosts. Testing has not been performed on hosts with further configuration and running this project on said hosts may break them.

---

### 📖 Overview 📖

This project was originally started as a [gist](https://gist.github.com/willjasen/df71ca4ec635211d83cdc18fe7f658ca) guide on how to cluster Proxmox servers together using Tailscale so that hosts not physically located together could participate in a cluster. While a how-to is great, being able to replicate the steps in code and sharing that with others was always been the goal.

---

### 😮 Controversy 😮

Many, many people will expend a lot of effort and noise to proclaim that this architecture is impossible and will never work. It is often cited that corosync requires a super extra-low amount of latency in order to work properly. While corosync is latency sensitive, there is some freedom within that constraint. My experience with issues clustering in this way has been very minimal, but I am only me, with a handful of Proxmox hosts in a case study of one.

---

### 💭 Mindfullness 💭

- Latency

Corosync uses a logical ring topology in its architecture based on a token. Each host in the cluster passes the token around to each other in a circular fashion with timing. In a traditional cluster network, each host communicates with each other host over a LAN, which is typically a low-latency, high bandwidth network (possibly even a non-routable one). Configuring corosync to communicate via Tailscale changes this underlying network design in which Tailscale is a layer 3 overlay network on top of existing network and generally works over the Internet. One must consider the the latency between each host and every other host when determining if Tailmox will work well enough given this, implying that this must carefully evaluated when adding more and more hosts. 

For example, a three node cluster with 50 milliseconds on average to one of the host is likely okay for Tailmox. A three node cluster with one host on a slow link which regularly results in a much higher latency is not likely to be okay. A five, seven, or nine node cluster with varying degrees of separation by latency would require even further consideration.

- Replications

Tailmox sets up each host's corosync clustering process to communicate via Tailscale, with the very basic/default hypervisor features of Proxmox, and that's all. Features like high availability and Ceph aren't likely to work well within a Tailmox cluster, unless those features are manually setup otherwise to communicate over another network like a LAN. However, features like being able to replicate a virtual machine or container from one node to another does work, making an architecture like ZFS replication across geographically distanced hosts over the internet possible. The key here with that those geographically distanced hosts is that they must have adqueate bandwidth, as there are no other network paths for the ZFS replications to take place over, and the bandwidth between the source and destination hosts cannot be saturated because it would interfere with corosync's performance (mainly, having just enough sliver of bandwidth so that packet latency and drops don't increase significantly). Given this, ZFS replication jobs can be set with a bandwidth limit to help control oversaturation of the link.

In my usage, I have been able to move a virtual server of about 20 terbytes by staging it via ZFS replication from a server in the EU over to my own server at home in the US, and performed a live migration of that server after it was staged in which it moved within a few minutes. Keep in mind that I have a gigabit fiber connection at home and the server in the EU was within a datacenter, also with a gigabit connection.

---

### ✏️ Preparation ✏️

Tailmox requires a Tailscale ACL and one should be prepared for cluster and web communications. Please review the three codeblocks within this section and make sure your ACL includes those pieces!

The script will check that the following TCP ports are available:

 - TCP 22
 - TCP 443
 - TCP 8669 (the Tailmox dashboard and web terminal; `TMOX` on a telephone keypad)
 - TCP 8006

The script will exit if any of the ports aren't available.

This script uses the tag of "tailmox" to determine which Tailscale machines are using this project to establish a cluster together. The "tailmox" tag should be specified under "tagOwners":
```
"tagOwners": {
	"tag:tailmox": [
		"autogroup:owner",
	],
}
```

Proxmox clustering requires TCP 22, TCP 443, TCP 8006, and UDP 5405 through 5412. Using the now established tag of "tailmox", create access control rules that allow all hosts with this tag to communicate with all other hosts with the tag as well. The rule at the end restricts the Tailmox dashboard and its read-only command-output view to tailnet administrators.
```
"acls": [
	/// ... ACL rules before

	// allow Tailmox
	{"action": "accept", "proto": "tcp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:22"]},   // Tailmox SSH
	{"action": "accept", "proto": "tcp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:443"]}, // Tailmox web
	{"action": "accept", "proto": "tcp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:8006"]}, // Tailmox web
	{"action": "accept", "proto": "tcp", "src": ["autogroup:admin"], "dst": ["tag:tailmox:8669"]}, // Tailmox dashboard and terminal
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5405"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5406"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5407"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5408"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5409"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5410"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5411"]}, // Tailmox clustering
	{"action": "accept", "proto": "udp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:5412"]}, // Tailmox clustering

	// allow Proxmox web from all other devices
	{"action": "accept", "proto": "tcp", "src": ["*"], "dst": ["tag:tailmox:443"]}, // Tailmox web
	{"action": "accept", "proto": "tcp", "src": ["*"], "dst": ["tag:tailmox:8006"]}, // Tailmox web

	/// ... ACL rules after 
]
```

Tailmox uses the Tailscale Services feature which allows one URL to access any of the tailmox hosts (via https://tailmox.MAGICDNS_NAME.ts.net):

```
"autoApprovers": {
	"services": {
		"svc:tailmox": ["tag:tailmox"],
		"tag:tailmox": ["tag:tailmox"],
	},
},
```

The last step is to create a Tailscale service (via https://login.tailscale.com/admin/services):

Under the "Advertised" section, click "Define Service". Then fill in the following details:

 - Service name: tailmox
 - Description: (this can be whatever you want)
 - Ports: 443
 - Service tags: (add the tag of 'tailmox')

then submit.

---

### ⚒️ Installation ⚒️

1. Change to the /opt directory: `cd /opt`
2. Pull this repo: `git clone https://github.com/willjasen/tailmox`
2. Change into the install directory: `cd tailmox`
3. Make sure that the script is executable: `chmod +x tailmox.sh`
4. Bootstrap the `tailmox` command and start the installer: `./tailmox serve`
5. Open the HTTPS URL printed by the script from an administrator's device on your tailnet. The dashboard includes a read-only command-output view, explicit buttons for `tailmox test`, `tailmox backups create`, and `tailmox cluster`, and a read-only configuration-backup inventory.

---

### 🖥️ Usage 🖥️

`tailmox.sh` starts a persistent dashboard on TCP 8669 and prints its tailnet-only HTTPS URL using the current Proxmox host's Tailscale MagicDNS name. The dashboard embeds a read-only command-output view at `/terminal/` and shows a read-only inventory of configuration backups. Opening the page does not start setup or launch a host shell. Use the `tailmox test` button for the read-only setup check, `tailmox backups create` to create a private configuration archive, or the confirmation-gated `tailmox cluster` button to begin the clustering workflow. The command-output service listens only on localhost; Tailscale Serve provides HTTPS and access over the tailnet.

The local `tailmox` command provides shortcuts for the main workflows:

```bash
tailmox cluster             # Run the complete clustering workflow
tailmox serve               # Start the dashboard and browser terminal
tailmox serve start         # Explicit form of `tailmox serve`
tailmox serve stop          # Stop the dashboard and browser terminal
tailmox stage               # Set up Tailscale and certificates only
tailmox backups             # List configuration backups
tailmox backups create      # Create a configuration backup now
tailmox test                # Test setup without changing the host
tailmox monitor             # Record test analytics every minute
tailmox monitor install     # Install and start the background monitor
tailmox monitor uninstall   # Stop and remove the background monitor
tailmox self-test           # Run the regression test suite
tailmox help                # List available commands
```

The launcher accepts the `--auth-key` parameter, followed by a Tailscale auth key, which can be generated via the Tailscale [Keys](https://login.tailscale.com/admin/settings/keys) page. An auth key is required when the host is not already signed in because the browser terminal is reachable only after Tailscale is online.

Tailmox preserves an existing Tailscale login instead of authenticating again. After Tailscale connects, `tailmox stage` and the full clustering workflow verify that the local device has the exact `tag:tailmox` tag and stop before configuring Tailscale Serve if it does not. Assign the tag through the Tailscale admin console or API. When provisioning a logged-out host with `--auth-key`, configure that auth key to apply `tag:tailmox`.

During the running of the script, if there are existing hosts within the tailmox cluster, it is likely to ask for the password of one of the remote hosts in order to properly join the Proxmox cluster.

Immediately before Tailmox creates or joins a Proxmox cluster, it archives the local `/etc/pve`, `/etc/corosync`, and `/etc/hosts` state under `/var/backups/tailmox`. The cluster change is blocked if `/etc/pve` is unavailable or the archive cannot be completed. Backup archives are readable only by root.

Run `tailmox backups` (or `tailmox backups list`) to list the Tailmox configuration backups on the host, including their type, size, integrity result, and full path. Run `tailmox backups create` to create the same private `/etc/pve`, `/etc/corosync`, and `/etc/hosts` archive on demand. These commands manage Tailmox configuration safeguards only; they do not back up or restore guests.

The dashboard lists each Tailmox configuration backup's type, creation time,
size, and basic integrity result. It publishes metadata only: backup contents
and absolute host paths are not placed in the web directory, and the dashboard
does not provide download, restore, or delete actions. This inventory covers
Tailmox cluster-configuration safeguards rather than Proxmox guest backups
created by `vzdump`.

If Tailmox is run on a host that is already a member of a Proxmox cluster, it preserves the existing cluster name, membership, guests, storage configuration, and other cluster settings. Before a new host can join over Tailscale, every existing Corosync member must also be signed in to the same tailnet, online, and carry the exact `tag:tailmox` tag. Run `tailmox stage` on each existing member first.

After every member is visible, run `tailmox cluster` on one existing member. Tailmox requires the cluster to be quorate, verifies a unique online Tailscale address for every configured member, creates a private timestamped backup of the shared Corosync configuration under `/var/backups/tailmox`, and asks you to type `MIGRATE` before changing every Corosync link-0 address together. Proxmox applies this shared configuration cluster-wide. Membership is not recreated, but Corosync may briefly lose quorum while the members move to the Tailscale network. If the cluster already uses those Tailscale addresses, Tailmox makes no Corosync change and exits successfully.

Tailmox refuses a partial migration. Preparing only one member of a multi-node cluster is not enough because every Corosync member must be able to communicate with every other member. Once the existing cluster is prepared successfully, a brand-new, empty Proxmox host can run `tailmox cluster`, find one of those tagged members, and join the preserved cluster.

Before invoking `pvecm add`, the new host also verifies that the remote cluster reports the expected Tailscale Corosync address for every existing member. It refuses the join if the remote cluster is only partially prepared.

---

### 🧪 Testing 🧪

This project has been tested to successfully join a cluster of three Proxmox v8 and v9 hosts together into a cluster via Tailscale. It has been tested up to the point of achieving this goal and not further. It is possible that further testing with other features related to clustering (like high availability and ZFS replication) may not work, though bugs can be patched appropriately when known.

Safely exercise the setup checks on a Proxmox host with:

```bash
tailmox test
```

This read-only test first verifies that the local Proxmox host is online with the exact `tag:tailmox` identity, then tests its own Tailscale path, ICMP behavior, and required TCP ports through its Tailscale address. Only after that self-test passes does it perform the same network checks for the other Tailmox peers. It does not install packages, change Tailscale or systemd, request certificates, create a cluster, or join one.

Run the same checks continuously and keep a local history with:

```bash
tailmox monitor
```

The monitor runs `tailmox test` immediately and then once per minute. It uses
`auto` mode by default: a host records `pre-cluster` network health until every
configured Corosync member uses its matching Tailscale address. Only then does
it record `cluster` mode plus the available quorum, votes, ring, and membership
data. Ordinary Proxmox cluster membership by itself does not activate cluster
mode. A mode can also be selected explicitly:

```bash
tailmox monitor --mode pre-cluster
tailmox monitor --mode cluster
tailmox monitor --once
```

For continuous operation across reboots, install it as a system service:

```bash
tailmox monitor install
```

To stop and remove that service later:

```bash
tailmox monitor uninstall
```

Uninstalling removes only the Tailmox monitor service definition. It preserves
the monitoring database so historical analytics are available if the monitor
is reinstalled.

Results are stored in `/var/lib/tailmox/monitor.sqlite3`. The schema keeps
runs, stable node identities, per-run node snapshots, individual network
checks, and cluster samples in related tables. Raw Tailscale JSON and terminal
output are not stored in the database. Every host has its own database and
records only tests performed locally; Tailmox does not accept or upload monitor
results between hosts.

While the monitor is running, it exposes a read-only Server-Sent Events
endpoint on localhost TCP 8671. `tailmox serve start` publishes that endpoint beneath
`/monitor` through the existing tailnet-only HTTPS listener, and the dashboard
updates monitor results and the backup inventory without browser polling.
Backup metadata is pushed when Tailmox refreshes its inventory, including after
`tailmox backups create`; the initial page load and Refresh button retain a
read-only fallback. The endpoint accepts no uploads or monitoring results. The
database and backup contents remain outside the web root; the browser receives
only a small analytics projection and backup metadata containing type, creation
time, size, integrity, and filename.

Run the project's regression test suite separately with:

```bash
tailmox self-test
```

If planning to run `tailmox.sh` many times in a short period, it is recommended that staging is performed first. By supplying the "--staging" parameter, `tailmox.sh` will install Tailscale and retrieve the Tailscale certificate and then stop. The purpose of staging is to prevent many requests to Tailscale for the same certificate in rapid succession. If staging is not performed, it is possible that the step to setup the certificate will take a very long time, which is not optimal when running many tests centered around setting up the Proxmox cluster.

To deploy fresh Proxmox hosts within an existing Proxmox environment and to perform quicker testing of Tailmox, [read more here](test-env/README.md).

---

### 🤓 The Scripts 🤓

`tailmox.sh` -  this is the main script of the project
- checks that the host is Proxmox v8 or v9, installs dependencies and Tailscale, then starts Tailscale
- once Tailscale is running, the host will generate a certificate from Tailscale (to be used with the web interface/API)
- it will then retrieve other Tailscale machines with the tag of "tailmox", check all of their Tailscale DNS names in parallel for approximately five seconds using 20 Tailscale path pings plus both 64-byte and 1280-byte ICMP packets, and check TCP 443 and TCP 8006; at least 80% (16 of 20) of the Tailscale path pings must succeed, while ICMP is evaluated separately; ICMP replies that are missing or take longer than 50 ms produce a warning with a visible countdown and require the user to type `PROCEED` within 10 seconds, otherwise setup is cancelled, while a failed Tailscale path sample or other failed check stops the script
- after the checks pass, the host will check if it is in a cluster; an existing cluster is preserved and, after explicit confirmation, its complete Corosync link-0 network is migrated to the verified Tailscale addresses of all current members
- if the host is not clustered, it will check the other Tailscale machines with the tag of "tailmox" to see if they are part of a cluster; when it finds a matching host in a cluster, it will then attempt to join to the cluster using it; if another host isn't found, then a new cluster will be prompted to be created
- immediately before `pvecm create` or `pvecm add`, it archives the local Proxmox and Corosync configuration and `/etc/hosts`; the cluster operation fails closed if the backup cannot be made

There are further scripts related to testing in the "test-env" folder.

---

### 🏁 Afterword 🏁

This project has been a fun experiment of mine after seeing many say that it could never work and I like a challenge myself. It's received much more attention that I had expected it to and I'm pleased to see it! It seems that others are also interested in the idea of geographically distanced hosts and the ability to move around virtual machines and containers with less effort!

---
---

The original guide has been moved to [GUIDE.md](https://raw.githubusercontent.com/willjasen/tailmox/refs/heads/main/GUIDE.md)

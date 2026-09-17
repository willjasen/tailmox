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

Proxmox clustering requires TCP 22, TCP 443, TCP 8006, and UDP 5405 through 5412. Using the now established tag of "tailmox", create access control rules that allow all hosts with this tag to communicate with all other hosts with the tag as well. There is also an included rule at the end to allow all devices within the tailnet to access the web interface of the hosts with the tag.
```
"acls": [
	/// ... ACL rules before

	// allow Tailmox
	{"action": "accept", "proto": "tcp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:22"]},   // Tailmox SSH
	{"action": "accept", "proto": "tcp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:443"]}, // Tailmox web
	{"action": "accept", "proto": "tcp", "src": ["tag:tailmox"], "dst": ["tag:tailmox:8006"]}, // Tailmox web
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

On each Proxmox VE 8 or 9 host, run as `root`:

```sh
curl -fsSL https://raw.githubusercontent.com/willjasen/tailmox/dev/install.sh | bash
```

The installer verifies the Proxmox version, clones the current `dev` branch
into `/opt/tailmox`, and adds the `tailmox` command at `/usr/local/bin/tailmox`.
It then runs the staging workflow, which installs or connects Tailscale and
starts and publishes the Tailmox monitor service. At the end it prints the
node monitor link on HTTPS port `8088` and the shared service link on standard
HTTPS without an explicit port.

If the host is not signed in to Tailscale, the staging workflow prints a login
link. An auth key can instead be supplied to the one-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/willjasen/tailmox/dev/install.sh | bash -s -- --auth-key YOUR_KEY
```

The installer also requires each host to have an age identity. It prompts to
create the post-quantum cluster identity on the first host, or to privately
import that same identity on another host. Back up the identity shown by the
first host from the root-only `/etc/tailmox/identity.txt` file; the installer
shows only a shortened recipient and fingerprint in the terminal. Private
identities and auth keys are not logged by the installer.
If the Proxmox cluster security registry already contains a public age
recipient, the installer displays that recipient and its fingerprint and only
offers to import the matching private identity, preventing a conflicting
identity from being created.

Run the same one-liner again to update an existing Tailmox installation. The
updater performs a fast-forward Git update and refuses to proceed over local
Git changes, a different branch or remote, or an unrelated command or directory.
Older archive-based installations are migrated to a Git checkout. Each run
refreshes the Tailscale Serve and monitor staging configuration, but does not
create or join a Proxmox cluster.

After every host is staged and has the same cluster identity, start clustering
explicitly:

```sh
tailmox cluster
```

To inspect the installer before running it, download
[`install.sh`](https://raw.githubusercontent.com/willjasen/tailmox/dev/install.sh)
and review it locally first.

---

### 🖥️ Usage 🖥️

`tailmox.sh` can be run without any parameters, but if the host is not logged into Tailscale, then when the script performs `tailscale up`, Tailscale will provide a link to use to login with.

In order to make the Tailscale functions easier to handle, `tailmox.sh` accepts the "--auth-key" parameter, followed by a Tailscale auth key, which can be generated via their [Keys](https://login.tailscale.com/admin/settings/keys) page. It is recommended that the key generated is reusable.

During the running of the script, if there are existing hosts within the tailmox cluster, it is likely to ask for the password of one of the remote hosts in order to properly join the Proxmox cluster.

To disable Tailmox for corosync and move cluster communication back to a LAN,
run this on a quorate cluster member and provide the LAN CIDR that every node
should use:

```sh
tailmox disable 192.168.1.0/24
```

Tailmox requires all configured nodes online, quorate, and connected, with
matching configurations. It discovers one unique LAN IPv4 address per host,
checks all-to-all source-bound LAN ping, and validates every planned configuration
on every host over noninteractive SSH. This mandatory dry run precedes the warning
and exact `DISABLE` confirmation; `TAILMOX_ASSUME_YES` cannot bypass either.
Use `--dry-run` to stop after validation, or `--keep-tailscale` to retain Tailscale
as a lower-priority fallback. Running without a CIDR prompts for the subnet and
fallback choice. Re-running always performs a fresh dry run.
SSH access using existing link addresses must already work with trusted host
keys. LAN addresses must be static and allow Corosync UDP traffic between hosts;
successful ping alone does not establish this. Run one migration at a time across
the cluster and avoid concurrent cluster configuration edits.

The migration adds LAN link 1 while retaining Tailscale link 0, verifies every
node, then prefers LAN. For LAN-only operation it moves link 0 to LAN while link 1
remains connected, verifies again, then removes temporary link 1. Each version is
checked on every node for configuration propagation, quorum and actual KNET peer
connections before advancing. Existing multi-link or non-passive configurations
are rejected for manual review. No Tailscale service is stopped.

The port 8669 website includes **Move Corosync to LAN** in its terminal actions.
The monitor site also has a dedicated **Disable Tailmox** page in the top page
dropdown (`/disable`, or `/monitor/disable` behind Tailscale Serve), sharing its
form styling with ID and Settings. The page scans
the host's assigned IPv4 networks and lists LAN subnets with their interface names,
excluding loopback, link-local and Tailscale interfaces. Choose a discovered
subnet or **Enter manually**, choose whether to retain the Tailscale fallback,
then select **Run dry run**. Manual entry remains available if discovery fails
or finds no LAN networks. Discovery is read-only; the dry run still checks every
cluster member against the selected subnet. The page streams
the results and only exposes confirmation after the migration process completes
validation. Type `DISABLE` to apply that same plan, or cancel it. Confirmation
expires after ten minutes and is restricted to the Tailscale user who started
the dry run. The process rechecks the cluster before applying the plan.
Failures identify the affected host and address, the failed check, and its exit
status or timeout. SSH and command diagnostics are included with credential
details redacted; link checks name disconnected or missing peers. A connection
failure is reported as such rather than assuming the host is offline.

The port 8669 terminal opens the same interactive workflow, including input collection, mandatory dry
run and confirmation. The terminal accepts input only for approved workflows and
does not expose a shell. Existing deployments need their web service updated and
restarted to enable terminal input.

Recovery configurations are stored in `/var/lib/tailmox/migrations` before writes.
On failed verification the migration stops at the current stage; it does not
attempt an automatic rollback through a potentially partitioned cluster. Keep
console access available: dry-run validation cannot guarantee live connectivity,
and quorum loss can trigger HA recovery. Backup restoration requires a newer
`config_version` and review of every node. This workflow still requires validation
in a disposable Proxmox environment before production use.

### 📈 Monitoring 📈

The Tailmox console on HTTPS port `8669` opens on an Intro page and provides a
top-right section selector for Intro, Staging, Settings, and Monitor. Intro
checks the local age identity and encrypted configuration and points to the
next required step. Staging runs the guarded host and analytics workflows,
Settings embeds the encrypted configuration interface, and Monitor preserves
the original analytics dashboard, terminal actions, and backup inventory. The
console publishes the authenticated monitor service beneath `/control` on the
same Tailscale Serve listener.

Tailmox installs a lightweight monitoring interface as `tailmox-monitor.service`. It listens locally on port `8088`. Each node mounts it through Tailscale Serve on HTTPS port `8088` at `/monitor`, while the shared Tailmox service publishes it at the root of its HTTPS port `443` URL:

- `https://HOSTNAME.MAGICDNS_NAME.ts.net:8088/monitor/`
- `https://tailmox.MAGICDNS_NAME.ts.net/`

The node's normal HTTPS port `443` continues to proxy the Proxmox interface.

The monitor includes corosync-specific details: whether the `corosync` service is active and enabled, whether the cluster is quorate, expected and current votes, corosync transport, configured and active member information from `corosync-cmapctl`, quorum node details from `corosync-quorumtool`, cluster member count over time, link-quality history for each peer, and recent `corosync` journal entries. Configured cluster members that are not active in corosync are shown as offline. The Health page shows successful and failed checks for cluster services, hosts, quorum, Tailmox webservers, peer links, and configured InfluxDB availability.

When InfluxDB is configured, monitor graphs query the shared bucket across every
reporting Tailmox host. Legends identify the source host, and path-specific
graphs label both ends (for example, `pve3 → pve4`) so the load-balanced service
shows the same cluster-wide history regardless of which host serves the page.

The monitor page is display-only: it refreshes status, tables, graphs, and logs
automatically and contains no navigation links or operational controls.

Do not publish port `8088` through an Internet-facing reverse proxy. Tailscale
Serve supplies identity headers to that privileged service, and those headers
are only trustworthy inside the Serve boundary. Tailmox also rejects requests
carrying Cloudflare proxy headers before checking Tailscale identity.

For a public working example, use `tailmox-public-monitor.service` on localhost
port `8089`. The root monitor writes a fixed, sanitized snapshot under
`/run/tailmox-public-monitor/`; the public service runs as the unprivileged
`tailmox-public` user and can only read that snapshot and static assets. It has
no administrative routes, accepts only `GET` and `HEAD`, validates the HTTP
host, and sends restrictive browser security headers. The public page mirrors
the private monitor's six one-hour graphs, but the export schema only permits
their timestamps, numeric measurements, health booleans, and display labels.
Those labels intentionally expose the hostnames and Tailscale addresses shown
by the private graphs. Cluster names, logs, configuration, credentials, and raw
command output never enter the public snapshot. Point Cloudflare Tunnel at
`http://localhost:8089`, never `8088`.

The public Corosync link-quality section includes a hostname-only topology. It
combines both measured directions into one host-pair edge, labels the edge with
the higher current average latency, colors degraded and offline paths, and
shows missing measurements as neutral links. Its detail table preserves the
directional values without publishing peer IP addresses.

The public service's systemd unit applies a capability-free sandbox and permits
only loopback network traffic. Create its system account with a non-login shell,
install the unit after replacing `@TAILMOX_DIR@` with the installation path,
and install `tailmox-public-monitor-export.conf` as the private monitor's
`public-snapshot.conf` systemd drop-in. Enable both pieces only on the host
intentionally serving the public demo. At
Cloudflare, also enforce HTTPS, block methods other than `GET` and `HEAD`, rate
limit the hostname, and enable managed WAF and bot protections. These edge
controls are defense in depth; the origin remains safe if they are misconfigured
because port `8089` contains no privileged handler.

To enable Google Analytics 4 for the public page, create the root-owned file
`/etc/tailmox/public-monitor.env` with mode `0600` and set the site's measurement
ID, for example `TAILMOX_GA_MEASUREMENT_ID=G-ABC123`. Restart
`tailmox-public-monitor.service` after changing it. Analytics is disabled when
the setting is absent. The service validates the ID and only relaxes its Content
Security Policy for Google Analytics while analytics is enabled; the private
Tailmox console is unaffected.

InfluxDB credentials are configured only from the monitor UI at
`/monitor/editInfluxDB`. On the first host, create the dedicated Tailmox age
identity and back it up when it is displayed. Tailmox requires age 1.3.0 or
newer and generates a hybrid ML-KEM-768 + X25519 identity beginning with
`AGE-SECRET-KEY-PQ-1`; it never silently falls back to a classic X25519 key.
Add that same identity from the web UI on every other Tailmox host. Its private value is stored locally as
`/etc/tailmox/identity.txt` with root-only permissions and is never written to
the Proxmox clustered filesystem.

Tailmox stores the age-encrypted configuration at
`/etc/pve/tailmox/config.age`. Each host also generates its own dedicated
Ed25519 configuration-signing key at
`/etc/tailmox/signing-key.pem`. This is a Tailmox-only OpenSSL key: it is not an
SSH host key, is never placed in `authorized_keys`, and is not used for login.
Only its public key is placed in the clustered security registry.

Configuration changes are proposals signed by the host that created them.
Every registered host verifies and accepts the exact encrypted revision from
its own monitor UI. Tailmox activates the revision only after all registered
hosts have written valid signed acceptance receipts. A rejection or missing
receipt keeps the previous configuration active. The proposing host records
its own acceptance when it creates the proposal.

Existing `/etc/pve/tailmox/tailmox.conf` and `/etc/tailmox-monitor.env` files
are treated as legacy plaintext. Tailmox continues using the existing settings
so monitoring is not interrupted. After the age identity and host signer are
initialized, the web interface automatically creates an encrypted migration
proposal. The plaintext files are removed only after every registered host has
accepted that exact revision and it becomes active.

When configured, Tailmox writes `tailmox_cluster_status`,
`tailmox_corosync_member`, `tailmox_corosync_link_quality`, and
`tailmox_corosync_config` measurements using InfluxDB line protocol. The
cluster status measurement includes active, configured, quorum, and offline
node counts. `tailmox_corosync_config` includes the global knet MTU setting,
PMTUD interval, knet ping interval and timeout, token timing, consensus timing,
max network delay, and related corosync config values. If the encrypted
settings are incomplete or cannot be decrypted, the monitor continues without
exporting data and reports the configuration error in the web interface.

The older periodic test collector is still available as `tailmox analytics`. It records `tailmox check` results, latency summaries, and cluster samples in SQLite, and can be installed as `tailmox-analytics.service` with `tailmox analytics install`.

To export the latency and TCP results from the read-only `tailmox check` to InfluxDB, configure
InfluxDB in the monitor settings, then run `tailmox influx install`. The exporter
runs the real Tailmox monitoring check once per minute and writes
`tailmox_icmp` and `tailmox_tcp` measurements. Use `tailmox influx restart` or
`tailmox influx uninstall` to manage it.

---

### 🧪 Testing 🧪

This project has been tested to successfully join a cluster of three Proxmox v8 and v9 hosts together into a cluster via Tailscale. It has been tested up to the point of achieving this goal and not further. It is possible that further testing with other features related to clustering (like high availability and ZFS replication) may not work, though bugs can be patched appropriately when known.

If planning to run `tailmox.sh` many times in a short period, it is recommended that staging is performed first. By supplying the "--staging" parameter, `tailmox.sh` will install Tailscale and retrieve the Tailscale certificate and then stop. The purpose of staging is to prevent many requests to Tailscale for the same certificate in rapid succession. If staging is not performed, it is possible that the step to setup the certificate will take a very long time, which is not optimal when running many tests centered around setting up the Proxmox cluster.

To deploy fresh Proxmox hosts within an existing Proxmox environment and to perform quicker testing of Tailmox, [read more here](test-env/README.md).

---

### 🤓 The Scripts 🤓

To display the Tailmox membership recorded on the cluster, run:

```sh
./tailmox.sh info
```

To remove a host from the Proxmox cluster, run this on a remaining cluster
member:

```sh
tailmox remove <node-name>
```

Tailmox confirms the target is a current cluster member, runs `pvecm delnode`,
and removes the host from Tailmox's shared membership record. The removed host
must still have its local Proxmox cluster configuration reset before it can be
reused or joined to another cluster. Do not run this against the local host.

The command reports that the host is not part of a Tailmox cluster when the
state file is missing or contains no hosts. Hosts added by Tailmox are stored
in `/etc/pve/tailmox/state.json`, so Proxmox replicates the membership record
to every cluster member. Each entry includes a UTC `date_joined` timestamp.
Older hosts without that key are still displayed and simply omit the date.
Running the cluster workflow again on an existing member repairs a missing
entry for that host without recreating or rejoining the cluster.

`tailmox.sh` -  this is the main script of the project
- checks that the host is Proxmox v8 or v9, installs dependencies and Tailscale, then starts Tailscale
- once Tailscale is running, the host will generate a certificate from Tailscale (to be used with the web interface/API)
- installs the Tailmox monitoring interface and publishes it at `/monitor` through Tailscale Serve
- it will then retrieve other Tailscale machines with tag of "tailmox", then check if it can reach them via ping (ICMP), via TCP 443, and via TCP 8006; if these checks do not pass, the script will exit
- after the checks pass, the host will check if it is in a cluster; if it is not, it will check the other Tailscale machines with the tag of "tailmox" to see if they are part of a cluster; when it finds a matching host in a cluster, it will then attempt to join to the cluster using it; if another host isn't found, then a new cluster will be prompted to be created

`tailmox-monitor.py` - this is the local web monitoring interface
- reports Proxmox cluster and Tailscale status
- reports corosync service, quorum, member, vote, and recent log details
- refreshes the dashboard automatically

`tailmox-monitor` - this is the legacy test analytics collector behind `tailmox analytics`
- stores periodic `tailmox check` results in SQLite
- exposes an event stream for the older dashboard assets in `web/`

There are further scripts related to testing in the "test-env" folder.

---

### 🏁 Afterword 🏁

This project has been a fun experiment of mine after seeing many say that it could never work and I like a challenge myself. It's received much more attention that I had expected it to and I'm pleased to see it! It seems that others are also interested in the idea of geographically distanced hosts and the ability to move around virtual machines and containers with less effort!

---
---

The original guide has been moved to [GUIDE.md](https://raw.githubusercontent.com/willjasen/tailmox/refs/heads/main/GUIDE.md)

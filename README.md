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

1. Change to the /opt directory: `cd /opt`
2. Pull this repo: `git clone https://github.com/willjasen/tailmox`
2. Change into the install directory: `cd tailmox`
3. Make sure that the script is executable: `chmod +x tailmox.sh`
4. Run the script: `./tailmox.sh`

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
It opens the same interactive workflow, including input collection, mandatory dry
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

Tailmox installs a lightweight monitoring interface as `tailmox-monitor.service`. It listens locally on port `8088` and is mounted through Tailscale Serve on HTTPS port `8088` at `/monitor`, so each node can show its own health from:

- `https://HOSTNAME.MAGICDNS_NAME.ts.net:8088/monitor/`
- `https://tailmox.MAGICDNS_NAME.ts.net:8088/monitor/`

The monitor includes corosync-specific details: whether the `corosync` service is active and enabled, whether the cluster is quorate, expected and current votes, corosync transport, configured and active member information from `corosync-cmapctl`, quorum node details from `corosync-quorumtool`, cluster member count over time, link-quality history for each peer, and recent `corosync` journal entries. Configured cluster members that are not active in corosync are shown as offline.

The same page is also the Tailmox control console. A signed-in Tailscale user
can run `tailmox stage`, install, restart, or uninstall `tailmox analytics`, run
the local test suite, and create a root-only configuration backup. Only one
workflow runs at a time and its output opens in a pop-up dialog. Close it with
Close or Escape, and reopen it with View workflow output. Closing the dialog
does not stop the workflow. A Tailscale auth
key entered for staging is passed through a private process environment, is
cleared from the browser field immediately, and is never placed in command
arguments or saved in the clustered configuration.

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

The older periodic test collector is still available as `tailmox analytics`. It records `tailmox test` results, latency summaries, and cluster samples in SQLite, and can be installed as `tailmox-analytics.service` with `tailmox analytics install`.

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
- stores periodic `tailmox test` results in SQLite
- exposes an event stream for the older dashboard assets in `web/`

There are further scripts related to testing in the "test-env" folder.

---

### 🏁 Afterword 🏁

This project has been a fun experiment of mine after seeing many say that it could never work and I like a challenge myself. It's received much more attention that I had expected it to and I'm pleased to see it! It seems that others are also interested in the idea of geographically distanced hosts and the ability to move around virtual machines and containers with less effort!

---
---

The original guide has been moved to [GUIDE.md](https://raw.githubusercontent.com/willjasen/tailmox/refs/heads/main/GUIDE.md)

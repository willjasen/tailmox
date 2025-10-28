### 🗺️ The Guide 🗺️

The [gist](https://gist.github.com/willjasen/df71ca4ec635211d83cdc18fe7f658ca) guide is now being procured below. The gist at its original location will no longer be updated.

---
---

### 📝 Prologue 📝
- This example uses "host1" and "host2" as example names for the hosts
- This example uses "example-test.ts.net" as a Tailscale MagicDNS domain
- The Tailscale IP for host1 is 100.64.1.1
- The Tailscale IP for host2 is 100.64.2.2

---

### 📋 Steps 📋
1. Setup two Proxmox hosts
2. Install Tailscale on the hosts:
	```curl -fsSL https://tailscale.com/install.sh | sh;```
3. Update /etc/hosts on all hosts with the proper host entries:
	- ```100.64.1.1 host1.example-test.ts.net host1```
	- ```100.64.2.2 host2.example-test.ts.net host2```
  
4. Since DNS queries will be served via Tailscale, ensure that your global DNS server via Tailscale can resolve host1 as 100.64.1.1 and host2 as 100.64.2.2
5. If you need to allow for the traffic within your Tailscale ACL: allow TCP 22, TCP 443, TCP 8006, and UDP 5405 - 5412; example as follows:
	```// allow Proxmox clustering
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host1:22"]},   // SSH
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host2:22"]},   // SSH
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host1:443"]}, // Proxmox web
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host2:443"]}, // Proxmox web
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host1:8006"]}, // Proxmox web
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host2:8006"]}, // Proxmox web
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5405"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5406"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5407"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5408"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5409"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5410"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5411"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host1:5412"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5405"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5406"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5407"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5408"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5409"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5410"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5411"]}, // corosync
	{"action": "accept", "proto": "udp", "src": ["host1", "host2"], "dst": ["host2:5412"]}, // corosync
    ```
6. Create the cluster using host1 (so that host2 has a cluster to join to)

7. In order for clustering to initially succeed, all cluster members must only have a link0 within corosync associated with Tailscale (if any other links exists within corosync, they must be temporarily removed for this initial cluster member addition to succeed); to have host2 join the cluster of host1, then run from host2 (replacing "magic-dns" with your Magic DNS domain slug):
	```pvecm add host1.magic-dns.ts.net --link0 100.64.2.2```
8. You should SSH in from host1 to host2 and vice versa; if this isn't done, then tasks like migrations and replications may not work until performed:
	- ```ssh host1```
	- ```ssh host2```
9. That should do it! Test, test, test!

To add a third member to the cluster (and so on), repeat these similar steps.

---

## 🔧 Troubleshooting 🔧

### Adding to the Cluster

Should clustering not be successful, you'll need to do two things:

1. Remove the err'd member from host1 by running:
	```pvecm delnode host2```
2. Reset clustering on host2 by running:
	```systemctl stop pve-cluster corosync; pmxcfs -l; rm -rf /etc/corosync/*; rm /etc/pve/corosync.conf; killall pmxcfs; systemctl start pve-cluster; pvecm updatecerts;```

Then try again.

### Maintaining Quorum

You may find in a large cluster (5 or more members) that features like the web interface won't work properly between cluster members. This is likely because quorum via corosync hasn't been properly achieved. The file at `/etc/pve/.members` may show a node or nodes as `"online": 1` indicating that it is online and communicable to in some form, but the `ip` value never shows. In circumstances where one of the members has an underperforming network connection in relation to the other cluster members (particularly in reference to a high latency measured in 200-300 ms), then corosync should be stopped and disabled on that member temporarily. To do that, run `systemctl stop corosync; systemctl disable corosync;`. To enable and start it again, run `systemctl enable corosync; systemctl start corosync;`.

---
*END OF GUIDE*
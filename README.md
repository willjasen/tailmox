# tailmox
cluster proxmox over tailscale

### ‼️ DANGER ‼️ 

In the interest of complete transparency, if you follow this guide or use this project, there’s a very minuscule but non-zero chance that you may violate the Bekenstein bound, at which the resulting black hole may swallow the earth whole. You have been warned!

---

### ⚠️ WARNING ⚠️
- This project is for development, testing, and research purposes only. This guide comes with no guarantee or warranty that these steps will work within your environment. Should you attempt within a production environment, any negative outcomes are not the fault of this guide or its author.
- This project was tested on Proxmox 8 (Debian 12).

---

### 📖 Overview

This project was originally started as a [gist](https://gist.github.com/willjasen/df71ca4ec635211d83cdc18fe7f658ca) guide on how to cluster Proxmox servers together using Tailscale so that hosts not physically located together could participate in a cluster. While a how-to is great, being able to replicate the steps in code and sharing that with others was always the goal.

---

### 😮 Controversy 😮

Many, many people will expend a lot of effort and noise to proclaim either that this architecture is impossible and will never work. It is often cited that corosync requires a super extra-low amount of latency in order to work properly. While corosync is latency sensitive, there is some freedom within that constraint. My experience with issues clustering in this way has been very minimal, but I am only me, with a handful of Proxmox hosts in a case study of one.

---

### 🖥️ Usage 🖥️

`tailmox.sh` can be run without any parameters, but if the host is not logged into Tailscale, then when the script performs `tailscale up`, Tailscale will provide a link to use to login with.

In order to make the Tailscale functions easier to handle, `tailmox.sh` accepts the "--auth-key" parameter, followed by a Tailscale auth key, which can be generated via their [Keys](https://login.tailscale.com/admin/settings/keys) page. It is recommended that key generated is reusable.

---

### 🤓 The Scripts 🤓

`tailmox.sh` -  this is the main script of the project
- checks that the host is Proxmox v8, installs dependencies and Tailscale, then starts Tailscale
- once Tailscale is running, the host will generate a certificate from Tailscale (to be used with the web interface/API)
- it will then retrieve other Tailscale machines with tag of "tailmox", then check if it can reach them via ping (ICMP) and TCP 8006 (HTTPS for Proxmox); if these checks do not pass, the script will exit as these are required for Proxmox clustering
- after the checks pass, the host will check if it is in a cluster; if it is not, it will check the other Tailscale machines with the tag of "tailmox" to see if they are part of a cluster; when it finds a matching host in a cluster, it will then attempt to join to the cluster using it; if another host isn't found, then a new cluster will be prompted to be created

`revert_test_vms.sh` - this is a testing script used to revert VMs being tested with
- I currently have three Proxmox VMs with Proxmox installed inside of each
- this script reverts each VM to a snapshot named "ready-for-testing" that was taken after dependencies are installed and the "tailmox" project was cloned into the VM, but right before the script has been run for the first time
- this allows testing `tailmox.sh` easily by reverting the VMs before the clustering processes and data have been created

---
---

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
5. If you need to allow for the traffic within your Tailscale ACL, allow TCP 22, TCP 8006, and UDP 5405 - 5412; example as follows:
	```// allow Proxmox clustering
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host1:22"]},   // SSH
	{"action": "accept", "proto": "tcp", "src": ["host1", "host2"], "dst": ["host2:22"]},   // SSH
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

## 💭 After Thoughts 💭

In order to use a Tailscale certificate with your host's web services, please see [tailscale-cert-services/proxmox-cert.sh](https://github.com/willjasen/tailscale-cert-services/blob/main/proxmox-cert.sh)

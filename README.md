# tailmox
cluster proxmox over tailscale

![GitHub Release](https://img.shields.io/github/v/release/willjasen/tailmox) -- ![GitHub Repo stars](https://img.shields.io/github/stars/willjasen/tailmox)

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

Because Tailscale allows for an access control list, if you use an ACL, then it should be prepared for cluster communications. The script will check that TCP 22, TCP 443, and TCP 8006 are available on all other hosts and will exit if not.

This script uses the tag of "tailmox" to determine which Tailscale machines are using this project to establish a cluster together. The "tailmox" tag should be specified under "tagOwners":
```
"tagOwners": {
	"tag:tailmox": [
		"autogroup:owner",
	],
}
```

Proxmox clustering requires TCP 22, TCP 443, TCP 8006, and UDP 5405 through 5412. Using the now established tag of "tailmox", we can create access control rules that allow all hosts with this tag to communicate with all other hosts with the tag as well. There is also an included rule at the end to allow all devices within the tailnet to access the web interface of the hosts with the tag.
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

---

### 🧪 Testing 🧪

This project has been tested to successfully join a cluster of three Proxmox v8 and v9 hosts together into a cluster via Tailscale. It has been tested up to the point of achieving this goal and not further. It is possible that further testing with other features related to clustering (like high availability and ZFS replication) may not work, though bugs can be patched appropriately when known.

If planning to run `tailmox.sh` many times in a short period, it is recommended that staging is performed first. By supplying the "--staging" parameter, `tailmox.sh` will install Tailscale and retrieve the Tailscale certificate and then stop. The purpose of staging is to prevent many requests to Tailscale for the same certificate in rapid succession. If staging is not performed, it is possible that the step to setup the certificate will take a very long time, which is not optimal when running many tests centered around setting up the Proxmox cluster.

`revert_test_vms.sh` is used to revert VMs installed with Proxmox to a state before the `tailmox.sh` script has been first run and erase any clustering processes and data within those VMs, to quickly restore to a state in which the `tailmox.sh` script can be tried again.

---

### 🤓 The Scripts 🤓

`tailmox.sh` -  this is the main script of the project
- checks that the host is Proxmox v8 or v9, installs dependencies and Tailscale, then starts Tailscale
- once Tailscale is running, the host will generate a certificate from Tailscale (to be used with the web interface/API)
- it will then retrieve other Tailscale machines with tag of "tailmox", then check if it can reach them via ping (ICMP) and TCP 8006 (HTTPS for Proxmox); if these checks do not pass, the script will exit as these are required for Proxmox clustering
- after the checks pass, the host will check if it is in a cluster; if it is not, it will check the other Tailscale machines with the tag of "tailmox" to see if they are part of a cluster; when it finds a matching host in a cluster, it will then attempt to join to the cluster using it; if another host isn't found, then a new cluster will be prompted to be created

`revert_test_vms.sh` - this is a testing script used to revert VMs being tested with
- I currently have three Proxmox VMs with Proxmox installed inside of each
- this script reverts each VM to a snapshot named "ready-for-testing" that was taken after dependencies are installed and the "tailmox" project was cloned into the VM, but right before the script has been run for the first time
- this allows testing `tailmox.sh` easily by reverting the VMs before the clustering processes and data have been created

---

### 🏁 Afterword 🏁

This project has been a fun experiment of mine after seeing many say that it could never work and I like a challenge myself. It's received much more attention that I had expected it to and I'm pleased to see it!

---
---

The original guide has been moved to [GUIDE.md](https://raw.githubusercontent.com/willjasen/tailmox/refs/heads/main/GUIDE.md)

---
---

### 🗣️ SOME THOUGHTS ON MODERATION 🗣️

The [Reddit post](https://www.reddit.com/r/Proxmox/comments/1k3ykbu/introducing_tailmox_cluster_proxmox_via_tailscale/) I made on “r/Proxmox” to announce this project seems to have generated some interest in this idea, which I am very thankful for. I have received more activity and stars on this project in less than 24 hours than my now 2nd most starred project has that I began in 2014.

Unfortunately, the post was locked after I was told by a moderator account to be respectful after replying civilly to another member who used an expletive twice in replying to me (leaving me at no fault, with the same said member poking fun at me in a separate post by another user from the previous day). By locking the post, those with genuine questions and comments are prevented from doing so. While I will state that locking the post is within their moderation powers to perform, it doesn’t make it palatable or correct, especially considering who is at fault, and being that this is within the open source community - and I fervently and firmly disagree with their decision.

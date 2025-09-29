# Recovering from Split Brain Scenarios

## Introduction

I am writing this note after a recent experience in which I was encountered with a split brain scenario within my 7 host Proxmox cluster communicating over Tailscale. To ease concerns, I do not believe that the split brain was a direct result of tailmox or by clustering Proxmox servers over Tailscale in general. The style and format here relates my own experience and steps of thinking in resolving the problem in combination with some of the technical workings and aspects of Proxmox clustering, and corosync by association. I hope that this information is useful to those who commonly work within environments that are Proxmox clusters, regardless of whether they are communicating via Tailscale or not.

Before proceeding further, please keep in mind that this is penned as being my own experience within my own environment. While I hope that this information provides insight and is useful - should you find yourself in a similar predicatment, please do not rely on this as a complete and total reflection of your own situation without careful consideration. It is trivial to mess up a Proxmox cluster when manually interacting with its pieces if understanding is not acquired and caution is not taken.

## The Events

The issue as it initially presented itself to me was that I powered on a server that I usually keep offline due to power usage reasons, though the server had been successfully on about a day before. Because I don't believe that giving it out is any risk to my security - PVE1 is its name. This server in question came up okay, but when I powered on another server that I also keep offline regularly (its name being PVE2), I was unable to access most pages within the web interface of the cluster, in particular, the Replications page in which I was mostly interested in at that time.

In an attempt to alleviate this situation, I tried adding a second ring within corosync, as I had previously had this kind of configuration a while back but with a growing number of servers and the consideration needed when manually adding another host to the cluster, I had abandoned for the sake of less effort, though I thought it originally as a good idea. With the gift of after thought of the situation after, I believe I can point to this as causing what was to come next.

To put forth forwardly, the proceeding issue evolved into a split brain scenario between two servers - PVE2 and Exeggutor. Yes, if you're familiar with Pokémon... #103, and this name derived from an inside Star Wars joke - nerds can have fun too. I spent about ten hours in total digging down deep within my environment to find what exactly was going wrong and how I could recover from it.

My initial attempts at fixing the second arisen issue were that maybe I needed to restart the systemd services that Proxmox utilizes in some particular correct order that might resolve what was happening, but that was of no avail. From there, it became a game of comparing files and logs related to Proxmox clustering and corosync.  Admittedly and like any sane person would do these days, I utilized AI chat tools to help quickly analyze the long lines of logging text and to hopefully find a discrepancy that I could run with. While they did offer a few avenues to investigate here and there, there became a point in which the responses I received were repeating and offering no new ideas.

I kept looking amongst the configuration files and logs and I eventually was able to come up with what was the best lead yet - the cluster config version in `corosync.conf` and the ring ID as noted in the output of `pvecm status`. I think most people who have delved into the pieces of how clustering within Proxmox is put together are aware of the cluster config version within `corosync.conf`, but in case you aren't, here is a direct example as it exists within my environment:

```
...
totem {
  cluster_name: willjasen
  config_version: 51
  interface {
    knet_link_priority: 20
    linknumber: 0
    ringnumber: 0
  }
  ip_version: ipv4-6
  link_mode: passive
  secauth: on
  version: 2
}
...
```

Anytime there are changes or updates to the corosync clustering service, the value of `totem.config_version` must be incremented. The hosts within a Proxmox cluster will receive this new configuration, notice the higher number, and begin using the new configuration for its corosync service.

This `config_version` value however does not act as the final voice of what a cluster member should be using for its configuration! The more important piece is the ring ID that a host has. There are two parts to the ring ID as seen below, separated by a dot. It is best to think of this ID similar to semantic software versioning in such that the first part represents a major number while the second part represent a minor number (or in this case, hexadecimal digits). For example, a ring ID of `1.10` is less than that of `2.5` and a ring ID of `3.1a` is less than that of `3.b2` - the leading major part holds weight first, followed by the minor part.

```
root@pve2:/etc# pvecm status
Cluster information
-------------------
Name:             willjasen
Config Version:   51
Transport:        knet
Secure auth:      on

Quorum information
------------------
Date:             Sat May 31 23:49:13 2025
Quorum provider:  corosync_votequorum
Nodes:            6
Node ID:          0x00000001
Ring ID:          1.3b0bd
Quorate:          Yes

...
```

What I noticed eventually was that the ring IDs for the hosts that were properly clustering together where

... to continue ...

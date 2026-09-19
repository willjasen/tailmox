# Deploying a Proxmox VM for Testing

### 📖 Overview 📖

To faciliate in quick testing, I have developed a way to create a testing environment such that multiple semi-preconfigured Proxmox hosts that are ready to test with can be setup easily by virtualizing Proxmox within Proxmox.

---

### ✏️ Preparation ✏️

The `create-vm-template.sh` script downloads the preconfigured image from an IPFS gateway, verifies it, and sets it up as a template named `tailmox-template` in Proxmox. It can also create linked clones of the template:

> **Important: current Tailmox test image source**
>
> The compressed image used by the default test template is permanently
> identified by this IPFS CID:
>
> ```text
> bafybeig3k2tpv33pcoveatirpbio4qgr7kltpnbau3ftlgpgi7emombzqy
> ```
>
> The uncompressed image CID is:
>
> ```text
> bafybeidxzo6vw73phymnsvqeb7ltulw3xj6yvrp4etd4vwcr7wweb6foya
> ```
>
> These values are also recorded in `template.json` and must not be changed
> for an existing image release. Record new CIDs as a new image release when
> publishing a replacement image.

```bash
./create-vm-template.sh \
  --vmid 50000 \
  --storage local-zfs \
  --bridge vlan3 \
  --clone-count 3 \
  --clone-vmid-start 50001
```

Run this command as root on a Proxmox node. If `--storage` is omitted, the script chooses the first enabled, active storage that supports VM images. It validates the selected storage and bridge before creating anything.

The standard test allocation is VM `50000` for `tailmox-template`. Linked
clone hostnames use the format `tailmox-t####`, where `####` is a random
four-character hexadecimal suffix.
The helper checks that every requested VM ID and name is available before it
creates the template or any clone.

From a local Tailmox checkout, set up the image on `pve-a2` with:

```bash
./tailmox vm-image
```

This connects with the local SSH key as `root`, copies only the image helpers to a temporary directory, runs the same checked template builder, and removes the temporary files afterward. Builder options pass through unchanged, for example `./tailmox vm-image --storage local-zfs --bridge vlan3 --clone-count 3`. Use `--host HOST` or set `TAILMOX_PVE_HOST` to target a different Proxmox host.

Use `--vmid 50000 --clone-vmid-start 50001` when a deployment requires an exact sequential template and clone ID range. The helper validates every requested ID before creating the template.

To create the linked clones remotely through the Proxmox API, first create the template on a Proxmox node, then run:

```bash
export PVE_API_TOKEN_ID='USER@REALM!TOKEN_ID'
export PVE_API_TOKEN_SECRET='TOKEN_SECRET'

./deploy-vms-api.sh \
  --api-url https://pve4.example.ts.net \
  --node pve4 \
  --template tailmox-template \
  --count 3 \
  --vmid-start 50001
```

The API helper prompts for any credentials that are not supplied through the environment. It creates stopped linked clones with random `tailmox-t####` hostnames by default. Every clone receives a `ready-for-testing` snapshot immediately after creation and before it can be started. Linked clones inherit the template storage. Use `--full --storage NAME` to place full clones on another storage, `--start` to start the clones after their snapshots exist, or `--bridge` to override the inherited template network.

The API helper defaults to clone IDs `50001` through `50003` when
`--count 3` is used. It checks all requested IDs and generated names before
creating any clone; use `--vmid-start` to choose a different contiguous range.
For multiple isolated test environments, allocate another contiguous range,
for example:

```bash
./deploy-vms-api.sh \
  --api-url https://pve4.example.ts.net \
  --node pve4 \
  --template tailmox-template \
  --count 3 \
  --vmid-start 50011
```

This creates VMs `50011`, `50012`, and `50013` with random `tailmox-t####`
hostnames. Always check the full requested ID and name range before
deployment; the helper refuses any collision.

Each linked clone receives a Proxmox note describing its VM ID, hostname,
source template, source image IPFS CID, Proxmox node, actual VirtIO bridge,
`/opt/tailmox` `dev` checkout, `dev-tailmox` service label, and
`ready-for-testing` recovery snapshot. The API helper uses the current
compressed CID by default; pass `--template-cid` when deploying a template
built from another image release.

To ensure that the linked clones can get online, review the network adapter settings within each VM. The network adapter uses `vlan3` by default, but your environment may be different.

The local template helper uses the `host` CPU type so nested virtualization is available and disables VM autostart by default. Use `--cpu TYPE` or `--onboot 1` to override those settings.

The default template resources are 2 vCPUs and 2048 MiB (2 GiB) of RAM;
linked clones inherit these settings.

Test VMs are configured with `serial0: socket` and `vga: std`, providing both
the graphical VGA display and `qm terminal <VMID>` serial access. The guest
image must also enable `serial-getty@ttyS0.service`; changing the Proxmox VM
settings alone does not create a serial login prompt.

For a newly installed nested Proxmox guest, run the host-side helper on the
outer Proxmox node:

```bash
./configure-proxmox-test-vm.sh --vmid 50051 --bridge vlan3 --start
```

It configures the VM's serial socket, VGA display, QEMU guest agent, and outer
network bridge. After logging into the nested guest, run the guest-side helper
as root:

```bash
./prepare-proxmox-test-guest.sh
```

It runs `apt-get update`, installs `qemu-guest-agent`, `git`, `jq`, and
`expect` plus `isc-dhcp-client` and `resolvconf`. It configures the nested
`vmbr0` bridge for DHCP, delegates `/etc/resolv.conf` to `resolvconf` so DNS
also comes from DHCP, then enables and starts `qemu-guest-agent.service`,
`serial-getty@ttyS0.service`, and `resolvconf.service`. Both helpers are
idempotent and stop before template conversion; run `qm template <VMID>` only
after verifying the guest.

Both deployment helpers add Proxmox Notes automatically. Imported templates are identified as stopped development sources, and linked clones record their source template and `ready-for-testing` recovery point.

Boot a new linked clone (the default credentials are `root` and
`tailmox-test`), copy `prepare-linked-clone.sh` into it, and run:

```bash
./prepare-linked-clone.sh --hostname tailmox-tabcd
reboot
```

The helper generates and reports a unique 16-character alphanumeric root
password for that clone. Pass `--root-password VALUE` to choose a 12–24
character alphanumeric password instead. Store reported passwords securely;
they are not written to the image, repository, or Proxmox notes.

The preparation helper converts the image's static `192.168.123.90` network
configuration to DHCP, installs the DHCP client and `resolvconf` when
necessary, delegates `/etc/resolv.conf` to the DHCP-managed resolver, removes
the stale image hostname from `/etc/hosts`, and deploys the latest `dev` branch
to `/opt/tailmox`. It also sets the shared Tailscale service label to
`dev-tailmox` and initializes `/usr/local/bin/tailmox`. It is safe to rerun on
an already-prepared clone, but refuses to update a dirty Git checkout or an
unrecognized network configuration. It does not authenticate Tailscale or
create or join a Proxmox cluster.

The guest bridge remains named `vmbr0` inside the nested Proxmox installation.
Its virtual NIC should be attached to the Proxmox host bridge `vlan3`.

The deployment helpers create the initial `ready-for-testing` snapshot automatically while each VM is stopped. This snapshot name is used by the `revert-test-vms.sh` script.

You are now ready to run/test the main script: `cd /opt/tailmox; git switch main; git pull --quiet; /opt/tailmox/tailmox.sh;`

Be sure to include the "--auth-key" parameter as well.

---

### 🤓 The Scripts 🤓

`test-env/create-vm-template.sh` - creates a VM template from the downloaded image and can create local linked clones

`test-env/setup-vm-image.sh` - stages and runs the template builder on `pve-a2` (or another selected Proxmox host) from a local checkout

`test-env/prepare-linked-clone.sh` - prepares a newly booted clone with DHCP, a unique hostname, and the latest Tailmox development branch

`test-env/prepare-linked-clone-agent.sh` - applies the same DHCP, hostname,
and branch preparation through the Proxmox guest agent when a clone still has
the image's static `192.168.123.90` address and cannot yet be reached by SSH.
For VM-ID-based environments, run it on the Proxmox host with
`--vmid 50011`; it defaults the guest hostname to a random `tailmox-t####` name.

`test-env/IMAGE-BUILD-NOTES.md` - records the next-image checklist and the image/preparation-helper versioning contract

`test-env/download-template.sh` - used to download the disk image of a previously configured Proxmox host that is ready for testing with Tailmox

`test-env/deploy-vms-api.sh` - creates linked clones of an existing template through the Proxmox API

`test-env/revert-test-vms.sh` - used to revert VMs being tested with

I currently have three Proxmox VMs with Proxmox installed inside of each. I am able to revert each VM to a snapshot named "ready-for-testing" that was taken after dependencies are installed and the "tailmox" project was cloned into the VM, but right before the script has been run for the first time. This allows testing `tailmox.sh` easily by reverting the VMs before the clustering processes and data have been created.

---

<img width="500" height="323" alt="yo dawg" src="https://github.com/user-attachments/assets/e3e3086b-7d70-4b73-8c31-ac40a33484d1" />

# Deploying a Proxmox VM for Testing

### 📖 Overview 📖

To faciliate in quick testing, I have developed a way to create a testing environment such that multiple semi-preconfigured Proxmox hosts that are ready to test with can be setup easily by virtualizing Proxmox within Proxmox.

---

### ✏️ Preparation ✏️

The `create-vm-template.sh` script downloads the preconfigured image from an IPFS gateway, verifies it, and sets it up as a template named `tailmox-template` in Proxmox. It can also create linked clones of the template:

```bash
./create-vm-template.sh \
  --storage local-zfs \
  --bridge vmbr0 \
  --clone-count 3
```

Run this command as root on a Proxmox node. If `--storage` is omitted, the script chooses the first enabled, active storage that supports VM images. It validates the selected storage and bridge before creating anything.

From a local Tailmox checkout, set up the image on `pve-a2` with:

```bash
./tailmox vm-image
```

This connects with the local SSH key as `root`, copies only the image helpers to a temporary directory, runs the same checked template builder, and removes the temporary files afterward. Builder options pass through unchanged, for example `./tailmox vm-image --storage local-zfs --bridge vmbr0 --clone-count 3`. Use `--host HOST` or set `TAILMOX_PVE_HOST` to target a different Proxmox host.

Use `--vmid 50000 --clone-vmid-start 50001` when a deployment requires an exact sequential template and clone ID range. The helper validates every requested ID before creating the template.

To create the linked clones remotely through the Proxmox API, first create the template on a Proxmox node, then run:

```bash
export PVE_API_TOKEN_ID='USER@REALM!TOKEN_ID'
export PVE_API_TOKEN_SECRET='TOKEN_SECRET'

./deploy-vms-api.sh \
  --api-url https://pve4.example.ts.net \
  --node pve4 \
  --template tailmox-template \
  --count 3
```

The API helper prompts for any credentials that are not supplied through the environment. It creates stopped linked clones named `tailmox1`, `tailmox2`, and `tailmox3` by default. Every clone receives a `ready-for-testing` snapshot immediately after creation and before it can be started. Linked clones inherit the template storage. Use `--full --storage NAME` to place full clones on another storage, `--start` to start the clones after their snapshots exist, or `--bridge` to override the inherited template network.

To ensure that the linked clones can get online, review the network adapter settings within each VM. The network adapter uses `vmbr0` with no VLAN by default, but your environment may be different.

The local template helper uses the `host` CPU type so nested virtualization is available and disables VM autostart by default. Use `--cpu TYPE` or `--onboot 1` to override those settings.

Both deployment helpers add Proxmox Notes automatically. Imported templates are identified as stopped development sources, and linked clones record their source template and `ready-for-testing` recovery point.

Boot a new linked clone (the default credentials are `root` and
`tailmox-test`), copy `prepare-linked-clone.sh` into it, and run:

```bash
./prepare-linked-clone.sh --hostname tailmox1
reboot
```

The preparation helper converts the image's static `192.168.123.90` network
configuration to DHCP, installs the DHCP client when necessary, removes the
stale image hostname from `/etc/hosts`, and deploys the latest `dev` branch to
`/opt/tailmox`. It also sets the shared Tailscale service label to
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

`test-env/IMAGE-BUILD-NOTES.md` - records the next-image checklist and the image/preparation-helper versioning contract

`test-env/download-template.sh` - used to download the disk image of a previously configured Proxmox host that is ready for testing with Tailmox

`test-env/deploy-vms-api.sh` - creates linked clones of an existing template through the Proxmox API

`test-env/revert-test-vms.sh` - used to revert VMs being tested with

I currently have three Proxmox VMs with Proxmox installed inside of each. I am able to revert each VM to a snapshot named "ready-for-testing" that was taken after dependencies are installed and the "tailmox" project was cloned into the VM, but right before the script has been run for the first time. This allows testing `tailmox.sh` easily by reverting the VMs before the clustering processes and data have been created.

---

<img width="500" height="323" alt="yo dawg" src="https://github.com/user-attachments/assets/e3e3086b-7d70-4b73-8c31-ac40a33484d1" />

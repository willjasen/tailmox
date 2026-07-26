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

The API helper prompts for any credentials that are not supplied through the environment. It creates stopped linked clones named `tailmox1`, `tailmox2`, and `tailmox3` by default. Use `--full` for full clones, `--start` to start the clones, and `--storage` or `--bridge` to override the inherited template settings.

To ensure that the linked clones can get online, review the network adapter settings within each VM. The network adapter uses `vmbr0` with no VLAN by default, but your environment may be different.

Boot up each linked clone VM (the default credentials are "root" and "tailmox-test"), then make the following changes:

 - edit the IP address of the host to one that works within your environment (it is "192.168.123.90" by default)
 - edit `/etc/hostname` to a unique hostname within the Tailmox cluster (example: tailmox1)
 - edit `/etc/hosts` to reflect the new IP and hostname (example: "10.2.3.10 tailmox1.local tailmox1")

Once you have verified online connectivity, shutdown the VM and create a snapshot named "ready-for-testing". This snapshot name is used by the `revert-test-vms.sh` script.

You are now ready to run/test the main script: `cd /opt/tailmox; git switch main; git pull --quiet; /opt/tailmox/tailmox.sh;`

Be sure to include the "--auth-key" parameter as well.

---

### 🤓 The Scripts 🤓

`test-env/create-vm-template.sh` - creates a VM template from the downloaded image and can create local linked clones

`test-env/download-template.sh` - used to download the disk image of a previously configured Proxmox host that is ready for testing with Tailmox

`test-env/deploy-vms-api.sh` - creates linked clones of an existing template through the Proxmox API

`test-env/revert-test-vms.sh` - used to revert VMs being tested with

I currently have three Proxmox VMs with Proxmox installed inside of each. I am able to revert each VM to a snapshot named "ready-for-testing" that was taken after dependencies are installed and the "tailmox" project was cloned into the VM, but right before the script has been run for the first time. This allows testing `tailmox.sh` easily by reverting the VMs before the clustering processes and data have been created.

---

<img width="500" height="323" alt="yo dawg" src="https://github.com/user-attachments/assets/e3e3086b-7d70-4b73-8c31-ac40a33484d1" />

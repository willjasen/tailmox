# Deploying a Proxmox VM for Testing

### 🤓 The Scripts 🤓

`test-env/create-vm-template.sh` - used to create a VM template using the downloaded template image

`test-env/download-template.sh` - used to download the disk image of a previously configured Proxmox host that is ready for testing with Tailmox

`test-env/revert-test-vms.sh` - used to revert VMs being tested with
- I currently have three Proxmox VMs with Proxmox installed inside of each
- this script reverts each VM to a snapshot named "ready-for-testing" that was taken after dependencies are installed and the "tailmox" project was cloned into the VM, but right before the script has been run for the first time
- this allows testing `tailmox.sh` easily by reverting the VMs before the clustering processes and data have been created

---

<img width="500" height="323" alt="yo dawg" src="https://github.com/user-attachments/assets/e3e3086b-7d70-4b73-8c31-ac40a33484d1" />

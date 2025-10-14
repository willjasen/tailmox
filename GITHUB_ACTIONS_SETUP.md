# Tailmox GitHub Actions Setup Guide

This document provides step-by-step instructions for integrating GitHub Actions with your Tailmox infrastructure using the Tailscale GitHub Action.

## 🔧 Prerequisites

Before setting up GitHub Actions, ensure you have:

1. **A Tailscale account** with Owner, Admin, or Network admin permissions
2. **GitHub repository admin access** for setting up secrets and workflows
3. **At least one configured Tailscale tag** (we'll use `tag:ci` for this example)
4. **Existing Tailmox infrastructure** with hosts tagged as `tag:tailmox`

## 🔐 Step 1: Create Tailscale OAuth Client

1. Go to the [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth)
2. Click "Generate OAuth client"
3. Set the following scopes:
   - ✅ `auth_keys` (required for creating ephemeral nodes)
4. Copy the Client ID and Client secret (you'll need these for GitHub secrets)

## 🏷️ Step 2: Configure Tailscale ACL

Update your Tailscale ACL policy to allow GitHub Actions runners to access your Proxmox hosts:

```json
{
  "tagOwners": {
    "tag:ci": ["autogroup:owner"],
    "tag:tailmox": ["autogroup:owner"]
  },
  "acls": [
    // Existing rules...
    
    // Allow GitHub Actions CI runners to access Tailmox hosts
    {
      "action": "accept",
      "proto": "tcp",
      "src": ["tag:ci"],
      "dst": ["tag:tailmox:22,8006"]
    },
    {
      "action": "accept", 
      "proto": "udp",
      "src": ["tag:ci"],
      "dst": ["tag:tailmox:5405-5412"]
    }
  ]
}
```

## 🔑 Step 3: Set Up GitHub Repository Secrets

In your GitHub repository, go to **Settings** → **Secrets and variables** → **Actions** and add:

### Required Secrets:
- `TS_OAUTH_CLIENT_ID`: Your Tailscale OAuth Client ID
- `TS_OAUTH_SECRET`: Your Tailscale OAuth Client secret

### Optional Secrets (for deployment workflows):
- `PROXMOX_HOST_IPS`: Comma-separated list of your Proxmox host Tailscale IPs or hostnames
  - Example: `100.64.1.1,100.64.1.2,host1.yourtailnet.ts.net`
- `PROXMOX_SSH_KEY`: SSH private key for accessing your Proxmox hosts
  - Generate with: `ssh-keygen -t ed25519 -C "github-actions"`
  - Add the public key to your Proxmox hosts' `~/.ssh/authorized_keys`

## 🚀 Step 4: Enable Workflows

The repository now includes several workflow files in `.github/workflows/`:

### 1. **test-tailmox.yml** - Automated Testing
- Runs on every push and pull request
- Tests script syntax with ShellCheck
- Validates basic connectivity through Tailscale

### 2. **deploy-to-proxmox.yml** - Secure Deployment
- Manual trigger workflow for deploying updates
- Connects to your Tailscale network securely
- Updates scripts on all Proxmox hosts

### 3. **cluster-health-check.yml** - Health Monitoring  
- Runs every 6 hours automatically
- Checks cluster status and generates reports
- Creates artifacts with health information

### 4. **docs-and-release.yml** - Documentation & Releases
- Generates documentation on releases
- Creates GitHub releases with installation guides

## 🔍 Step 5: Test the Setup

1. **Push a change** to your repository to trigger the test workflow
2. **Check the Actions tab** in your GitHub repository to see the workflow run
3. **Verify** that the Tailscale connection is established successfully

## 🛡️ Security Benefits

Using GitHub Actions with Tailscale provides:

- **Private network access**: GitHub runners connect to your private Tailscale network
- **No exposed ports**: Your Proxmox hosts don't need public internet access
- **Ephemeral connections**: Each workflow creates a temporary node that's automatically cleaned up
- **Encrypted traffic**: All communication uses WireGuard encryption
- **Access control**: Precise control over which resources can be accessed

## 📝 Customization

You can customize the workflows by:

- **Modifying triggers**: Change when workflows run (schedule, manual, etc.)
- **Adding notifications**: Integrate with Slack, Discord, or email
- **Extending checks**: Add more health monitoring or deployment steps
- **Environment-specific deployments**: Set up staging vs production environments

## 🔧 Troubleshooting

### Common Issues:

1. **"Connection refused" errors**: Check your Tailscale ACL configuration
2. **SSH authentication failures**: Verify your SSH key is properly configured
3. **Timeout issues**: Ensure your Proxmox hosts are online and accessible via Tailscale

### Debugging Steps:

1. Check workflow logs in the GitHub Actions tab
2. Verify Tailscale connectivity with the ping parameter
3. Test SSH access manually from a machine on your Tailscale network

## 📚 Additional Resources

- [Tailscale GitHub Action Documentation](https://tailscale.com/kb/1276/tailscale-github-action)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Tailscale ACL Reference](https://tailscale.com/kb/1337/policy-syntax)

For questions or issues, please open an issue in the repository or check the [Tailscale Community Forum](https://forum.tailscale.com/).
# AGENTS.md

## Project overview

Tailmox clusters Proxmox VE 8 and 9 hosts over Tailscale. The project is
primarily Bash and can modify networking, systemd services, Tailscale
configuration, and Proxmox cluster state.

Treat changes to installation, networking, authentication, clustering, storage,
and VM-management code as high risk.

## Repository layout

- `tailmox` — user-facing command dispatcher and test runner.
- `tailmox.sh` — main installer, web-terminal launcher, and clustering workflow.
- `tailmox-web.service` — systemd unit for the browser terminal.
- `tests/` — local shell tests using temporary directories and command mocks.
- `test-env/` — tooling for building and controlling nested Proxmox test VMs.
- `README.md` — current installation, usage, architecture, and ACL guidance.
- `GUIDE.md` — original/manual clustering guide.
- `VERSIONS.md` — release history.

## Working conventions

- Preserve compatibility with Bash and the existing script style.
- Quote variable expansions unless intentional word splitting is required.
- Prefer `[[ ... ]]` for Bash conditionals.
- Use `local` variables inside functions.
- Use `printf` for new output instead of relying on implementation-specific
  `echo` behavior.
- Return nonzero on failure and fail closed when host, peer, or network state is
  incomplete.
- Keep normal development runnable without root where practical.
- Make privileged paths configurable through `TAILMOX_*` environment variables
  so tests can redirect them into temporary directories.
- Never print, log, or commit Tailscale auth keys, Proxmox API tokens,
  passwords, or other credentials.
- Do not silently overwrite unrelated files, commands, services, or existing
  configuration.

## Safety requirements

Do not run the real clustering, staging, serving, VM deployment, template
creation, or VM-reversion workflows unless the user explicitly requests it and
confirms the intended Proxmox test environment.

In particular, treat these as potentially destructive or state-changing:

- `pvecm create`, `pvecm add`, and other cluster operations.
- Package installation and Tailscale authentication.
- Changes under `/etc`, `/var`, or `/usr/local/bin`.
- `systemctl` operations.
- `tailscale serve` configuration.
- Proxmox API calls.
- VM cloning, starting, stopping, snapshotting, or reverting.
- Storage-image downloads and template creation.

For ordinary development and verification, use mocks and temporary directories.
Do not assume the current machine is a disposable Proxmox host.

## Testing

Run the complete local suite from the repository root:

```bash
./tailmox test
```

The equivalent command is:

```bash
bash tailmox test
```

When changing behavior:

- Add or update a focused `tests/test-*.sh` test.
- Mock external commands such as `tailscale`, `pvecm`, `systemctl`, `curl`, and
  Proxmox utilities.
- Redirect logs, binaries, and systemd paths to temporary directories.
- Cover success, command failure, malformed output, incomplete state, and
  unsafe-state rejection where relevant.
- Verify that guarded operations are not called when preconditions fail.
- Ensure temporary files are removed with a trap.

Do not require a live Tailscale account, Proxmox installation, root access, or
internet connection for the local test suite.

## Documentation

Update `README.md` whenever commands, requirements, ports, ACL rules, supported
Proxmox versions, or user-visible behavior change.

Update `test-env/README.md` when test-environment workflows or parameters
change.

Update `VERSIONS.md` only when the change belongs to a planned release entry.

Keep examples consistent with the actual command interface:

```text
tailmox cluster
tailmox serve
tailmox stage
tailmox test
tailmox help
```

## Scope discipline

Keep changes focused on the requested behavior. Preserve unrelated user edits
and avoid broad formatting rewrites.

Before completing a change:

1. Run the relevant focused tests.
2. Run `./tailmox test`.
3. Review the diff for leaked credentials, hard-coded environment details,
   unsafe defaults, and unintended changes.
4. Clearly report any validation that could not be performed without a real
   Proxmox test environment.

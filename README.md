## Safe nested dev environments for untrusted software work

This is intended to be a safe environment for working with untrusted software.
Each separate concern (running the desktop, running LLMs, doing software dev)
is put into a separate guest VM running under a minimal host hypervisor.
These guests are designed to be rebuilt from trusted sources regularly
to contain any corruption that might occur.

### VM lifecycle

- **Desktop (vm 100)** and **LLM (vm 101)** auto-start at host first boot.
- **Dev template (vm 102)** is created once, provisioned, then converted to
  a PVE template (never auto-started).
- **Per-project dev VMs (vm 103+)** are created on demand from the desktop
  via `devctl`, cloned from the template. All created stopped; started/stopped
  on demand. See [Spec 07](specs/07-dev-fleet-lifecycle.md).

### Dev VM control (from desktop)

The desktop VM controls dev VM lifecycle through the host via `devctl`:

```bash
devctl add <project>    # create new dev VM from template (stopped)
devctl start <name>     # start a dev VM
devctl stop <name>      # graceful shutdown
devctl ssh <name>       # SSH to a running dev VM
```

### Dev VMs

Each software dev VM hosts one software project. Its network access is
severely constrained. The VM is primarily disk storage + Docker engine;
all dev tasks (AI harness, compiles, tests) run in ephemeral Docker
containers with bind-mounted disk access.

VM 103 (`dev-nested`) is dedicated to working on this repository itself
([Spec 08](specs/08-nested-dev-repo-vm.md)).

## Getting started

See [BUILDING.md](BUILDING.md) for build prerequisites, one-time setup, the
ISO build sequence, and deployment instructions.

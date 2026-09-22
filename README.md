## Safe nested dev environments for untrusted software work

This is intended to be a safe environment for working with untrusted software.
Each separate concern (running the desktop, running LLMs, doing software dev)
is put into a separate guest VM running under a minimal host hypervisor.
These guests are designed to be rebuilt from trusted sources regularly
to contain any corruption that might occur.

Each software dev VM is intended to host only one software project.
Its network access will be severely constrained.
Even so, the VM is intended to be primarily disk storage and docker engine,
with all development tasks (running an AI harness, doing compiles, etc)
delegated to ephemeral docker instances (often working with bind-mounted disk access).

# Discoveries

Running log of significant diagnoses: what broke, what was ruled out and
how, what it was, and what remains open. Newest first. Each entry should
let a future reader distinguish established fact from prime suspect.

## 2026-10-06 — Installer kernel oopses in `ovl_iterate_merged` (CVE-2026-53174 family)

**Symptom.** Ubuntu 26.04 server installs oopsed intermittently during
unpack, killing `rsync`, `unxz`, or `ubuntu-drivers` with `note: <proc>
exited with irqs disabled`, sometimes hanging afterward. Seen on both
guests across many attempts; fatality varied (a dead `rsync` during
`stage-extract` kills the install, a dead `ubuntu-drivers` does not).

**Ruled out, with evidence:** host RAM (27 clean memtest86+ passes over
32 GB); installer media (md5 self-check clean); thin-pool exhaustion
(`data` at 4%); host kernel and microcode (fresh 7.0.14 + `0xf8`, oopses on
both 7.0.2 and 7.0.14); install seeds (valid, parsed, network proven);
dGPU/`nouveau` (oopses with no GPU attached); `kvm=off` args (oopses without
them); wrong-disk installs (separate, fixed issue).

**Finding.** Full serial-captured traces show the same fault twice:
`getdents64` → `iterate_dir` → `shared_ovl_iterate` → `ovl_iterate` →
`ovl_iterate_merged+0x1d8`, faulting on the identical wild address
(`ffffffff8d7a3050`) both times. Deterministic across boots — not hardware.
This is the shape of CVE-2026-53174 (`ovl: keep err zero after successful
ovl_cache_get()`, published 2026-06-25, fix commits `e7051909a01b` /
`1711b6ed6953`): same function, same release era, wild-memory behavior on
the same path.

**Status: prime suspect, not convicted.** Installer media was refreshed
26.04 → 26.04.1 (installer kernel 7.0.0-14 → 7.0.0-30) on this theory, yet
oopses recurred on the new media — so either the fix had not reached the
`.1` kernel, or this is an adjacent defect in the same function. Either
way the installs complete around it when victims are non-critical, which
is why the fleet is green despite the open question.

**Open:** (1) which overlay mount the victims traverse (unknown — the
trigger workload is unidentified); (2) fix-inclusion proof for any future
media (compare installer kernel build against the fix timeline, don't
assume point releases contain it). If it ever kills a load-bearing step
again: capture via the install serial log (automatic since the capture
work), then file upstream with those traces — they are exactly what a
kernel team needs.

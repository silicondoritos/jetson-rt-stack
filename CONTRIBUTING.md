# Contributing

This is a small project. Expect friendly but asynchronous responses.

The repo is biased toward **operational correctness over elegance**.
Every "magic value" must trace to a vendor source in
[`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) or to a
script that derives it. New PRs hold that bar.

## Filing an issue

The most useful issues include:

- **Hardware variant**: this stack targets the Orin NX 16GB
  (p3767-0000 module) on a p3768 Orin Nano devkit carrier. State your
  module, carrier board, and what is in the M.2 slots.
- **L4T version**: `cat /etc/nv_tegra_release` output if you have
  already flashed; otherwise the `L4T_VERSION` value from
  [`versions.env`](versions.env).
- **Phase you are at**: `doctor`, `extract`, `build`, `bake`, `flash`,
  `verify`, or runtime.
- **Step manifest excerpt**: relevant rows from `logs/STEP_MANIFEST.tsv`
  if a phase produced one.
- **The actual command and the actual output** (copy-paste, not
  paraphrase). `make logs` runs
  [`scripts/gather_logs.sh`](scripts/gather_logs.sh) and produces a
  `support-bundle-*.tar.gz` containing the build, flash, and ignition
  logs plus the staged defconfig and extlinux. Attach it if it is not
  too large.
- **Whether you have run `make doctor`**. That is the first thing the
  responder will ask.

## Sending a pull request

Before opening one:

1. **Run `make doctor`** on a machine that has the prerequisites. If it
   reports new failures introduced by your change, fix or document them.
2. **`bash -n`** every script you touched. CI runs a lint workflow
   ([`.github/workflows/lint.yml`](.github/workflows/lint.yml)); this is
   the local bar before you push.
3. **Update [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md)**
   if your change touches a vendor fact (board target, USB ID, kernel
   CONFIG name, library version, vendor URL). Cite the source URL the
   way the existing entries do.
4. **Update [`docs/FINE_TUNING.md`](docs/FINE_TUNING.md)** if you add a
   new `/etc/jetson-av/*.conf` knob.
5. **Don't commit log artifacts** (`BUILD_LOG.md`, `FLASH_LOG.txt`,
   `IGNITION_*.log`, `support-bundle-*.tar.gz`). They are in
   `.gitignore`; keep it that way.

PR description template:

```markdown
### What
1-2 sentences.

### Why
What problem does this solve / what gap does this close?

### Vendor-fact changes
- [ ] Touches a vendor fact → updated VERIFICATION_REPORT.md
- [ ] Source URLs cited

### Vermagic discipline
- [ ] Touches kernel CONFIG / LOCALVERSION → I rebuilt and confirmed
  the audit gate (`make audit`) is still green.

### Tested on
- [ ] `make doctor` clean
- [ ] `bash -n` clean on changed scripts
- [ ] (if hardware-touching) flashed and ran `make verify` on actual
  Jetson Orin NX 16GB
```

Note on `make verify`: its venv-import step checks `/opt/av-env`, which
the first-boot service provisions only once the device has internet. On
a device whose first boot ran offline, expect that one step to fail
until provisioning completes online; the rest of the suite still counts.

## Code style

- **Bash**: `set -u` minimum, `set -e` where logical. All scripts must
  pass `bash -n`. No `eval` on user input. No `insmod --force` ever.
- **Indentation**: 4 spaces. Comments explain WHY, not WHAT.
- **Step framework**: any new pre/post-gated work uses
  `step::run "Step name" pre_fn exec_fn post_fn`. See
  [`docs/VERIFICATION.md`](docs/VERIFICATION.md) and
  [`scripts/lib/verify.sh`](scripts/lib/verify.sh).
- **No emoji in code or docs** unless explicitly requested.
- **Documentation goes in `docs/`**. Each new doc gets a row in the
  README's documentation map.
- **Versions, paths, and IDs** that appear in more than one place go in
  [`versions.env`](versions.env) and
  [`scripts/lib/config.sh`](scripts/lib/config.sh), not duplicated.

## Hard rules

Each of these was learned the hard way. See
[`docs/VERMAGIC_STRATEGY.md`](docs/VERMAGIC_STRATEGY.md) for the long
version.

- **Never `insmod --force`.** A PREEMPT_RT vermagic mismatch is not safe
  to bypass; the kernel will eventually crash in non-obvious ways. Every
  external module must share the kernel's preempt_rt vermagic, and the
  audit gate (`make audit`) enforces this before any flash.
- **Never `apt install nvidia-l4t-kernel-modules`** on a flashed
  device. The first-boot script holds these packages and pins them to
  Pin-Priority -1; don't override.
- **Never force-push to `main`.** Open a branch, file a PR.
- **Don't commit secrets.** Use `/etc/jetson-av/*.conf` files
  (gitignored where appropriate) for runtime secrets; CI tokens go in
  the runner's environment.

## Architecture overview

If you are new to the codebase, read in this order:

1. [`README.md`](README.md): what this is.
2. [`docs/QUICKSTART.md`](docs/QUICKSTART.md): what running it produces.
3. [`docs/AUTOMATION.md`](docs/AUTOMATION.md): how the Makefile,
   scripts, and [`versions.env`](versions.env) compose. Read this
   BEFORE modifying any script. The layered pattern (`scripts/lib/`,
   then phase scripts, then orchestrators) is intentional.
4. [`docs/VERMAGIC_STRATEGY.md`](docs/VERMAGIC_STRATEGY.md): the single
   biggest source of pain on this stack.
5. [`docs/COMMUNITY_POST.md`](docs/COMMUNITY_POST.md): a long-form tour
   of every component end-to-end.

The pipeline runs in four scripted phases: extract and patch
([`scripts/01_extract_and_patch.sh`](scripts/01_extract_and_patch.sh)),
build in Docker
([`scripts/02_build_kernel.sh`](scripts/02_build_kernel.sh)), bake the
rootfs ([`scripts/03_bake_rootfs.sh`](scripts/03_bake_rootfs.sh)), and
flash to NVMe
([`scripts/04_flash_nvme.sh`](scripts/04_flash_nvme.sh)). A vermagic
gate and an initrd gate abort the flash before any device write if the
kernel, modules, or initrd are inconsistent.

## Questions

Use GitHub issues for technical questions and the Axelera community
thread for Metis-related discussion. If you need this in production,
fork it: that is why it is Apache 2.0.

# Agent instructions

## Responsibility

Maintain the EVB10 UEFI platform and the tools that boot and observe the board. Board policy, boot
arguments and the kernel are in `UniXNU-evb10`.

## Required reading

1. This README and `.env.example`.
2. [UEFI firmware](https://unixnu.com/porting/uefi-firmware), [bring-up](https://unixnu.com/porting/bring-up) and [log capture](https://unixnu.com/porting/log-capture).

## Rules

- Never modify the edk2-rk3588 checkout; everything lives in `UniXNUEvb10/`.
- Machine paths, hosts, accounts and passwords belong in `.env` only (git-ignored). Never put them into a script, comment or document.
- `hw-reset.sh` makes a single attempt; do not add retries. Never put `shutdown` into a payload menu.
- One serial reader at a time. Do not start a build or a second capture while `run-kernel.sh` is running.
- Do not commit generated files (dtb, ESP image, NOR images, trust bundles, Data seeds, logs).
- Inline assembly for Darwin targets uses `"\n\t"`; for edk2 assembly keep the existing style.
- Report commands, revisions and results; keep hardware observations apart from host test results.

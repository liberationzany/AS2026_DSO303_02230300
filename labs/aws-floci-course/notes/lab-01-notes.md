# Lab 01 notes

`floci start --persist ~/floci-data` only bind-mounts a host directory; it does not
set `FLOCI_STORAGE_MODE`, so Floci stays in its default `memory` mode and writes
almost nothing durable there. Real persistence requires explicitly setting
`FLOCI_STORAGE_MODE=hybrid` (or `persistent`/`wal`) alongside the mount, because
the storage mode — not the presence of a mounted path — is what controls whether
state actually survives a restart.

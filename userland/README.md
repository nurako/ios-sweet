# userland: SWEETBOX autorun helper

`sweet-autorun.c` is the one binary that has to exist on the iOS root before
the mailbox is useful. It waits for the kernel's `SWEETBOX.done` marker,
runs `/private/var/tmp/autorun.sh` (a tiny interpreter, because iOS has no
`/bin/sh`) and relays every line of output to the persistent console log as
`|sweet-autorun| SWEET RUN: ...`.

Build it on a Mac:

```sh
userland/build.sh          # -> userland/out/sweet-autorun
```

The first box (see `docs/sweetbox.md`) installs it plus a launchd cache with
the `com.sweet.autorun` job; later boxes only carry files and an autorun.sh.

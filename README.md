# mali-dkms — Rockchip Mali (Valhall, CSF) GPU kernel driver, DKMS-packaged

A DKMS source package for the ARM **Mali-Valhall** GPU kernel driver as shipped in
the Rockchip **rk35xx** vendor kernel (Linux 6.1), targeting Mali-G610 (CSF) on the
Rockchip **`rk`** platform. It builds a single loadable module, **`valhall_kbase.ko`**.

It is assembled the same way the CIX `cix-gpu-dkms` package is: the
ARM driver source tree plus a thin top-level `Makefile` and `dkms.conf` that drive an
out-of-tree Kbuild.

## Provenance

Sources are copied verbatim (no build artifacts) from the Rockchip 6.1 rk35xx kernel
worktree, DDK release **g29p1** (ARM's `r`-series renamed by Rockchip;
`midgard`→`valhall`, `mali_kbase`→`valhall_kbase`):

| In this package | Copied from (kernel tree) |
| --- | --- |
| `drivers/gpu/arm/valhall/` | `drivers/gpu/arm/valhall/` |
| `include/uapi/gpu/arm/valhall/` | `include/uapi/gpu/arm/valhall/` |
| `include/linux/*_for_valhall.h`, other Mali `linux/` headers | `include/linux/` |
| `Documentation/` (valhall DT bindings, sysfs ABI, OPP) | `Documentation/` |

The Valhall driver references the kernel's own `<linux/...>` headers via
`-I$(srctree)`; only the Mali-specific headers it can't find there are vendored into
`include/` (the Kbuild adds `-I$(src)/../../../../include`, i.e. this package root).

## Build configuration

The top-level `Makefile` passes, option for option, the Mali-Valhall settings from
the rk35xx vendor `.config` — only switched from built-in (`=y`) to module (`=m`):
platform `rk`, CSF support, devfreq, gator, expert+debug+fence-debug+trace, primary
perf-counter set, PWRSOFT-765. The KUTF test framework is forced off (it would
otherwise default on under `DEBUG=y` and emit extra test modules). Everything else
resolves to `n`, matching the vendor config. `memory_group_manager` /
`protected_memory_allocator` are **not** built (vendor `CONFIG_MALI_BASE_MODULES` is
off); `valhall_kbase` uses its native MGM.

The CSF firmware is **compiled into the module**, not loaded at runtime: the Makefile
defines `CONFIG_MALI_CSF_INCLUDE_FW`, so `csf/mali_kbase_csf_firmware.c` embeds
`drivers/gpu/arm/valhall/mali_csffw.h` (a ~1.4 MB `static u8 mali_csffw[]` blob).
No `*.mali_csffw.bin` in `/lib/firmware` is required. (That symbol is unprefixed and
not part of the ARM Makefile's config resolution, so it is injected via `KCFLAGS`.)

## Install with DKMS

`dkms` looks for the tree under `/usr/src/<PACKAGE_NAME>-<PACKAGE_VERSION>`, which for
this package is `mali-valhall-g610-g29p1`:

```sh
sudo cp -r mali-dkms /usr/src/mali-valhall-g610-g29p1
sudo dkms add     -m mali-valhall-g610 -v g29p1
sudo dkms build   -m mali-valhall-g610 -v g29p1
sudo dkms install -m mali-valhall-g610 -v g29p1
```

## Build manually (no DKMS)

```sh
make                                  # against /lib/modules/$(uname -r)/build
make KERNEL_SRC=/path/to/kernel/build # against a specific kernel
make clean
```
The module is produced at `drivers/gpu/arm/valhall/valhall_kbase.ko`.

## Important: the target kernel must not have Mali built in

DKMS replaces an out-of-tree module. If the kernel was built with
`CONFIG_MALI_VALHALL=y` (as the stock rk35xx vendor kernel is), `vmlinux` already
exports the kbase symbols and `modpost` will fail with *"<symbol> exported twice"*.
Build/install this against a kernel configured with `CONFIG_MALI_VALHALL=n` (or `=m`
and blacklisted) so `valhall_kbase.ko` is the sole provider.

## License

GPL-2.0 WITH Linux-syscall-note. See `LICENSE`.

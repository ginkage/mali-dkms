# mali-dkms — Rockchip Mali (Valhall, CSF) GPU kernel driver, DKMS-packaged

A DKMS source package for the ARM **Mali-Valhall** GPU kernel driver
(**`valhall_kbase.ko`**), extracted from the Rockchip **rk35xx** vendor kernel
(Linux 6.1) and **ported to build and run on mainline ARM64 kernels** (tested on
`7.1.2-edge-rockchip64`). Targets Mali-G610 (CSF) on the Rockchip `rk` platform
(e.g. RK3588).

It is assembled the same way the CIX `cix-gpu-dkms` package is: the ARM driver source
tree plus a thin top-level `Makefile` and `dkms.conf` that drive an out-of-tree Kbuild.

## Provenance

Sources are copied verbatim (no build artifacts) from the Rockchip 6.1 rk35xx kernel
worktree, DDK release **g29p1** (ARM's `r`-series renamed by Rockchip;
`midgard`→`valhall`, `mali_kbase`→`valhall_kbase`):

| In this package | Copied from (kernel tree) |
| --- | --- |
| `drivers/gpu/arm/valhall/` | `drivers/gpu/arm/valhall/` |
| `include/uapi/gpu/arm/valhall/` | `include/uapi/gpu/arm/valhall/` |
| `include/linux/*_for_valhall.h`, other Mali `linux/` headers | `include/linux/` |
| `include/soc/rockchip/*.h`, `include/linux/soc/rockchip/pvtm.h` | vendored BSP headers (see port notes) |
| `include/linux/wakelock.h` | re-implemented on the mainline `wakeup_source` API |
| `Documentation/` (valhall DT bindings, sysfs ABI, OPP) | `Documentation/` |

The Valhall driver references the kernel's own `<linux/...>` headers via `-I$(srctree)`;
only the Mali-specific headers it can't find there are vendored into `include/` (the Kbuild
adds `-I$(src)/../../../../include`, i.e. this package root).

## Build configuration

The top-level `Makefile` passes, option for option, the Mali-Valhall settings from the
rk35xx vendor `.config` — only switched from built-in (`=y`) to module (`=m`): platform
`rk`, CSF support, devfreq, gator, expert+debug+fence-debug+trace, primary perf-counter
set, PWRSOFT-765. The KUTF test framework is forced off (it would otherwise default on
under `DEBUG=y` and emit extra test modules). Everything else resolves to `n`, matching
the vendor config. `memory_group_manager` / `protected_memory_allocator` are **not** built
(vendor `CONFIG_MALI_BASE_MODULES` is off); `valhall_kbase` uses its native MGM.

The CSF firmware is **compiled into the module**, not loaded at runtime: the Makefile
defines `CONFIG_MALI_CSF_INCLUDE_FW`, so `csf/mali_kbase_csf_firmware.c` embeds
`drivers/gpu/arm/valhall/mali_csffw.h` (a ~1.4 MB `static u8 mali_csffw[]` blob). No
`*.mali_csffw.bin` in `/lib/firmware` is required. (That symbol is unprefixed and not part
of the ARM Makefile's config resolution, so it is injected via `KCFLAGS`.)

## Porting to mainline kernels (7.x)

The driver is a 6.1-era vendor tree; mainline has moved on. All changes are either in the
package's vendored `include/` shims or version-guarded (`KERNEL_VERSION`) so the tree still
builds against the original 6.1 vendor kernel. The validity of these fixes is corroborated
by the independent Sky1 `cix-gpu-kmd` port, which hit the same sequence on the sky1 variant.

**Build mechanism.** 7.x kbuild removed `EXTRA_CFLAGS` (kernel commit `e966ad0edd005`,
v6.15). The ARM Makefile passed *every* `-DCONFIG_MALI_VALHALL_*` define through it, so they
were silently dropped (only `MALI_USE_CSF`, set via `ccflags-y`, survived). Fixed by routing
the computed defines through `KCFLAGS` in `drivers/gpu/arm/valhall/Makefile`.

**Rockchip BSP decoupling.** mainline lacks the downstream SoC services the vendor platform
code calls. Four **self-stubbing** headers are vendored into `include/`:
`soc/rockchip/rockchip_opp_select.h`, `rockchip_system_monitor.h`, `rockchip_ipa.h`,
`linux/soc/rockchip/pvtm.h`. With `CONFIG_ROCKCHIP_*` unset (mainline) their `#else` branches
make the OPP/voltage/thermal/IPA helpers no-ops while still defining the structs embedded in
`kbase_device`. `include/linux/wakelock.h` (Android API, removed from mainline) was rewritten
on top of `wakeup_source_register()`/`__pm_stay_awake()`.

**Kernel API shims** in `include/linux/version_compat_defs_for_valhall.h`:

| Change | Kernel | Shim |
| --- | --- | --- |
| `mm_get_unmapped_area()` dropped `mm` arg | 6.19 | call 5-arg form |
| `hrtimer_init()` → `hrtimer_setup()` | 6.15 | macro maps `hrtimer_init` onto `hrtimer_setup` w/ placeholder cb |
| `del_timer[_sync]()` → `timer_delete[_sync]()` | 6.15 | macros (both names) |
| `dma_fence_ops.fence_value_str` removed | 6.16 | guarded out in `mali_kbase_fence_ops.c` |
| `__Set/ClearPageMovable()` removed | 6.17 | no-op'd; page migration force-disabled at init |
| `dma_fence_signal()` became `void` | 7.x | int-returning shim (returns 0) |
| `shmem_file_setup()` flags → `vma_flags_t` | 7.x | wrapper via `legacy_to_vma_flags()` |

**Robustness** (adopted from the cix-gpu-kmd port): `kbase_gpu_wait_cache_clean()` had an
unbounded `wait_event_interruptible()` that hangs forever on a stuck cache flush (e.g. after
a GPU fault) — replaced with a 2 s `wait_event_timeout()` + GPU-reset recovery. Added
`MODULE_DESCRIPTION` (silences the 6.x build warning).

**Functional caveats** (none block rendering): DVFS works via the standard DT
`operating-points-v2` table (loaded with `dev_pm_opp_of_add_table()`), but Rockchip's
vendor voltage **binning/AVS/read-margin** tuning is not applied; GPU-page migration
(memory compaction of GPU pages) is disabled unless the optional kernel patch is applied
(see *Optional: GPU page migration* below).

## Optional: GPU page migration (kernel patch)

Kernel 6.17 replaced the per-page `__SetPageMovable()` API with a page-type-based
`set_movable_ops()` scheme, and there is no page type a module can register on its own.
So on a stock 6.17+ kernel the driver builds with page migration **disabled** (the markers
no-op, logged once at probe) — harmless, as it is only a memory-compaction optimisation.

To enable it, the kernel needs a small page-type patch, provided here:

```sh
# inside your kernel source tree (e.g. an Armbian build), then rebuild the kernel
patch -p1 < /path/to/mali-dkms/kernel-patches/0001-mm-add-PGTY_mali_gpu-movable-page-type.patch
```

It adds a `PGTY_mali_gpu` page type (`include/linux/page-flags.h` + the matching cases in
`mm/migrate.c`) plus a self-referential `#define PGTY_mali_gpu` so the module can detect it.
The driver auto-adapts: when `PGTY_mali_gpu` is defined, `KBASE_PAGE_MIGRATION_SUPPORTED`
becomes 1, the `__Set/ClearPageMovable` shims map onto the new page type (mirroring how
in-tree `zsmalloc` marks pages), and `kbase_mem_migrate_init()` registers the driver's
`movable_operations` with `set_movable_ops(&movable_ops, PGTY_mali_gpu)`. Without the patch
it falls back to the disabled no-op path automatically — the same DKMS sources build both
ways, so no driver edits are needed either direction.

## Install with DKMS

`dkms` looks for the tree under `/usr/src/<PACKAGE_NAME>-<PACKAGE_VERSION>`, which for this
package is `mali-valhall-g610-g29p1`:

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

## Running it: panthor coexistence

On a mainline kernel the in-tree **panthor** DRM driver claims the Mali GPU
(`fb000000.gpu`, providing `renderD128`). The proprietary libmali stack needs
`valhall_kbase` instead, so panthor must be displaced — which also removes that render node,
so the libmali/Zink/XWayland userspace needs it back from `rockchip-drm` (see *The userspace
stack* below). Binding and probe were reconciled
with the mainline DT node in advance — **no DT overlay is needed**:

1. **Binding** — added `arm,mali-valhall-csf` and `rockchip,rk3588-mali` to `kbase_dt_ids[]`
   so kbase matches the existing node (this also makes modalias auto-load work).
2. **Clocks / regulator / interrupts / power-domain** — already compatible with the mainline
   node: kbase reads clocks by *index* (grabs all three — `core`/`coregroup`/`stacks`), the
   regulator by name `mali` (→ `mali-supply`), interrupts with an upper-then-**lower**-case
   fallback (`job`/`mmu`/`gpu`), and the single power-domain attaches via genpd + `pm_runtime`.
3. **OPP / DVFS** — on mainline the vendor Rockchip OPP path is stubbed, so
   `kbase_platform_rk_init_opp_table()` now loads the standard DT `operating-points-v2` table
   via `dev_pm_opp_of_add_table()` (selected by `#if CONFIG_ROCKCHIP_OPP`).

The remaining step is the runtime test once panthor is out of the way (below).

**Recovery is safe:** the display controller (`card0`, `display-subsystem`/HDMI) is a
separate device from the GPU (`card1`/`fb000000.gpu`), so blacklisting the GPU driver does
not lose the console or SSH.

### Load management: optional during dev, automatic when stable

While the driver may still crash or hang, never let it take down boot; once trusted, load
it automatically.

**Dev phase — manual, recoverable.** `blacklist` only blocks *automatic* (modalias/udev)
loading; explicit `modprobe` still works:

```sh
# /etc/modprobe.d/mali-dev.conf
blacklist panthor          # free the GPU device (display stays up on card0)
blacklist valhall_kbase    # do NOT auto-load — every boot comes up clean
```
```sh
sudo update-initramfs -u           # if panthor is shipped in the initramfs
# reboot, then test by hand (over serial/SSH so a hang is recoverable):
sudo modprobe valhall_kbase
# if it hangs/panics, just reboot — nothing auto-loads, so the system returns clean
```

**Stable phase — automatic.** Keep panthor blacklisted and drop the `valhall_kbase`
blacklist line. With a matching `compatible` in `kbase_dt_ids[]`, the DKMS-installed module
auto-loads via modalias at boot and binds the GPU. (`dkms.conf`'s `AUTOINSTALL=yes` only
rebuilds the module on kernel upgrades; it does not control loading.)

## The userspace stack: render node + uncached heap (kernel patches)

`valhall_kbase` is only the GPU **compute** driver (`/dev/mali0`). The full Rockchip libmali
userspace — native GLES/Vulkan, plus Mesa/**Zink** GL-on-Vulkan and **XWayland** — needs two
more things from the kernel that mainline (unlike the Rockchip vendor kernel) stopped providing
once panthor is displaced. Both are carried here as kernel patches; apply them to the target
kernel source and rebuild.

**Render node — `0002-drm-rockchip-expose-render-node.patch`.** On Rockchip the DRM **render
node** (`/dev/dri/renderD128`) is what Mesa/Zink and XWayland's glamor open for their GBM/winsys
(buffer handles + dma-buf PRIME); the actual GPU work still goes to libmali (`/dev/mali0`) /
libMaliVulkan. On mainline that node is provided by **panthor**, so blacklisting panthor to run
`valhall_kbase` removes it and Mesa/Zink/XWayland fail with *"Failed to make EGL context current
with GL"* (the libmali-native GLES desktop keeps working — it needs no DRM render node). The
Rockchip vendor kernel instead exposes the render node from the **display** driver — its
`rockchip-drm` carries `DRIVER_RENDER`, mainline's is display-only — so the patch re-adds that
one flag. Nothing more is needed: libmali allocates through dma-heap, not the vendor
`ROCKCHIP_GEM_CREATE` ioctl. `CONFIG_DRM_ROCKCHIP=m`, so this is testable by rebuilding just
`rockchipdrm.ko` — no full kernel build.

**Uncached dma-heap — `0003-dma-buf-system-heap-add-system-uncached.patch`.** libmali and its WSI
layer allocate write-combine buffers from `/dev/dma_heap/system-uncached` (needed on the
non-coherent GPU — cached fallback corrupts). Mainline removed that heap (~5.13). The patch
re-adds it, ported from the Rockchip vendor mechanism (Simon Xue, commits `a2ded8cab4d6` /
`43fb28d9a879` / `1a44a281070e`) onto mainline's `priv`-based `system_heap.c` (an `uncached` flag
beside the existing `cc_shared` one), plus the small `dma_heap_get_dev()` accessor the alloc-time
cache flush needs. The vendor's `*_partial` cpu-access ops and kernel-space
`dma_heap_find`/`dma_heap_buffer_alloc` helpers are intentionally omitted — libmali uses neither
(only the standard full `DMA_BUF_IOCTL_SYNC`). Built-in (`=y`), so this one needs a full kernel
rebuild.

The result is the split the Rockchip 6.1 vendor kernel uses, reproduced on mainline: **kbase**
drives the GPU (`/dev/mali0`), patched **rockchip-drm** hands out the render node for the
Zink/Mesa/XWayland winsys, **libmali** does GLES/Vulkan plus the uncached heap, and **Zink**
layers GL on top of libMaliVulkan.

**Status — confirmed on hardware.** On a `7.1.2-edge-rockchip64` build with 0002 + 0003
applied, `/dev/dri/renderD128` (`rockchip-drm`) and `/dev/dma_heap/system-uncached` are both
present, and XWayland, Vulkan, and Zink-on-libMaliVulkan all run on `valhall_kbase`.

## Important: vendor kernels with Mali built in

If the *target* kernel was built with `CONFIG_MALI_VALHALL=y` (as the stock rk35xx vendor
kernel is — not mainline), `vmlinux` already exports the kbase symbols and `modpost` fails
with *"<symbol> exported twice"*. Build against a kernel with `CONFIG_MALI_VALHALL=n` (or
`=m` + blacklist). Mainline kernels have no in-tree kbase, so this does not arise there.

## License

GPL-2.0 WITH Linux-syscall-note. See `LICENSE`.

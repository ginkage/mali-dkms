# SPDX-License-Identifier: GPL-2.0
#
# Top-level DKMS Makefile for the Rockchip Mali (Valhall, CSF) GPU kernel driver.
#
# Builds drivers/gpu/arm/valhall/valhall_kbase.ko out-of-tree against the target
# kernel, configured for the Rockchip "rk" platform (rk35xx / Mali-G610, CSF).
#
# This mirrors the approach of the CIX cix-gpu-kmd DKMS package: pass the platform
# and feature CONFIG_* on the command line, then recurse into the ARM driver
# Makefile (which resolves the remaining Kconfig dependencies for out-of-tree
# builds and drives Kbuild against $(KDIR)).

# Kernel to build against. DKMS invokes us with KERNEL_SRC=${kernel_source_dir};
# a manual "make" falls back to the running kernel's build tree.
KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
KDIR       ?= $(KERNEL_SRC)

# The Valhall kbase driver within this package.
VALHALL_DIR := drivers/gpu/arm/valhall

# Configuration. This reproduces, option for option, the Mali-Valhall settings of
# the Rockchip rk35xx vendor kernel .config (the build target), only switched from
# built-in (=y) to a loadable module (=m). The KUTF kernel-unit-test framework is
# forced off: out-of-tree it would default on when DEBUG=y, but the vendor kernel
# ships it disabled and it would otherwise emit extra test .ko modules.
#
# Anything not listed resolves to n via the ARM Makefile's dependency logic, which
# matches the "is not set" entries in the vendor .config.
MALI_CONFIGS := \
	CONFIG_MALI_VALHALL=m \
	CONFIG_MALI_VALHALL_PLATFORM_NAME=rk \
	CONFIG_MALI_VALHALL_CSF_SUPPORT=y \
	CONFIG_MALI_VALHALL_REAL_HW=y \
	CONFIG_MALI_VALHALL_DEVFREQ=y \
	CONFIG_MALI_VALHALL_GATOR_SUPPORT=y \
	CONFIG_MALI_VALHALL_EXPERT=y \
	CONFIG_MALI_VALHALL_DEBUG=y \
	CONFIG_MALI_VALHALL_ENABLE_TRACE=y \
	CONFIG_MALI_VALHALL_FENCE_DEBUG=y \
	CONFIG_MALI_VALHALL_SYSTEM_TRACE=y \
	CONFIG_MALI_VALHALL_PRFCNT_SET_PRIMARY=y \
	CONFIG_MALI_VALHALL_TRACE_POWER_GPU_WORK_PERIOD=y \
	CONFIG_MALI_PWRSOFT_765=y \
	CONFIG_MALI_VALHALL_KUTF=n

# Compile the CSF firmware straight into the module. With CONFIG_MALI_CSF_INCLUDE_FW
# defined, csf/mali_kbase_csf_firmware.c #includes drivers/.../valhall/mali_csffw.h
# (a ~1.4 MB `static u8 mali_csffw[]` blob); without it the driver falls back to
# request_firmware() and needs a .mali_csffw.bin in /lib/firmware. The vendor kernel
# sets it =y, but it is unprefixed and absent from the ARM Makefile's CONFIGS list,
# so it is injected here as a compile define via KCFLAGS (which the kernel appends to
# KBUILD_CFLAGS for every object) rather than through the CONFIG_* pass-through.
export KCFLAGS := $(KCFLAGS) -DCONFIG_MALI_CSF_INCLUDE_FW=1

.PHONY: all modules_install clean

all:
	$(MAKE) -C $(VALHALL_DIR) KERNEL_SRC=$(KDIR) $(MALI_CONFIGS) all

modules_install:
	$(MAKE) -C $(VALHALL_DIR) KERNEL_SRC=$(KDIR) $(MALI_CONFIGS) modules_install

# `clean` deletes the out-of-tree build products directly instead of recursing
# into the kernel's clean. The ARM Kbuild has dependency checks that error out
# (e.g. FENCE_DEBUG requires CONFIG_SYNC_FILE) using kernel CONFIG_* that are only
# loaded for a build, not for the 'clean' target — so a kbuild clean aborts with
# "Error 2". DKMS runs CLEAN before and after every build, so it must succeed.
clean:
	find $(VALHALL_DIR) -type f \( -name '*.o' -o -name '*.ko' -o -name '*.mod' \
		-o -name '*.mod.c' -o -name '*.mod.o' -o -name '*.cmd' -o -name '*.d' \
		-o -name '*.a' -o -name 'modules.order' -o -name 'Module.symvers' \) -delete

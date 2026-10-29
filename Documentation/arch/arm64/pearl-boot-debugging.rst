Pearl boot-time memory corruption
================================

Scope
-----

The reported boot-time fault occurs in ``klist_next()`` while
``fw_devlink_drivers_done()`` walks the device-link class. The previous
node's successor is NULL, producing a read at address ``-8``. This is a
corrupted list, not evidence that MMQoS initialization failed. Continuing
after this Oops can leave a worker holding locks with interrupts disabled.

The diagnostic changes address two independently confirmed problems:

* Both the CCCI SCP platform probe and modem initialization call the same
  SCP initializer. Initialization is now serialized and performed once;
  the state-sync work is initialized before registering the notifier,
  which can synchronously deliver SCP READY.
* LK can relocate the Wi-Fi shared DMA pool. The embedded DTB's captured
  address must not be used after relocation. The kernel records the
  unique LK Wi-Fi reservation, then updates both the live OF ``reg``
  property and the reserved-memory manager before device probing. Missing,
  malformed, ambiguous or already-used pools are not modified.

Neither problem has been proven to cause the device-link corruption.
The changes are not a verified fix for the vendor-logo hang.

Boot image and vendor_boot
--------------------------

The inspected diagnostic boot image uses Android boot header version 4.
With this format, ``vendor_boot`` can supply a vendor ramdisk and DTB;
the header alone does not establish which partition supplied LK's FDT.

This kernel first reads the handed-off FDT's boot arguments, RAM layout
and reserved-memory windows. It then replaces the driver tree with the
embedded Pearl DTB. An incompatible firmware DTB or vendor ramdisk can
therefore matter, but the supplied ``klist_next`` trace does not identify
``vendor_boot`` as the source of the NULL class-list pointer.

Initially keep both ramdisks and ``vendor_boot`` unchanged while testing
the new diagnostic kernel. Capture the first corruption report before
changing another boot component. Do not force-load vendor modules built
for a different kernel release.

Diagnostic configuration
------------------------

``arch/arm64/configs/pearl-kasan.config`` enables Generic KASAN with outline
instrumentation, vmalloc checking, allocation/free metadata, list checks
and panic-on-Oops. It does not enable panic-on-WARN: unrelated existing
warnings must not prevent reaching the reported fault.

With ``CONFIG_DEBUG_LIST``, the devlink callback reports a NULL class-list
pointer before or after relaxing a link. The report names the link and
includes raw object addresses for comparison with the fault registers.
This instrumentation does not skip traversal or turn a corrupt pointer
into a successful result.

KASAN can report CPU out-of-bounds accesses and use-after-free, but does
not reliably identify DMA writes or all in-bounds logical overwrites.
Absence of a KASAN report is not proof that memory corruption is fixed.

Building
--------

Use the full configuration from the affected kernel, not a fresh minimal
defconfig. Provide an AArch64-capable Clang/LLVM toolchain, the normal
kernel host build dependencies, and ``pahole`` if the base config uses BTF::

    LLVM_BIN=/path/to/llvm/bin \
    BASE_CONFIG=/path/to/affected/kernel.config \
    OUTPUT_DIR=/path/to/new/pearl-kasan \
    JOBS=1 LLD_THREADS=1 \
    bash scripts/pearl/build-kasan.sh

Generic KASAN and debug information require additional build resources.
A single build job does not guarantee that a low-memory host can complete
the final link; use a host with sufficient RAM and disk space.

The builder checks the toolchain before changing configuration or creating
build products. It copies tracked and non-ignored untracked source files
into a fresh build snapshot, excluding ignored objects and configuration.
The original checkout is not cleaned or rebuilt. The snapshot is built
in place because the existing embedded-DTB rule builds in the source tree.

The output contains ``Image``, ``Image.gz``, the embedded DTB, ``vmlinux``,
``System.map``, ``vmlinux.symvers``, configuration, source patch, build
logs and checksums. The ``Image`` target does not build modules or their
combined ``Module.symvers`` file.
Only a successful build writes ``build-status.txt`` with ``built``.
The ``vmlinux`` symlink requires retaining the ``build`` directory.

The release suffix ``-pearl-kasan`` deliberately differs from the affected
kernel. Do not force-load modules built for the old release. Matching
modules are not built by this script; build them from the same snapshot
and configuration if required.

This script does not create or flash an Android boot image. Retain the
existing boot ramdisk and boot header when packaging a new kernel, and
check the final image against the actual boot-partition size. Do not
modify LK, vendor_boot, vbmeta or userdata for this diagnosis.

GitHub Actions
--------------

``.github/workflows/pearl-kasan.yml`` builds on Ubuntu 24.04 with LLVM 18.
Push the source fixes, builder and configuration to the
``7.2-mt6895-xiaomi-pearl`` branch to trigger it. Manual dispatch is also
available when the workflow is present on the repository's default branch.

``arch/arm64/configs/pearl-artifact.config`` records the full affected
kernel configuration. The workflow uses this file as the base and applies
``pearl-kasan.config``; it does not substitute a minimal defconfig.
Each build starts from a fresh checkout and source snapshot, with no
object cache, and only read access to repository contents.

Successful runs upload ``pearl-kasan-<commit>.tar.zst`` containing the new
ARM64 ``Image``, compressed image, DTB, configurations, symbols, build
provenance, source commit patch and checksums. The archive dereferences the
``vmlinux`` symlink, so it is self-contained without the build directory.
Build logs are uploaded separately, including when compilation fails.
Neither the generic nor vendor ramdisk is rebuilt by this workflow.

Next evidence
-------------

Capture the first ``BUG: KASAN:``, list-debug report or
``PEARL-DEVLINK-CORRUPTION`` message with its allocation/free stacks. Decode
addresses only with this build's ``vmlinux``. Do not treat later surviving
GPU or touch logs, or a message printed before the foreground unmount, as
proof that PID 1 completed the handoff.

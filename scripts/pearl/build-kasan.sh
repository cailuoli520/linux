#!/bin/bash
set -euo pipefail

if [[ ${1:-} == --help ]]; then
    printf '%s\n' \
        'Build the Pearl diagnostic kernel in a fresh source snapshot.' \
        'Environment: LLVM_BIN, KERNEL_SOURCE, BASE_CONFIG, OUTPUT_DIR, JOBS, LLD_THREADS.' \
        'BASE_CONFIG defaults to the existing kernel .config; JOBS and LLD_THREADS default to 1.' \
        'This builds Image and symbols, not an Android boot.img or matching modules.'
    exit 0
fi
if [[ $# != 0 ]]; then
    printf 'Unexpected arguments; use --help.\n' >&2
    exit 2
fi

kernel_source=${KERNEL_SOURCE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
kernel_source=$(realpath -- "$kernel_source")
base_config=${BASE_CONFIG:-"$kernel_source/.config"}
output_dir=$(realpath -m -- "${OUTPUT_DIR:-$kernel_source/../../pearl-boot/kernel-kasan}")
jobs=${JOBS:-1}
lld_threads=${LLD_THREADS:-1}

if [[ -n ${LLVM_BIN:-} ]]; then
    export PATH="$LLVM_BIN:$PATH"
fi
if [[ ! $jobs =~ ^[1-9][0-9]*$ || ! $lld_threads =~ ^[1-9][0-9]*$ ]]; then
    printf 'JOBS and LLD_THREADS must be positive integers.\n' >&2
    exit 2
fi
missing_tools=()
for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip \
            make git tar gzip sha256sum tee bc bison flex perl openssl pkg-config unlink rmdir; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools+=("$tool")
    fi
done
if [[ ${#missing_tools[@]} != 0 ]]; then
    printf 'Cannot build: missing tools: %s\n' "${missing_tools[*]}" >&2
    printf '%s\n' \
        'Provide LLVM_BIN pointing to an LLVM toolchain.' \
        'No configuration or Image was changed.' >&2
    exit 2
fi
if [[ ! -f $base_config ]]; then
    printf 'Missing base configuration: %s\n' "$base_config" >&2
    exit 2
fi
if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$base_config" && ! command -v pahole >/dev/null 2>&1; then
    printf 'The base configuration enables BTF, but pahole is missing.\n' >&2
    exit 2
fi
case "$output_dir/" in
    "$kernel_source/"*)
        printf 'OUTPUT_DIR must be outside KERNEL_SOURCE.\n' >&2
        exit 2
        ;;
esac
if [[ -e $output_dir/build || -e $output_dir/Image || -e $output_dir/vmlinux ]]; then
    printf 'Refusing to reuse build products. Choose a fresh OUTPUT_DIR: %s\n' "$output_dir" >&2
    exit 2
fi

cd -- "$kernel_source"
git diff --check HEAD
compiler_test_dir=$(mktemp -d)
cleanup_compiler_test()
{
    for generated_file in test.o linked.o; do
        if [[ -f $compiler_test_dir/$generated_file ]]; then
            unlink -- "$compiler_test_dir/$generated_file"
        fi
    done
    rmdir -- "$compiler_test_dir"
}
trap cleanup_compiler_test EXIT
printf 'int pearl_compiler_test(void) { return 0; }\n' | \
    clang --target=aarch64-linux-gnu -x c -c -o "$compiler_test_dir/test.o" -
ld.lld --threads="$lld_threads" -m aarch64elf -r \
    "$compiler_test_dir/test.o" -o "$compiler_test_dir/linked.o"

build_dir="$output_dir/build"
mkdir -p -- "$build_dir"
if [[ ! $base_config -ef $output_dir/kernel.base.config ]]; then
    cp -- "$base_config" "$output_dir/kernel.base.config"
fi
git rev-parse HEAD > "$output_dir/source-commit.txt"
clang --version > "$output_dir/compiler-version.txt"
git diff --binary HEAD > "$output_dir/kernel.patch"
while IFS= read -r -d '' source_path; do
    if [[ -f $source_path || -L $source_path ]]; then
        if git diff --no-index --binary -- /dev/null "$source_path" \
            >> "$output_dir/kernel.patch"; then
            :
        elif [[ $? != 1 ]]; then
            exit 1
        fi
    fi
done < <(git ls-files --others --exclude-standard -z)

while IFS= read -r -d '' source_path; do
    if [[ -f $source_path || -L $source_path ]]; then
        printf '%s\0' "$source_path"
    fi
done < <(git ls-files --cached --others --exclude-standard --deduplicate -z) \
    > "$output_dir/source-files.list"
tar --null --no-recursion -T "$output_dir/source-files.list" -cf - | tar -xf - -C "$build_dir"

cd -- "$build_dir"
diagnostic_config="$build_dir/arch/arm64/configs/pearl-kasan.config"
KCONFIG_CONFIG="$build_dir/.config" "$build_dir/scripts/kconfig/merge_config.sh" -m \
    "$output_dir/kernel.base.config" "$diagnostic_config" > "$output_dir/config-merge.log"
make_args=(ARCH=arm64 LLVM=1 LOCALVERSION= O= "KCONFIG_CONFIG=$build_dir/.config"
           "LD=ld.lld --threads=$lld_threads")
make -C "$build_dir" "${make_args[@]}" olddefconfig 2>&1 | tee "$output_dir/olddefconfig.log"
while IFS= read -r setting; do
    if [[ -n $setting ]] && ! grep -Fqx -- "$setting" "$build_dir/.config"; then
        printf 'Required diagnostic option was not retained: %s\n' "$setting" >&2
        exit 1
    fi
done < "$diagnostic_config"

kernel_release=$(make -s -C "$build_dir" "${make_args[@]}" kernelrelease)
if [[ $kernel_release != *-pearl-kasan ]]; then
    printf 'Unexpected diagnostic kernel release: %s\n' "$kernel_release" >&2
    exit 1
fi
printf '%s\n' "$kernel_release" > "$output_dir/kernel-release.txt"
cp -- "$build_dir/.config" "$output_dir/kernel.config"
"$build_dir/scripts/diffconfig" "$output_dir/kernel.base.config" "$build_dir/.config" \
    > "$output_dir/config-diff.txt"
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-pearl}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-diagnostic}
make -j"$jobs" -C "$build_dir" "${make_args[@]}" Image 2>&1 | tee "$output_dir/build.log"

cp -- "$build_dir/arch/arm64/boot/Image" "$output_dir/Image"
gzip -n -c "$output_dir/Image" > "$output_dir/Image.gz"
cp -- "$build_dir/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-pearl.dtb" \
    "$output_dir/mt6895-xiaomi-pearl.dtb"
cp -- "$build_dir/System.map" "$output_dir/System.map"
cp -- "$build_dir/vmlinux.symvers" "$output_dir/vmlinux.symvers"
ln -s build/vmlinux "$output_dir/vmlinux"
llvm-objdump -d --disassemble-symbols=klist_next "$build_dir/lib/klist.o" \
    > "$output_dir/klist-next-disassembly.txt"
llvm-readelf -n "$build_dir/vmlinux" > "$output_dir/vmlinux-notes.txt"
cd -- "$output_dir"
sha256sum Image mt6895-xiaomi-pearl.dtb Image.gz kernel.config kernel.base.config \
    kernel.patch System.map vmlinux.symvers vmlinux > SHA256SUMS
printf 'built\n' > build-status.txt
printf 'Diagnostic kernel built: %s/Image (%s)\n' "$output_dir" "$kernel_release"

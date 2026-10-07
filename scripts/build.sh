#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	export PATH="${CLANG_PATH:-}:${PATH}"

	# إذا لم يجد الملف في المسار المعتاد، يقوم بتوليده تلقائياً بأمان
	if [ ! -f "$DEFCONFIG_PATH" ]; then
		echo "[*] Generating defconfig using make ${KERNEL_CONFIG}..."
		make -C "$KERNEL_DIR" ARCH="$ARCH" "$KERNEL_CONFIG" || make -C "$KERNEL_DIR" ARCH="$ARCH" defconfig || true
		mkdir -p "$(dirname "$DEFCONFIG_PATH")"
		[ -f "${KERNEL_DIR}/.config" ] && cp "${KERNEL_DIR}/.config" "$DEFCONFIG_PATH" || true
	fi

	touch "$DEFCONFIG_PATH"
	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"
	
	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU || true
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver" || true

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH" || true
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y || true
		fi
	fi

	# استخدام صيغة if الآمنة بدلاً من && لتجنب انهيار set -e الصامت
	if is_true "${ADD_OVERLAYFS_CONFIG:-false}"; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS || true
	fi

	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y || true
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y || true
	fi

	if is_true "${DISABLE_CC_WERROR:-false}"; then
		kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR || true
	fi

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" || true ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact names predictable.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\"" || true
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion" || true
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "ARCH=${ARCH} LLVM=1 LLVM_IAS=1 OBJCOPY=llvm-objcopy KCFLAGS=-Wno-error"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST="abfarm"
	export KBUILD_BUILD_USER="android-build"
	export KBUILD_BUILD_TIMESTAMP="Wed Nov 26 11:16:14 UTC 2025"
	
	# تعطيل تحذيرات Clang 22 الجديدة كلياً لتفادي توقف BPF و syscalls
	export KCFLAGS="-Wno-error -Wno-default-const-init-var-unsafe"

	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" \
		|| die "defconfig generation failed"

	info "make ${args}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"

	# إنشاء رابط رمزي لضمان عثور باقي مراحل الأكشن على المخرجات
	mkdir -p "${KERNEL_DIR}/out/arch/${ARCH}/boot"
	if [ -f "${KERNEL_DIR}/arch/${ARCH}/boot/${KERNEL_IMAGE_NAME}" ]; then
		cp "${KERNEL_DIR}/arch/${ARCH}/boot/${KERNEL_IMAGE_NAME}" "${KERNEL_DIR}/out/arch/${ARCH}/boot/" || true
	fi

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi

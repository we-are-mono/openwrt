# Single source of truth for the ASK revision used by all ASK packages.
# Must match ASK_VERSION in target/linux/layerscape/Makefile so the kernel
# patches and the userspace/modules always come from the same commit.
ASK_VERSION:=b4c31a46dfb7b03984ebfa3a8eabd06ccbc0cc91
ASK_SOURCE:=ask-$(ASK_VERSION).tar.xz
ASK_SOURCE_URL:=https://github.com/we-are-mono/ASK

# APK-valid package version for ASK-sourced packages (apk rejects
# versions that do not start with a digit, so the raw sha cannot be used)
ASK_PKG_VERSION:=1.0_git20260808

# NXP userspace components, pinned to the same LSDK tag as the kernel
# (lf-6.12.49-2.2.0; expressed digits-only for apk)
ASK_NXP_TAG:=lf-6.12.49-2.2.0
ASK_NXP_PKG_VERSION:=6.12.49.2.2.0

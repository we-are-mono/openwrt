# Single source of truth for the ASK revision used by all ASK packages.
# Must match ASK_VERSION in target/linux/layerscape/Makefile so the kernel
# patches and the userspace/modules always come from the same commit.
ASK_VERSION:=fe36f305a473d4121cf8613cc8c8c5a8496d8c48
ASK_SOURCE:=ask-$(ASK_VERSION).tar.xz
ASK_SOURCE_URL:=https://github.com/we-are-mono/ASK

# APK-valid package version for ASK-sourced packages, DERIVED from ASK_VERSION
# so it changes whenever the pinned commit does. apk requires a leading digit
# (so the bare sha cannot be used) but accepts a ~<hash> commit suffix — the
# same scheme the kernel package uses (e.g. 6.12.49~b9036c2b...). The old value
# was a hand-typed date string decoupled from the commit: two different commits
# could share one version, so an in-place `apk upgrade` would skip a new ASK and
# `apk list` misreported which commit was installed. (sysupgrade was unaffected —
# it reflashes the whole rootfs — but the version label lied.)
ASK_PKG_VERSION:=1.0~$(shell echo $(ASK_VERSION) | cut -c1-12)

# NXP userspace components, pinned to the same LSDK tag as the kernel
# (lf-6.12.49-2.2.0; expressed digits-only for apk)
ASK_NXP_TAG:=lf-6.12.49-2.2.0
ASK_NXP_PKG_VERSION:=6.12.49.2.2.0

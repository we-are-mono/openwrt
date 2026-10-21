# Single source of truth for the ASK revision used by all ASK packages.
# Must match ASK_VERSION in scripts/mono-sync-ask-kernel.sh so the kernel
# patches and the userspace/modules always come from the same commit.
ASK_VERSION:=a58493b5b458f03aa9729f2c56743e3427279e1c
# The ASK release tag ASK_VERSION points at (mono-1.1.4 -> 1.1.4); bump both together.
ASK_RELEASE:=1.1.7
ASK_SOURCE:=ask-$(ASK_VERSION).tar.xz
ASK_SOURCE_URL:=https://github.com/we-are-mono/ASK

# APK-valid package version for ASK-sourced packages: <release>~<commit>. apk
# requires a leading digit (so the bare sha cannot be used) and accepts a ~<hash>
# commit suffix, the same scheme the kernel package uses (6.12.49~b9036c2b...).
# The release number is what orders two pins: owut and apk compare only the
# numeric part and the -rN, so with a fixed "1.0~" prefix every bump compared as
# equal and owut reported it as "indeterminate". The hash keeps two builds of
# one release (e.g. a local file:// pin) distinguishable in `apk list`.
ASK_PKG_VERSION:=$(ASK_RELEASE)~$(shell echo $(ASK_VERSION) | cut -c1-12)


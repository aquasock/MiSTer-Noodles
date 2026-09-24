#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work="$root/build/sdk-consumer"
mkdir -p "$work"
cp "$root/examples/sdk_smoke.c" "$work/consumer.c"
for target in host arm; do
    stage="$work/$target"
    make -C "$root" --no-print-directory install-sdk SDK_TARGET="$target" PREFIX=/usr DESTDIR="$stage"
    (
        cd "$work"
        export PKG_CONFIG_LIBDIR="$stage/usr/lib/pkgconfig"
        export PKG_CONFIG_SYSROOT_DIR="$stage"
        test "$(pkg-config --modversion noodles)" = 0.2.0
        if [ "$target" = host ]; then
            cc="${HOSTCC:-cc}"
            link_flags=
        else
            cc="${CROSS:-arm-linux-gnueabihf-}gcc"
            link_flags=-static
        fi
        # Deliberate splitting of pkg-config's compiler/linker flags.
        "$cc" $link_flags -Wall -Wextra -Werror $(pkg-config --cflags noodles) consumer.c \
            $(pkg-config --libs noodles) -o "$target-consumer"
        if [ "$target" = host ]; then
            "${HOSTCXX:-c++}" -x c++ -Wall -Wextra -Werror \
                $(pkg-config --cflags noodles) consumer.c -x none \
                $(pkg-config --libs noodles) -o host-cpp-consumer
            # Usage-only run: no /dev/mem or hardware access on the build host.
            if ./host-consumer --invalid > usage.log 2>&1; then
                echo "Expected usage rejection for invalid argument" >&2
                exit 1
            fi
            grep -q 'Usage:' usage.log
        fi
    )
done
echo "PASS: installed SDK consumers (native C/C++, ARM C) via pkg-config only"

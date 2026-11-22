#!/bin/bash
# Verify every ExecStart path and every dependency a custom unit names actually
# exists in the image.
#
# bluez was missing while multi-user.target.wants/bluetooth.service was a dangling
# symlink, and the image check passed because it only looked at the link name. This
# makes that class of bug impossible to miss: for each custom unit, resolve every
# ExecStart binary and every After/Before/Wants/Requires unit.
set -u
IMG=${IMG:-$(cd "$(dirname "$0")/.." && pwd)/rootfs.ext4}
MNT=$(mktemp -d)

sudo -n mount -o loop,ro "$IMG" "$MNT" 2>/dev/null || { echo "挂载失败: $IMG"; exit 1; }

pass=0; fail=0

exists_in_image() {
    # $1 is an absolute path inside the image.
    local p=${1#/}
    local dir base
    dir=$(dirname "$p")
    base=$(basename "$p")
    sudo -n ls "$MNT/$dir" 2>/dev/null | grep -qx "$base"
}

echo "===== 检查每个自定义单元的 ExecStart 与依赖 ====="
for f in "$MNT"/etc/systemd/system/*.service; do
    [ -f "$f" ] || continue
    name=$(basename "$f")

    # ExecStart may carry a leading "-" or "@"; strip them.
    while IFS= read -r line; do
        bin=$(echo "$line" | sed 's/^ExecStart=//; s/^[-@+]//' | awk '{print $1}')
        [ -n "$bin" ] || continue
        case "$bin" in
            /*)
                if exists_in_image "$bin"; then
                    printf '  [OK]   %-26s ExecStart %s\n' "$name" "$bin"
                    pass=$((pass + 1))
                else
                    printf '  [FAIL] %-26s ExecStart %s 不存在\n' "$name" "$bin"
                    fail=$((fail + 1))
                fi
                ;;
        esac
    done < <(grep -hE '^ExecStart=' "$f" 2>/dev/null)

    # Dependencies on other units.
    while IFS= read -r dep; do
        case "$dep" in
            *.service|*.target|*.socket)
                if exists_in_image "/usr/lib/systemd/system/$dep" \
                   || exists_in_image "/etc/systemd/system/$dep"; then
                    printf '  [OK]   %-26s 依赖 %s\n' "$name" "$dep"
                    pass=$((pass + 1))
                else
                    printf '  [FAIL] %-26s 依赖 %s 不存在\n' "$name" "$dep"
                    fail=$((fail + 1))
                fi
                ;;
        esac
    done < <(grep -hE '^(After|Before|Wants|Requires)=' "$f" 2>/dev/null \
             | sed 's/^[A-Za-z]*=//' | tr ' ' '\n' | sort -u)
done

echo
echo "===== 检查 .wants 里每个链接的目标 ====="
for d in "$MNT"/etc/systemd/system/*.wants; do
    [ -d "$d" ] || continue
    for l in "$d"/*; do
        [ -e "$l" ] || [ -L "$l" ] || continue
        name=$(basename "$l")
        target=$(readlink "$l" 2>/dev/null)
        [ -n "$target" ] || continue
        if exists_in_image "$target"; then
            printf '  [OK]   %-26s -> %s\n' "$(basename "$d")" "$name"
            pass=$((pass + 1))
        else
            printf '  [FAIL] %-26s -> %s 目标缺失 (%s)\n' "$(basename "$d")" "$name" "$target"
            fail=$((fail + 1))
        fi
    done
done

sudo -n umount "$MNT"
rmdir "$MNT" 2>/dev/null || true

echo
echo "===== 汇总: 通过 $pass，失败 $fail ====="
[ "$fail" -eq 0 ] && echo "  所有单元引用的目标都存在" || echo "  有 $fail 处引用悬空"

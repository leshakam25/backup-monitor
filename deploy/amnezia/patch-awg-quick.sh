#!/bin/bash
# awg-quick всегда пишет sysctl src_valid_mark, а в контейнере /proc/sys только для чтения.
# Значение задаётся в docker-compose (sysctls), поэтому пишем только если оно ещё не 1.
set -euo pipefail
f="$1"
sed -i 's/^\(\s*\)\[\[ \$proto == -4 \]\] && cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1/\1[[ $proto == -4 ]] \&\& [[ $(sysctl -n net.ipv4.conf.all.src_valid_mark 2>\/dev\/null) != 1 ]] \&\& cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1/' "$f"
grep -q 'sysctl -n net.ipv4.conf.all.src_valid_mark' "$f" || { echo "patch awg-quick: шаблон не найден" >&2; exit 1; }
bash -n "$f"

#!/usr/bin/env bash
# 分片拉取真机截图：远程 adb 链路传大文件易截断，按片拉取校验后本地拼接。
# 用法: shot.sh <adb-serial> [输出.png] [截图前adb命令]
SERIAL=${1:?usage: shot.sh <adb-serial> [output.png] [pre-command]}
OUT=${2:-shot.png}
PRE=${3:-}
TMP=$(mktemp -d)
PNG_MAGIC_END=$'\xaeB\x60\x82'

adb -s "$SERIAL" shell "$PRE; screencap -p /sdcard/_shot.png; rm -f /sdcard/_shotp_*; split -b 256k /sdcard/_shot.png /sdcard/_shotp_; stat -c%s /sdcard/_shot.png; ls /sdcard/_shotp_* | wc -l" > /tmp/_shot_meta.txt 2>/dev/null
SIZE=$(head -1 /tmp/_shot_meta.txt)
NPARTS=$(sed -n 2p /tmp/_shot_meta.txt)
[ -z "$SIZE" ] || [ -z "$NPARTS" ] && { echo "截图失败"; exit 1; }

mkdir -p "$TMP"; rm -f "$TMP"/_shotp_* 2>/dev/null
LAST=$(( NPARTS - 1 ))
for i in $(seq 0 $LAST); do
  n=$(printf "%02d" $i); f="_shotp_$n"
  if [ "$i" = "$LAST" ]; then exp=$(( SIZE - 262144 * LAST )); else exp=262144; fi
  ok=0
  for t in $(seq 1 8); do
    adb -s "$SERIAL" pull "/sdcard/$f" "$TMP/$f" >/dev/null 2>&1
    sz=$(stat -c%s "$TMP/$f" 2>/dev/null || echo 0)
    [ "$sz" = "$exp" ] && { ok=1; break; }
    sleep 1
  done
  [ $ok = 1 ] && echo -n "." || { echo "FAIL $f"; exit 1; }
done
echo
cat "$TMP"/_shotp_* > "$OUT" && python3 - "$OUT" <<'EOF'
import sys
d = open(sys.argv[1], 'rb').read()
print(len(d), 'COMPLETE' if d.endswith(b'IEND\xaeB\x60\x82') else 'TRUNC')
EOF

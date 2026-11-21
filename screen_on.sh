#!/system/bin/sh
# 亮屏: 恢复正常显示。
#
# ── 两条恢复路径 ──────────────────────────────────────────────────────
# 1) 设备一直是 Awake 的(物理关屏不走 PowerManager), 只是 display power
#    mode = OFF => 直接设回 POWER_MODE_NORMAL 即可, 屏幕立刻亮。
# 2) 设备已被别的方式弄进 Dozing(如 input keyevent 26 / 手动息屏),
#    此时只设 NORMAL 不够 —— 必须先 KEYCODE_WAKEUP 把系统唤醒。
#
# ── 为什么不用 KEYCODE_SLEEP 反向 ────────────────────────────────────
#   KEYCODE_SLEEP 会让系统进 Dozing, 后续 intent 会被吞, 挂机平板
#   的实况图链路会 504。物理关屏没有这个问题。
#
# 用法:
#   adb shell su -c 'sh /data/local/tmp/screen_on.sh'
DEX=/data/local/tmp/screenpower.dex

# 若系统处于 Dozing/Asleep, 先唤醒(这一步会让屏幕亮, 是预期行为)
WAKE=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | grep -oE 'Awake|Dozing|Asleep')
if [ "$WAKE" != "Awake" ]; then
  input keyevent 224 >/dev/null 2>&1   # KEYCODE_WAKEUP
  sleep 1
fi

if [ -f "$DEX" ]; then
  OUT=$(CLASSPATH=$DEX app_process /data/local/tmp ScreenPower on 2>&1)
  case "$OUT" in
    *OK*)
      echo "SCREEN_ON $OUT"
      exit 0
      ;;
    *)
      echo "SCREEN_POWER_FAIL $OUT"
      ;;
  esac
fi

# 兜底: 唤醒 (若上面已唤醒则屏幕本就会亮)
input keyevent 224 >/dev/null 2>&1
echo "SCREEN_ON_FALLBACK"

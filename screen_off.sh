#!/system/bin/sh
# 关屏: 屏幕物理全黑, 但设备保持唤醒。
#
# ── 手动入口(2026-11-13 起服务器不再自动关屏) ────────────────────────
#   keepalive.sh 原「每 120s 黑屏兜底」已删除 —— 它会把用户刚点亮的平板
#   反复压黑。现在服务器只负责把本脚本部署到设备, **绝不执行它**。
#   用法: ① 把平板插回电源  ② adb shell sh /data/local/tmp/screen_off.sh
#   ★ 必须真插电: [0] 会校验, 没插电直接拒绝关屏并退出(见下方说明)。
#
# ── 两层机制, 互不冲突 ────────────────────────────────────────────────
# [1] 保持设备唤醒 —— 真插电 + scrcpy 官方 stay-awake(2026-11-09 定案)
#     平板物理插着电源(mPlugType!=0), 一条 Settings.Global 即可:
#         settings put global stay_on_while_plugged_in 7
#     AOSP isBeingKeptAwakeLocked(): mStayOn && mPlugType != 0 -> 恒 Awake。
#     ★ 不伪造电池状态、不制造用户活动 -> 快手 info2 正常
#       (已废弃的 userActivity 5s 轮询会让窗口抖动、打掉 info2 -> 504)。
#     ★ 设备恒 Awake, **无需任何亮屏唤醒**(无 keyevent / wakeUp)。
#
# [2] 物理关屏 (SurfaceControl.setDisplayPowerMode OFF)
#     app_process 直调 hidden API, 作用在 SurfaceFlinger 层,
#     **不经过 PowerManager** => 像素真正不发光(真黑屏), 而系统仍 Awake。
#     与 scrcpy 3.x 的 "Device display turned off" 完全一致。
#
# 为什么不能用 input keyevent 26:
#   KEYCODE_SLEEP 走 PowerManager -> mWakefulness=Dozing
#   -> Activity 被吞, 快手不发 info2 -> 必 504(2026-11-09 实测复现)。
#
# 依赖 /data/local/tmp/screenpower.dex (由服务器 keepalive.sh 自动推送)。
DEX=/data/local/tmp/screenpower.dex

# [0] 前置校验: 必须真插电。
#     stay_on_while_plugged_in 只在 mPlugType!=0 时生效。断电时跑本脚本
#     会把屏幕压黑, 但 10~15s 后掉 Dozing -> 深链被吞、快手不发 info2 -> 504,
#     而且屏幕已黑、现象很难自查。所以没插电就直接拒绝, 让用户先把线插回去。
PLUG=$(dumpsys battery 2>/dev/null | grep -iE 'AC powered|USB powered|Wireless powered' | grep -i true | head -1)
if [ -z "$PLUG" ]; then
  echo "ABORT: 未检测到插电(AC/USB/无线均为 false), 已拒绝关屏。"
  echo "       请先把平板插回电源, 再跑: sh /data/local/tmp/screen_off.sh"
  echo "       (断电时 stay_on 不生效, 黑屏后 10~15s 会 Dozing -> 504)"
  exit 1
fi
echo "PLUGGED: $PLUG"

# [1] 真插电保活(幂等)。绝不拉起 keep_awake.sh 轮询守护;
#     若发现残留守护顺手停掉, 否则它会破坏 info2。
settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1
if [ -f /data/local/tmp/keep_awake.pid ]; then
  sh /data/local/tmp/keep_awake.sh stop >/dev/null 2>&1
fi

# [2] 物理关屏
if [ -f "$DEX" ]; then
  OUT=$(CLASSPATH=$DEX app_process /data/local/tmp ScreenPower off 2>&1)
  case "$OUT" in
    *OK*)
      echo "SCREEN_OFF $OUT"
      echo "--- 挂机状态自检(约 7s) ---"
      dumpsys power 2>/dev/null | grep -E 'mPlugType=|mStayOn=|mWakefulness=' | tr -d '\r'
      echo "期望: mPlugType!=0 / mStayOn=true / mWakefulness=Awake"
      exit 0
      ;;
    *)
      echo "SCREEN_POWER_FAIL $OUT"
      ;;
  esac
fi

# 兜底: 旧方式(会进 Dozing, 深链可能 504)
input keyevent 26
echo "SCREEN_OFF_FALLBACK"

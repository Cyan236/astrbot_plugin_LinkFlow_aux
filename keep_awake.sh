#!/system/bin/sh
# keep_awake.sh —— 挂机平板「保持设备唤醒 + 物理黑屏」守护
#
# ══════════════════════════════════════════════════════════════════════
# 最终方案(2026-11-09 实测确定):
#   周期性调用 IPowerManager.userActivity(uptimeMillis, 0, 0),
#   把 framework 的 mUserActivitySummary 维持在 0x1(有活动),
#   framework 就永远不会 goToSleep -> 设备保持 mWakefulness=Awake。
#
#   配合 SurfaceControl.setDisplayPowerMode(OFF) 实现
#   "屏幕物理黑掉(powerMode=Off) + 系统保持活跃"。
#
#   ★ 不依赖插电判定, 不碰电池状态, 不伪造 AC。
#     实测 100+ 秒全程: mWakefulness=Awake, powerMode=Off(0), mPlugType=0。
#
# ── 已排除的方案(全部实测, 别再回头) ──────────────────────────────
#   · wake lock (partial/dim/bright/full): 锁拿得到但挡不住 Dozing ❌
#   · input keyevent 注入: 不计入 user activity                  ❌
#   · screen_off_timeout 拉满: 被 WindowManager override 覆盖   ❌
#   · fake AC + stay_on_while_plugged_in=7: 有效但污染电池状态  ❌
#   · scrcpy --stay-awake: 本质就是 stay_on_while_plugged_in=7   ❌
#
# ── 三个必须记住的坑 ────────────────────────────────────────────
#   1. userActivity 的 eventTime 必须是 SystemClock.uptimeMillis()!
#      用 elapsedRealtime() 或 currentTimeMillis() 都会抛
#      IllegalArgumentException("event time must not be in the future")。
#   2. 设备已在 Dozing 时, 必须先 wakeUp, 否则 userActivity 会走
#      framework 的 userActivityNoUpdateLocked 空转(不抛异常但无效)。
#   3. wakeUp 会**点亮屏幕** (powerMode Off→On), 所以唤醒后必须
#      立刻再跑一次 ScreenPower off 才能黑屏。
#
# ── 性能纪律(这个脚本在解析热路径上, 必须 < 2s) ──────────────────
#   实测各操作 adb shell 耗时:
#     dumpsys power | grep -m1 mWakefulness=      ~6.8s  ← 禁用!
#     dumpsys SurfaceFlinger | grep -m1 powerMode ~4.6s  ← 禁用!
#     逐 PID fork(cat/tr) 扫 /proc             ~11~22s ← 禁用!
#     grep -l 单次扫 /proc                       ~0.17s (但会误匹配)
#     ScreenPower state (SurfaceControl 反射)   ~0.15s ← 用这个
#     KeepAwake alive <pid> (读 PID 文件)       ~0.15s ← 用这个
#
#   之前 status 里同时用了两个 dumpsys + 逐 PID fork, 整个要 21.5s,
#   插件侧 _keep_awake('status') 的 20s 超时被打爆 -> 解析链路失败。
#   现在: PID 由 KeepAwake 进程自己写 PID 文件, 状态用反射读, 全程 < 1s。
#
# 进程模型: 单个 app_process 常驻(不套外层 while 循环)。
#   原因: 外层 shell 会持有调用方 stdout 管道, 杀它时
#         ssh/adb 调用永远等不到 EOF -> 调用卡死(实测踩过)。
#   进程意外退出由服务器端 keepalive.sh 每分钟检查并重启。
#
# 用法:
#   sh /data/local/tmp/keep_awake.sh start   # 拉起保活进程
#   sh /data/local/tmp/keep_awake.sh stop    # 停止
#   sh /data/local/tmp/keep_awake.sh status  # 查看状态
#
# 依赖: /data/local/tmp/keepawake.dex (KeepAwake 工具)
#       /data/local/tmp/screenpower.dex (ScreenPower 工具)

DEX=/data/local/tmp/keepawake.dex
SCREENDEX=/data/local/tmp/screenpower.dex
LOG=/data/local/tmp/keep_awake.log
PIDF=/data/local/tmp/keep_awake.pid
INTERVAL=5000

log() {
    echo "[$(date '+%F %T')] $*" >> $LOG
}

# 取保活进程 PID(读 PID 文件, O(1))。
# 只有 PID 校验通过(命令行确实是 app_process ... KeepAwake hold)才算数,
# 防 PID 复用 / stale 文件误判。
lock_pids() {
    [ -f "$PIDF" ] || return 0
    pid=$(cat "$PIDF" 2>/dev/null | tr -d ' \t\r\n')
    case "$pid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    OUT=$(CLASSPATH=$DEX app_process /data/local/tmp KeepAwake alive "$pid" 2>/dev/null)
    case "$OUT" in
        ALIVE*) echo "$pid" ;;
        *) rm -f "$PIDF" ;;
    esac
}

running() {
    [ -n "$(lock_pids)" ]
}

# 物理关屏。唤醒后必须调用, 否则 wakeUp 会把屏幕点亮。
#
# ⚠️ 必须后台执行且全量重定向: 同步调用 app_process 要 1~2s(冷启动 JVM),
#    而且如果它继承了调用方 stdout 管道, adb 会一直等 EOF -> 调用卡死。
screen_off() {
    [ -f "$SCREENDEX" ] || return 0
    setsid sh -c "CLASSPATH=$SCREENDEX exec app_process /data/local/tmp ScreenPower off" \
        </dev/null >/dev/null 2>&1 &
}

# 读屏幕电源状态。
#
# ⚠️ 性能(热路径, 必须 < 0.5s):
#   dumpsys SurfaceFlinger | grep -m1 powerMode      4.6s  ← 禁用
#   dumpsys SurfaceFlinger -display-id | grep ...    0.23s ← 用这个
# ⚠️ 不要在 app_process 里 fork dumpsys: 读到首行就 break 会让管道写满,
#    dumpsys 阻塞 -> waitFor() 永久等待(实测挂死)。所以只能在 shell 层做。
screen_state() {
    OUT=$(dumpsys SurfaceFlinger -display-id 2>/dev/null | grep -m1 -i powerMode)
    [ -z "$OUT" ] && OUT=$(dumpsys SurfaceFlinger 2>/dev/null | grep -m1 -i powerMode)
    echo "${OUT:-powerMode=unknown}"
}

case "$1" in
start)
    if running; then
        echo "running pids=$(lock_pids | tr '\n' ' ')"
        exit 0
    fi
    if [ ! -f $DEX ]; then
        log "ERROR: $DEX missing"
        echo "ERROR: $DEX missing"
        exit 1
    fi
    rm -f "$PIDF"
    # 关键: setsid + 全量重定向, 让进程彻底脱离当前会话,
    # 既不持有调用方的 stdout 管道, 也不随 adb shell 退出而被杀。
    setsid sh -c "CLASSPATH=$DEX exec app_process /data/local/tmp KeepAwake hold $INTERVAL" \
        </dev/null >>$LOG 2>&1 &
    # KeepAwake 自己写 PID 文件, 但要等 JVM 起来(冷启动 ~1.5s)
    sleep 2
    if running; then
        pids=$(lock_pids | tr '\n' ' ')
        # 坑 3: 保活进程启动时会 wakeUp -> 屏幕被点亮, 立刻物理关屏。
        screen_off
        log "started pids=$pids"
    else
        # 再轮询 6s(冷启动可能更慢)
        j=0
        while [ $j -lt 6 ]; do
            sleep 1
            j=$((j+1))
            if running; then break; fi
        done
        if running; then
            pids=$(lock_pids | tr '\n' ' ')
            screen_off
            log "started (late) pids=$pids"
        else
            log "FAILED to start (after $((2+j))s)"
            echo "FAILED to start"
            exit 1
        fi
    fi
    ;;
stop)
    for p in $(lock_pids); do
        kill -9 "$p" 2>/dev/null
    done
    rm -f $PIDF
    log "stopped"
    echo "stopped"
    ;;
status)
    # ⚠️ 这里只用快速操作: PID 文件 + SurfaceControl 反射。
    #    千万别加 dumpsys(单个 dumpsys 就 5~7s, 会把 20s 超时打爆)。
    if running; then
        echo "running pids=$(lock_pids | tr '\n' ' ')"
    else
        echo "not running"
    fi
    screen_state
    ;;
*)
    echo "usage: $0 start|stop|status"
    exit 1
    ;;
esac

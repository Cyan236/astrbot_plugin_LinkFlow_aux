import java.lang.reflect.Method;

import android.os.IBinder;
import android.os.SystemClock;

/**
 * KeepAwake —— 挂机平板「保持设备唤醒 + 物理黑屏」保活工具。
 *
 * ══════════════════════════════════════════════════════════════════════
 * 最终方案(2026-11-09 实测确定, 取代此前所有尝试):
 *
 *   核心机制: IPowerManager.userActivity(long, int, int) —— 周期上报用户活动
 *
 *   AOSP Dozing 判定链:
 *     mUserActivitySummary == USER_ACTIVITY_SUMMARY_USER_ACTIVITY_ENDED (0x4)
 *       → goToSleep() → mWakefulness = Dozing → App 被限速/深链被吞
 *   只要周期性把 mUserActivitySummary 维持在 0x1(有活动),
 *   framework 就永远不会 goToSleep, 设备保持 mWakefulness=Awake。
 *
 *   ⚠️ 三个关键坑(都是实测踩出来的, 别改):
 *
 *   1. eventTime 口径必须是 SystemClock.uptimeMillis(), 不是 elapsedRealtime!
 *      PowerManagerService.userActivity 校验 eventTime <= uptimeMillis,
 *      超了直接抛 IllegalArgumentException("event time must not be in the future")。
 *      · elapsedRealtime() 含 deep sleep 时间, 远大于 uptimeMillis → 必被拒
 *      · currentTimeMillis() 是 wall clock (1.79e12) → 也必被拒
 *      · 只有 uptimeMillis() 通过 (实测二分边界正好落在 uptimeMillis 上)
 *
 *   2. 必须先 wakeUp 再轮询。
 *      设备已在 Dozing 时, 直接调 userActivity 会走 framework 的
 *      "userActivityNoUpdateLocked" 分支 —— 调用成功、不抛异常, 但
 *      mUserActivitySummary 纹丝不动 (logcat 里能看到这个分支名)。
 *      先 wakeUp 把设备拉回 Awake, 后续 userActivity 才会真正更新 summary。
 *      ⚠️ wakeUp 会**点亮屏幕** (powerMode Off→On), 所以唤醒后必须
 *              再调一次 ScreenPower off 才能物理黑屏。
 *
 *   3. 屏幕状态与设备状态是两条独立的线:
 *      · SurfaceControl.setDisplayPowerMode(OFF) → 像素真黑 (powerMode=Off)
 *      · userActivity 轮询 → framework 保持 Awake
 *      两者叠加实测: 100+ 秒全程 mWakefulness=Awake + powerMode=Off(0),
 *      且 mPlugType=0(真没插电), 电池状态零污染。
 *
 * ══════════════════════════════════════════════════════════════════════
 * 与其它方案对比(全部实测, 勿再回头):
 *   · wake lock (partial/dim/bright/full): 锁拿得到(logcat 有
 *     acquireWakeLockInternal 记录), 但 mWakeLockSummary 不含阻止
 *     Dozing 的位 → 照样 Dozing。❌
 *   · input keyevent 注入: 不计入 user activity。❌
 *   · screen_off_timeout 拉满: 被 mUserActivityTimeoutOverrideFromWindowManager
 *     (10000ms) 覆盖。❌
 *   · fake AC + stay_on_while_plugged_in=7: 有效, 但污染电池状态
 *     (图标显示充电中) → 用户明确不接受。❌
 *   · scrcpy --stay-awake: 就是 stay_on_while_plugged_in=7, 同样依赖插电判定。❌
 *
 * 用法:
 *   app_process /data/local/tmp KeepAwake hold            # 常驻保活(默认 5s 间隔)
 *   app_process /data/local/tmp KeepAwake hold 3          # 3s 间隔
 *   app_process /data/local/tmp KeepAwake status          # 只打印当前状态
 *   app_process /data/local/tmp KeepAwake probe          # 枚举 IPowerManager
 *
 * 进程模型: 单个 app_process 常驻, 由设备端 keep_awake.sh 守护拉起;
 *           进程意外退出由服务器端 keepalive.sh 每分钟检查并重启。
 */
public class KeepAwake {

    /** 默认轮询间隔(ms)。必须显著小于 user activity timeout(实测 15s)。 */
    private static final long DEFAULT_INTERVAL_MS = 5000L;

    private static Object sSvc;
    private static Class<?> sIface;

    public static void main(String[] args) throws Exception {
        String mode = args.length > 0 ? args[0] : "status";
        sIface = Class.forName("android.os.IPowerManager");
        sSvc = powerService();

        if ("probe".equals(mode)) {
            probe();
            return;
        }
        if ("status".equals(mode)) {
            System.out.println("isPowered      = " + callBool("isPowered"));
            System.out.println("isInteractive  = " + callBool("isInteractive"));
            System.out.println("isDeviceIdle   = " + callBool("isDeviceIdleMode"));
            return;
        }
        if ("hold".equals(mode)) {
            long interval = args.length > 1 ? Long.parseLong(args[1]) : DEFAULT_INTERVAL_MS;
            hold(interval);
            return;
        }
        System.out.println("usage: KeepAwake hold [intervalMs] | status | probe");
    }

    private static void probe() {
        for (Method m : sIface.getMethods()) {
            String n = m.getName();
            if (n.equals("userActivity") || n.equals("wakeUp")
                    || n.equals("goToSleep") || n.equals("nap")
                    || n.equals("setDozeAfterScreenOff")
                    || n.equals("isPowered") || n.equals("isInteractive")
                    || n.equals("setStayOnSetting")) {
                System.out.println("  " + n + " "
                        + java.util.Arrays.toString(m.getParameterTypes()));
            }
        }
    }

    /**
     * 常驻保活: 先 wakeUp, 然后周期上报 userActivity。
     *
     * @param intervalMs 轮询间隔, 必须 < user activity timeout(实测 15s)
     */
    private static void hold(long intervalMs) throws Exception {
        // Step 1: 唤醒。必须在 Dozing -> Awake 时先把设备拉出来,
        //          否则后续 userActivity 会走 userActivityNoUpdateLocked 空转。
        // ⚠️ wakeUp 会点亮屏幕 —— 调用方负责在之后执行 ScreenPower off。
        try {
            call("wakeUp",
                    new Class<?>[]{long.class, int.class, String.class, String.class},
                    new Object[]{SystemClock.uptimeMillis(), 0, "keepawake", "keepawake"});
            System.out.println("HOLD awake, interval=" + intervalMs + "ms");
        } catch (Throwable t) {
            System.out.println("HOLD wakeUp failed (继续尝试 userActivity): " + t);
        }

        long n = 0;
        while (true) {
            try {
                // eventTime 必须用 uptimeMillis —— 见类注释「坑 1」。
                call("userActivity",
                        new Class<?>[]{long.class, int.class, int.class},
                        new Object[]{SystemClock.uptimeMillis(), 0, 0});
                n++;
                if (n % 60 == 0) {
                    System.out.println("HOLD alive, calls=" + n);
                }
            } catch (Throwable t) {
                System.out.println("HOLD userActivity failed: " + t);
            }
            Thread.sleep(intervalMs);
        }
    }

    private static Object callBool(String name) {
        try {
            Method m = null;
            for (Method x : sIface.getMethods()) {
                if (x.getName().equals(name)) m = x;
            }
            if (m == null) return "<no method>";
            return m.invoke(sSvc, new Object[0]);
        } catch (Throwable t) {
            return "ERR " + t;
        }
    }

    private static Object call(String name, Class<?>[] pt, Object[] argv) throws Exception {
        Method m = null;
        for (Method x : sIface.getMethods()) {
            if (x.getName().equals(name)
                    && java.util.Arrays.equals(x.getParameterTypes(), pt)) {
                m = x;
                break;
            }
        }
        if (m == null) throw new NoSuchMethodException(name);
        return m.invoke(sSvc, argv);
    }

    private static Object powerService() throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Method getService = sm.getDeclaredMethod("getService", String.class);
        getService.setAccessible(true);
        IBinder binder = (IBinder) getService.invoke(null, "power");
        Class<?> stub = Class.forName("android.os.IPowerManager$Stub");
        Method asInterface = stub.getDeclaredMethod("asInterface", IBinder.class);
        asInterface.setAccessible(true);
        return asInterface.invoke(null, binder);
    }
}

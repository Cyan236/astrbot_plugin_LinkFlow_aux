// 用 app_process 直调 SurfaceControl.setDisplayPowerMode, 物理关屏但系统保持活跃。
// 参照 scrcpy server/src/main/java/com/genymobile/scrcpy/device/Device.java:
//   Android 10+ (API29): 遍历 getPhysicalDisplayIds(), 取 getPhysicalDisplayToken(id),
//   再 setDisplayPowerMode(token, mode); 更老版本用 getBuiltInDisplay().
// 注意 setDisplayPowerMode 是 private static, 必须 getDeclaredMethod + setAccessible.
// mode: 0 = POWER_MODE_OFF (物理黑屏), 2 = POWER_MODE_NORMAL (恢复)
//
// 用法:
//   CLASSPATH=/data/local/tmp/screenpower.dex app_process /data/local/tmp ScreenPower probe
//   CLASSPATH=/data/local/tmp/screenpower.dex app_process /data/local/tmp ScreenPower off
//   CLASSPATH=/data/local/tmp/screenpower.dex app_process /data/local/tmp ScreenPower on
//   CLASSPATH=/data/local/tmp/screenpower.dex app_process /data/local/tmp ScreenPower state
import java.lang.reflect.Method;

public class ScreenPower {
    private static final int POWER_MODE_OFF = 0;
    private static final int POWER_MODE_NORMAL = 2;

    public static void main(String[] args) throws Exception {
        String cmd = args.length > 0 ? args[0] : "probe";
        Class<?> sc = Class.forName("android.view.SurfaceControl");

        Method getIds = declared(sc, "getPhysicalDisplayIds");
        Method getToken = declared(sc, "getPhysicalDisplayToken", long.class);
        Method setMode = declared(sc, "setDisplayPowerMode", android.os.IBinder.class, int.class);

        if ("probe".equals(cmd)) {
            // 只探测能力, 不改任何状态
            long[] ids = (long[]) getIds.invoke(null);
            System.out.println("PROBE OK displays=" + ids.length
                    + " hasSetDisplayPowerMode=true hasGetPhysicalDisplayToken=true");
            return;
        }

        if ("state".equals(cmd)) {
            // 读当前电源状态(只走反射, 绝不 fork 外部进程)。
            //
            // ⚠️ 踩过的坑:
            //   1) dumpsys SurfaceFlinger | grep powerMode 要 4.6s
            //      (dumpsys SF 输出巨大, grep 得等管道读完) —— 禁用。
            //   2) 在 app_process 里用 ProcessBuilder fork dumpsys 会**死锁**:
            //      读到第一行就 break -> 管道写满 -> dumpsys 阻塞 ->
            //      waitFor() 永久等待(实测挂死 3 分钟)。
            //      所以 Java 侧只能反射, dumpsys 由外层 shell 兜底。
            //   3) 快的做法是 `dumpsys SurfaceFlinger -display-id | grep -m1 powerMode`
            //      —— 实测 0.23s, 由 keep_awake.sh 在 shell 层执行。
            //
            // 本子命令只做能力探测, 供脚本判断 ROM 是否支持读状态。
            long[] ids = (long[]) getIds.invoke(null);
            boolean hasGetter = false;
            try {
                Class<?> sc2 = Class.forName("android.view.SurfaceControl");
                sc2.getDeclaredMethod("getDisplayPowerMode", android.os.IBinder.class);
                hasGetter = true;
            } catch (Throwable t) {
                hasGetter = false;
            }
            System.out.println("STATE displays=" + ids.length
                    + " hasGetDisplayPowerMode=" + hasGetter);
            return;
        }

        boolean on = "on".equals(cmd);
        int mode = on ? POWER_MODE_NORMAL : POWER_MODE_OFF;

        long[] ids = (long[]) getIds.invoke(null);
        boolean ok = false;
        for (long id : ids) {
            Object token = getToken.invoke(null, id);
            if (token == null) continue;
            setMode.invoke(null, token, mode);
            ok = true;
        }
        if (!ok) {
            System.out.println("FAIL no physical display token");
            System.exit(2);
        }
        System.out.println("OK displays=" + ids.length + " mode=" + mode);
    }

    private static Method declared(Class<?> c, String name, Class<?>... args) throws Exception {
        Method m = c.getDeclaredMethod(name, args);
        m.setAccessible(true);
        return m;
    }
}

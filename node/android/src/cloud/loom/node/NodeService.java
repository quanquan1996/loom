package cloud.loom.node;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.File;
import java.util.Map;

/** A foreground service that supervises the embedded loom-node daemon: the same
 *  "run it, if it dies wait and run it again" loop the Termux boot script did,
 *  but as a real Android service with a persistent notification and a wake-lock
 *  — the legitimate keep-alive path (what WeChat/PDD use). */
public class NodeService extends Service {

    private static final String CHANNEL = "loom-node";
    private static final int NOTE_ID = 1;

    private volatile boolean running = false;
    private Process proc;
    private PowerManager.WakeLock wake;

    static void start(Context c) {
        Intent i = new Intent(c, NodeService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i);
        else c.startService(i);
    }

    static void stop(Context c) {
        c.stopService(new Intent(c, NodeService.class));
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (running) return START_STICKY;
        running = true;
        startForeground(NOTE_ID, buildNotification());
        acquireWake();
        new Thread(this::supervise, "loom-node-supervisor").start();
        return START_STICKY;
    }

    private void supervise() {
        File bin = Config.binary(this);
        File log = Config.logFile(this);
        log.getParentFile().mkdirs();
        while (running) {
            if (!Config.configured(this)) { // device was removed in Loom
                stopSelf();
                return;
            }
            try {
                ProcessBuilder pb = new ProcessBuilder(bin.getAbsolutePath(), "daemon");
                pb.directory(Config.home(this));
                pb.redirectErrorStream(true);
                pb.redirectOutput(ProcessBuilder.Redirect.appendTo(log));
                Map<String, String> env = pb.environment();
                env.put("HOME", Config.home(this).getAbsolutePath());
                env.put("TMPDIR", getCacheDir().getAbsolutePath());
                // getprop (for DNS) and the shell live here:
                env.put("PATH", "/system/bin:/system/xbin");
                proc = pb.start();
                proc.waitFor();
            } catch (Exception ignored) {
            }
            if (!running) return;
            try { Thread.sleep(5000); } catch (InterruptedException e) { return; }
        }
    }

    private void acquireWake() {
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null) {
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "loom-node:daemon");
            wake.setReferenceCounted(false);
            wake.acquire();
        }
    }

    private Notification buildNotification() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL, "Loom Node", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        Notification.Builder b = (Build.VERSION.SDK_INT >= 26)
                ? new Notification.Builder(this, CHANNEL)
                : new Notification.Builder(this);
        return b.setContentTitle("Loom Node")
                .setContentText("节点在线，供 Loom 远程调用")
                .setSmallIcon(R.drawable.ic_launcher)
                .setOngoing(true)
                .build();
    }

    @Override public void onDestroy() {
        running = false;
        if (proc != null) proc.destroy();
        if (wake != null && wake.isHeld()) wake.release();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}

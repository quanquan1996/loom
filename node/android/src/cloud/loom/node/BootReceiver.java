package cloud.loom.node;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Brings the node back after a reboot or an app update, without Termux:Boot —
 *  only if it was ever configured. */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent intent) {
        if (Config.configured(c)) NodeService.start(c);
    }
}

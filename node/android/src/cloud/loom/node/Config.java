package cloud.loom.node;

import android.content.Context;
import java.io.File;

/** Where the embedded loom-node daemon reads its config and writes its state.
 *  The daemon computes these from $HOME (os.UserHomeDir), so we point $HOME at
 *  the app's private files dir and mirror the same layout here. */
final class Config {
    static File home(Context c) { return c.getFilesDir(); }

    static File configFile(Context c) {
        return new File(home(c), ".config/loom-node/config.json");
    }

    static File logFile(Context c) {
        return new File(home(c), ".local/state/loom-node/daemon.log");
    }

    static File binary(Context c) {
        // The only place on modern Android an app may exec a bundled executable:
        // its extracted native-library dir (not subject to the W^X exec ban).
        return new File(c.getApplicationInfo().nativeLibraryDir, "libloomnode.so");
    }

    static boolean configured(Context c) {
        File f = configFile(c);
        return f.exists() && f.length() > 0;
    }
}

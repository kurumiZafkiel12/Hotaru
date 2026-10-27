import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.os.Looper;

public final class AndroidArchiveProbe {
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread = activityThread.getMethod("systemMain").invoke(null);
        Context context = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        PackageManager manager = context.getPackageManager();
        for (String path : args) {
            PackageInfo info = manager.getPackageArchiveInfo(path,
                PackageManager.GET_ACTIVITIES | PackageManager.GET_SERVICES |
                PackageManager.GET_META_DATA | PackageManager.GET_SIGNATURES);
            if (info == null) throw new AssertionError("packageInfo is null: " + path);
            ApplicationInfo application = info.applicationInfo;
            application.sourceDir = path;
            application.publicSourceDir = path;
            Resources resources = manager.getResourcesForApplication(application);
            manager.getApplicationIcon(application).getIntrinsicWidth();
            resources.newTheme().applyStyle(application.theme, true);
            if (info.activities != null) {
                for (android.content.pm.ActivityInfo activity : info.activities) {
                    resources.newTheme().applyStyle(activity.getThemeResource(), true);
                }
            }
            if (!"dev.hotaru.hotaru".equals(info.packageName)) {
                throw new AssertionError("Unexpected package: " + info.packageName);
            }
            System.out.println("ARCHIVE_OK " + path + " " + info.packageName + " " + info.versionName);
        }
        System.exit(0);
    }
}

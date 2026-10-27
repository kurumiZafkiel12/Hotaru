package dev.hotaru.hotaru

import android.animation.ValueAnimator
import android.os.Bundle
import android.os.Build
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import dev.hotaru.hotaru.plugins.AppPlugin
import dev.hotaru.hotaru.plugins.BatteryPlugin
import dev.hotaru.hotaru.plugins.ServicePlugin
import dev.hotaru.hotaru.plugins.TilePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        splash.setOnExitAnimationListener { provider ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !ValueAnimator.areAnimatorsEnabled()) {
                provider.remove()
            } else {
                provider.view.animate()
                    .alpha(0f)
                    .scaleX(0.96f)
                    .scaleY(0.96f)
                    .setDuration(250)
                    .withEndAction { provider.remove() }
                    .start()
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AppPlugin())
        flutterEngine.plugins.add(BatteryPlugin())
        flutterEngine.plugins.add(ServicePlugin())
        flutterEngine.plugins.add(TilePlugin())
        ServiceState.attachFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        flutterEngine?.let(ServiceState::detachFlutterEngine)
        super.onDestroy()
    }
}

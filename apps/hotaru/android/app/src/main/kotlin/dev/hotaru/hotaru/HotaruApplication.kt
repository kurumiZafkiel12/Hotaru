package dev.hotaru.hotaru

import android.app.Application
import android.content.Context
import dev.hotaru.hotaru.common.GlobalState

class HotaruApplication : Application() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        GlobalState.init(this)
    }
}

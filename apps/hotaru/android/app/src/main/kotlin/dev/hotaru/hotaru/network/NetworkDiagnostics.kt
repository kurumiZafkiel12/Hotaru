package dev.hotaru.hotaru.network

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings

object NetworkDiagnostics {
    fun snapshot(context: Context): Map<String, Any?> {
        return try {
            val manager = context.getSystemService(ConnectivityManager::class.java)
                ?: return unavailable("unavailable")
            val network = manager.activeNetwork
            val capabilities = network?.let(manager::getNetworkCapabilities)
            val links = network?.let(manager::getLinkProperties)
            linkedMapOf<String, Any?>(
                "readable" to true,
                "api" to Build.VERSION.SDK_INT,
                "active" to (network != null),
                "vpn" to capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN),
                "validated" to capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                "captive-portal" to capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
                "metered" to network?.let { manager.isActiveNetworkMetered },
                "transports" to listOf(
                    NetworkCapabilities.TRANSPORT_WIFI to "wifi",
                    NetworkCapabilities.TRANSPORT_CELLULAR to "cellular",
                    NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet",
                    NetworkCapabilities.TRANSPORT_VPN to "vpn",
                    NetworkCapabilities.TRANSPORT_BLUETOOTH to "bluetooth",
                ).filter { capabilities?.hasTransport(it.first) == true }.map { it.second },
                "dns-servers" to links?.dnsServers?.mapNotNull { it.hostAddress }.orEmpty(),
                "mtu" to links?.mtu?.takeIf { it > 0 },
            ).apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    put("private-dns-active", links?.isPrivateDnsActive)
                    put("private-dns-name", links?.privateDnsServerName)
                }
            }
        } catch (_: SecurityException) {
            unavailable("permission")
        } catch (_: RuntimeException) {
            unavailable("unavailable")
        }
    }

    private fun unavailable(reason: String): Map<String, Any?> = mapOf(
        "readable" to false,
        "api" to Build.VERSION.SDK_INT,
        "reason" to reason,
    )

    fun openSettings(activity: Activity?, page: String?): Boolean {
        if (activity == null) return false
        val action = when (page) {
            "vpn" -> Settings.ACTION_VPN_SETTINGS
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "private-dns" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                "android.settings.PRIVATE_DNS_SETTINGS"
            } else {
                return false
            }
            else -> return false
        }
        for (candidate in listOf(action, Settings.ACTION_WIRELESS_SETTINGS)) {
            try {
                activity.startActivity(Intent(candidate))
                return true
            } catch (_: Exception) {
                // Some vendors omit a settings activity; the network page remains useful.
            }
        }
        return false
    }
}

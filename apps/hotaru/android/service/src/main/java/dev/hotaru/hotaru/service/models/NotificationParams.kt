package dev.hotaru.hotaru.service.models

data class NotificationParams(
    val title: String = "Hotaru",
    val stopText: String = "STOP",
    val onlyStatisticsProxy: Boolean = false,
    val showStopAction: Boolean = true,
)

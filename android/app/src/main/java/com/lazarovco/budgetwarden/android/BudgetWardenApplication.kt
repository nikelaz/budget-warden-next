package com.lazarovco.budgetwarden.android

import android.app.Application
import com.lazarovco.budgetwarden.core.FfiException
import com.lazarovco.budgetwarden.core.initializeCoreWithClockFloor
import java.util.UUID

class BudgetWardenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        val deviceId = preferences.getString(DEVICE_ID_KEY, null)
            ?.let(UUID::fromString)
            ?: UUID.randomUUID().also { generated ->
                check(preferences.edit().putString(DEVICE_ID_KEY, generated.toString()).commit()) {
                    "Could not persist the device identity."
                }
            }

        try {
            initializeCoreWithClockFloor(
                deviceId,
                preferences.getLong(CLOCK_PHYSICAL_MS_KEY, 0L),
                preferences.getInt(CLOCK_LOGICAL_KEY, 0),
            )
        } catch (error: FfiException) {
            check(error.message == "Rust core is already initialized") { error.message.orEmpty() }
        }
    }

    companion object {
        const val PREFERENCES_NAME = "budget_warden"
        private const val DEVICE_ID_KEY = "device_id"
        const val CLOCK_PHYSICAL_MS_KEY = "clock_physical_ms"
        const val CLOCK_LOGICAL_KEY = "clock_logical"
    }
}

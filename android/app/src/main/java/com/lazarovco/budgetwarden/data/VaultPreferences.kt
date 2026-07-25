package com.lazarovco.budgetwarden.data

import android.content.Context

enum class VaultType { GOOGLE_DRIVE, LOCAL }

class VaultPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("budget_warden", Context.MODE_PRIVATE)

    var vaultType: VaultType
        get() = runCatching {
            VaultType.valueOf(preferences.getString(KEY_VAULT_TYPE, null) ?: VaultType.GOOGLE_DRIVE.name)
        }.getOrDefault(VaultType.GOOGLE_DRIVE)
        set(value) { preferences.edit().putString(KEY_VAULT_TYPE, value.name).apply() }

    var accountEmail: String?
        get() = preferences.getString(KEY_ACCOUNT_EMAIL, null)
        set(value) { preferences.edit().putString(KEY_ACCOUNT_EMAIL, value).apply() }

    var driveConnected: Boolean
        get() = preferences.getBoolean(KEY_DRIVE_CONNECTED, false)
        set(value) { preferences.edit().putBoolean(KEY_DRIVE_CONNECTED, value).apply() }

    companion object {
        private const val KEY_VAULT_TYPE = "vault_type"
        private const val KEY_ACCOUNT_EMAIL = "drive_account_email"
        private const val KEY_DRIVE_CONNECTED = "drive_connected"
    }
}

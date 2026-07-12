package com.lazarovco.budgetwarden

import android.app.Application
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.lazarovco.budgetwarden.data.VaultDatabase
import com.lazarovco.budgetwarden.data.VaultPreferences
import com.lazarovco.budgetwarden.data.VaultSyncWorker
import java.util.concurrent.TimeUnit

class BudgetWardenApplication : Application() {
    val vaultDatabase by lazy { VaultDatabase.create(this) }
    val vaultPreferences by lazy { VaultPreferences(this) }

    override fun onCreate() {
        super.onCreate()
        val request = PeriodicWorkRequestBuilder<VaultSyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).build())
            .build()
        WorkManager.getInstance(this).enqueueUniquePeriodicWork("drive-vault-sync", ExistingPeriodicWorkPolicy.UPDATE, request)
    }
}

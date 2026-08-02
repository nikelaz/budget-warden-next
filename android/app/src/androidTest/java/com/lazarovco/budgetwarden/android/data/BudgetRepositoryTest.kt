package com.lazarovco.budgetwarden.android.data

import android.content.Context
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import com.lazarovco.budgetwarden.android.BudgetWardenApplication
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class BudgetRepositoryTest {
    @Test
    fun transientProviderFailureDoesNotPruneRecentUri() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences(
            BudgetWardenApplication.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        val original = preferences.getString(RECENT_FILES_KEY, null)
        val unavailableUri = Uri.parse("content://${UUID.randomUUID()}/offline.budget")
        preferences.edit().putString(RECENT_FILES_KEY, unavailableUri.toString()).commit()

        try {
            val repository = BudgetRepository(context, Dispatchers.Unconfined)

            assertThat(repository.loadStoredBudgets()).isEmpty()
            assertThat(preferences.getString(RECENT_FILES_KEY, null))
                .isEqualTo(unavailableUri.toString())
        } finally {
            val editor = preferences.edit()
            if (original == null) {
                editor.remove(RECENT_FILES_KEY)
            } else {
                editor.putString(RECENT_FILES_KEY, original)
            }
            editor.commit()
        }
    }

    private companion object {
        const val RECENT_FILES_KEY = "recent_budget_uris_v1"
    }
}

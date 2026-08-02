package com.lazarovco.budgetwarden.android.data

import android.net.Uri
import android.util.AtomicFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import java.io.File
import java.util.UUID
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class BudgetRecoveryStoreTest {
    @Test
    fun writeAtomicallyReplacesPreviousRecoverySnapshot() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "recovery-test-${UUID.randomUUID()}")
        val store = BudgetRecoveryStore(context, directory)
        val uri = Uri.parse("content://tests/atomic.budget")

        try {
            store.write(uri, "first")
            store.write(uri, "second")

            assertThat(store.read(uri)).isEqualTo("second")
            assertThat(directory.listFiles()).hasLength(1)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun deleteRemovesRecoverySnapshot() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "recovery-test-${UUID.randomUUID()}")
        val store = BudgetRecoveryStore(context, directory)
        val uri = Uri.parse("content://tests/deleted.budget")

        try {
            store.write(uri, "budget")
            store.delete(uri)

            assertThat(store.read(uri)).isNull()
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun failedReplacementRestoresPreviousRecoverySnapshot() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "recovery-test-${UUID.randomUUID()}")
        val store = BudgetRecoveryStore(context, directory)
        val uri = Uri.parse("content://tests/interrupted.budget")

        try {
            store.write(uri, "complete")
            val baseFile = checkNotNull(directory.listFiles()?.single())
            val atomicFile = AtomicFile(baseFile)
            val interrupted = atomicFile.startWrite()
            interrupted.write("partial".toByteArray())
            atomicFile.failWrite(interrupted)

            assertThat(store.read(uri)).isEqualTo("complete")
        } finally {
            directory.deleteRecursively()
        }
    }
}

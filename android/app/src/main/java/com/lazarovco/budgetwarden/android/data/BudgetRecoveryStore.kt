package com.lazarovco.budgetwarden.android.data

import android.content.Context
import android.net.Uri
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.security.MessageDigest

internal class BudgetRecoveryStore(
    context: Context,
    private val directory: File = File(context.noBackupFilesDir, RECOVERY_DIRECTORY),
) {
    @Synchronized
    fun write(uri: Uri, json: String) {
        check(directory.isDirectory || directory.mkdirs()) {
            "Could not create the budget recovery directory."
        }

        val file = atomicFile(uri)
        var output: FileOutputStream? = null
        try {
            output = file.startWrite()
            output.write(json.toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (error: Exception) {
            output?.let(file::failWrite)
            throw error
        }
    }

    @Synchronized
    fun read(uri: Uri): String? {
        val file = atomicFile(uri)
        return try {
            file.openRead().bufferedReader(Charsets.UTF_8).use { it.readText() }
        } catch (_: FileNotFoundException) {
            null
        }
    }

    @Synchronized
    fun delete(uri: Uri) {
        atomicFile(uri).delete()
    }

    private fun atomicFile(uri: Uri): AtomicFile = AtomicFile(
        File(directory, "${uri.recoveryKey()}.budget"),
    )

    private fun Uri.recoveryKey(): String = MessageDigest
        .getInstance("SHA-256")
        .digest(toString().toByteArray(Charsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private companion object {
        const val RECOVERY_DIRECTORY = "budget-recovery"
    }
}

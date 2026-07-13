package com.lazarovco.budgetwarden.data

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.lazarovco.budgetwarden.BudgetWardenApplication
import com.lazarovco.budgetwarden.domain.BudgetCrdt
import org.json.JSONObject
import java.io.File

class VaultSyncEngine(private val context: Context) {
    private val application = context.applicationContext as BudgetWardenApplication
    private val dao = application.vaultDatabase.vaultFiles()
    private val preferences = application.vaultPreferences
    private val drive = GoogleDriveClient()
    private val localDirectory = File(context.filesDir, "Google Drive Vault Cache").apply { mkdirs() }

    suspend fun sync(token: String) {
        val folderId = drive.findOrCreateVault(token)
        deletePending(token)
        cacheUntrackedLocalFiles()
        val remoteFiles = drive.listVaultFiles(token, folderId)
        remoteFiles.forEach { remote ->
            val known = dao.byDriveId(remote.id)
            val destination = File(localDirectory, safeName(remote.name))
            if (known?.syncState == "PENDING_UPLOAD") {
                if (remote.version > (known.driveVersion ?: 0) && destination.exists()) {
                    rebasePendingFile(token, remote, known, destination)
                }
                return@forEach
            }
            if (known == null || remote.version > (known.driveVersion ?: 0) || !destination.exists()) {
                drive.download(token, remote.id, destination)
            }
            val budgetId = runCatching { JSONObject(destination.readText()).getString("id") }.getOrElse { remote.id }
            dao.upsert(listOf(VaultFileEntity(
                budgetId, remote.id, remote.name, destination.absolutePath, remote.ownerEmail, remote.sharedWithMe,
                remote.modifiedTime, remote.version, "SYNCED", null,
            )))
        }
        uploadPending(token, folderId)
        if (remoteFiles.isNotEmpty()) dao.deleteRemoteFilesExcept(remoteFiles.map(DriveFile::id))
    }

    private suspend fun rebasePendingFile(token: String, remote: DriveFile, cached: VaultFileEntity, localFile: File) {
        val remoteFile = File.createTempFile("budget-remote-", ".budget", context.cacheDir)
        try {
            drive.download(token, remote.id, remoteFile)
            val repository = BudgetRepository(context)
            BudgetFileLocks.withLock(localFile) {
                val inMemory = repository.decodeBudget(localFile.readText(), localFile.name)
                val onDisk = repository.decodeBudget(remoteFile.readText(), localFile.name)
                val normalized = repository.normalizeActualAmounts(BudgetCrdt.merge(inMemory, onDisk))
                localFile.writeText(repository.encodeBudget(normalized))
            }
            dao.upsert(listOf(cached.copy(
                modifiedTime = localFile.lastModified(),
                driveVersion = remote.version,
                pendingOperation = null,
            )))
        } finally {
            remoteFile.delete()
        }
    }

    private suspend fun deletePending(token: String) {
        dao.all().filter { it.syncState == "PENDING_DELETE" }.forEach { cached ->
            cached.driveFileId?.let { drive.trash(token, it) }
            dao.delete(cached.budgetId)
        }
    }

    private suspend fun cacheUntrackedLocalFiles() {
        val repository = BudgetRepository(context)
        localDirectory.listFiles { file -> file.isFile && file.extension.equals("budget", true) }.orEmpty().forEach { file ->
            val budgetId = runCatching { JSONObject(file.readText()).getString("id") }.getOrNull() ?: return@forEach
            if (dao.byBudgetId(budgetId) == null) {
                dao.upsert(listOf(VaultFileEntity(
                    budgetId, null, file.name, file.absolutePath, preferences.accountEmail, false,
                    file.lastModified(), null, "PENDING_UPLOAD", null,
                )))
            }
        }
    }

    suspend fun share(budgetId: String, email: String, token: String) {
        val file = dao.byBudgetId(budgetId) ?: error("Budget is not in the Drive vault yet.")
        drive.share(token, file.driveFileId ?: error("Budget upload has not completed yet."), email.trim())
    }

    private suspend fun uploadPending(token: String, folderId: String) {
        dao.all().filter { cached ->
            cached.syncState == "PENDING_UPLOAD" && File(cached.localPath).parentFile == localDirectory
        }.forEach { cached ->
            val file = File(cached.localPath)
            if (file.exists()) {
                val remote = drive.upload(token, folderId, file, cached.driveFileId)
                dao.upsert(listOf(cached.copy(
                    driveFileId = remote.id, modifiedTime = remote.modifiedTime, driveVersion = remote.version,
                    syncState = "SYNCED", pendingOperation = null,
                )))
            }
        }
    }

    private fun safeName(name: String): String = name.replace(Regex("""[/\\?%*|\"<>:\p{Cntrl}]"""), "-")
}

class VaultSyncWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val application = applicationContext as BudgetWardenApplication
        if (!application.vaultPreferences.driveConnected) return Result.success()
        val authorization = runCatching { DriveAuthorizer(applicationContext).authorize(application.vaultPreferences.accountEmail) }
            .getOrElse { return Result.retry() }
        if (authorization !is DriveAuthorization.Authorized) return Result.retry()
        application.vaultPreferences.accountEmail = authorization.email
        return runCatching { VaultSyncEngine(applicationContext).sync(authorization.token); Result.success() }.getOrElse { Result.retry() }
    }

    companion object {
        fun enqueue(context: Context) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                "drive-vault-sync-now", ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<VaultSyncWorker>().build(),
            )
        }
    }
}

package com.lazarovco.budgetwarden.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Upsert
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "vault_files")
data class VaultFileEntity(
    @PrimaryKey val budgetId: String,
    val driveFileId: String?,
    val name: String,
    val localPath: String,
    val ownerEmail: String?,
    val isSharedWithMe: Boolean,
    val modifiedTime: Long,
    val driveVersion: Long?,
    val syncState: String,
    val pendingOperation: String?,
)

@Dao
interface VaultFileDao {
    @Query("SELECT * FROM vault_files ORDER BY lower(name)")
    fun observeAll(): Flow<List<VaultFileEntity>>

    @Query("SELECT * FROM vault_files")
    suspend fun all(): List<VaultFileEntity>

    @Query("SELECT * FROM vault_files WHERE budgetId = :budgetId LIMIT 1")
    suspend fun byBudgetId(budgetId: String): VaultFileEntity?

    @Query("SELECT * FROM vault_files WHERE driveFileId = :driveFileId LIMIT 1")
    suspend fun byDriveId(driveFileId: String): VaultFileEntity?

    @Upsert
    suspend fun upsert(files: List<VaultFileEntity>)

    @Query("DELETE FROM vault_files WHERE driveFileId IS NOT NULL AND driveFileId NOT IN (:ids)")
    suspend fun deleteRemoteFilesExcept(ids: List<String>)

    @Query("DELETE FROM vault_files WHERE budgetId = :budgetId")
    suspend fun delete(budgetId: String)
}

@Database(entities = [VaultFileEntity::class], version = 2, exportSchema = true)
abstract class VaultDatabase : RoomDatabase() {
    abstract fun vaultFiles(): VaultFileDao

    companion object {
        fun create(context: Context): VaultDatabase = Room.databaseBuilder(
            context.applicationContext,
            VaultDatabase::class.java,
            "budget-warden-vault.db",
        ).addMigrations(MIGRATION_1_2).build()

        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE vault_files ADD COLUMN pendingOperation TEXT")
            }
        }
    }
}

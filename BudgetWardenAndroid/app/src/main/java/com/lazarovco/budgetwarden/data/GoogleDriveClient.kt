package com.lazarovco.budgetwarden.data

import android.accounts.Account
import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.common.Scopes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant

const val DRIVE_SCOPE = "https://www.googleapis.com/auth/drive"
const val DRIVE_FOLDER_NAME = "Budget Warden Vault"
const val BUDGET_MIME_TYPE = "application/vnd.budgetwarden.budget+json"

data class DriveFile(val id: String, val name: String, val modifiedTime: Long, val version: Long, val ownerEmail: String?, val sharedWithMe: Boolean)

sealed interface DriveAuthorization {
    data class Authorized(val token: String, val email: String?) : DriveAuthorization
    data class NeedsResolution(val pendingIntent: PendingIntent) : DriveAuthorization
}

class DriveAuthorizer private constructor(
    private val client: com.google.android.gms.auth.api.identity.AuthorizationClient,
) {
    constructor(context: Context) : this(Identity.getAuthorizationClient(context))
    constructor(activity: Activity) : this(Identity.getAuthorizationClient(activity))

    suspend fun authorize(email: String? = null): DriveAuthorization {
        val request = AuthorizationRequest.builder().setRequestedScopes(
            listOf(Scope(DRIVE_SCOPE), Scope(Scopes.EMAIL)),
        ).apply {
            if (email != null) setAccount(Account(email, "com.google"))
        }.build()
        return client.authorize(request).await().toAuthorization()
    }

    fun resultFromIntent(intent: Intent): DriveAuthorization = client.getAuthorizationResultFromIntent(intent).toAuthorization()

    private fun AuthorizationResult.toAuthorization(): DriveAuthorization = pendingIntent?.let(DriveAuthorization::NeedsResolution)
        ?: DriveAuthorization.Authorized(
            accessToken ?: error("Google did not return a Drive token."),
            toGoogleSignInAccount()?.email,
        )
}

class GoogleDriveClient(private val http: OkHttpClient = OkHttpClient()) {
    suspend fun findOrCreateVault(token: String): String = withContext(Dispatchers.IO) {
        list(token, "name = '$DRIVE_FOLDER_NAME' and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
            .firstOrNull()?.id ?: createFolder(token)
    }

    suspend fun listVaultFiles(token: String, folderId: String): List<DriveFile> = withContext(Dispatchers.IO) {
        val owned = list(token, "'$folderId' in parents and trashed = false")
        val shared = list(token, "sharedWithMe = true and trashed = false and name contains '.budget'")
        (owned + shared).distinctBy(DriveFile::id).filter { it.name.endsWith(".budget", true) }
    }

    suspend fun download(token: String, driveId: String, destination: File) = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("https://www.googleapis.com/drive/v3/files/$driveId?alt=media").bearer(token).build()
        http.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "Drive download failed (${response.code})." }
            destination.parentFile?.mkdirs()
            destination.outputStream().use { response.body.byteStream().copyTo(it) }
        }
    }

    suspend fun upload(token: String, folderId: String, file: File, driveId: String?): DriveFile = withContext(Dispatchers.IO) {
        val metadata = JSONObject().put("name", file.name).apply { if (driveId == null) put("parents", JSONArray().put(folderId)) }
        val body = MultipartBody.Builder().setType("multipart/related".toMediaType())
            .addPart(metadata.toString().toRequestBody("application/json; charset=UTF-8".toMediaType()))
            .addPart(file.asRequestBody(BUDGET_MIME_TYPE.toMediaType())).build()
        val base = "https://www.googleapis.com/upload/drive/v3/files"
        val url = if (driveId == null) "$base?uploadType=multipart&fields=$FIELDS" else "$base/$driveId?uploadType=multipart&fields=$FIELDS"
        val builder = Request.Builder().url(url).bearer(token)
        http.newCall(if (driveId == null) builder.post(body).build() else builder.patch(body).build()).execute().use {
            check(it.isSuccessful) { "Drive upload failed (${it.code})." }
            parseFile(JSONObject(it.body.string()))
        }
    }

    suspend fun share(token: String, driveId: String, email: String) = withContext(Dispatchers.IO) {
        val body = JSONObject().put("type", "user").put("role", "writer").put("emailAddress", email)
            .toString().toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url("https://www.googleapis.com/drive/v3/files/$driveId/permissions?sendNotificationEmail=true")
            .bearer(token).post(body).build()
        http.newCall(request).execute().use { check(it.isSuccessful) { "Sharing failed (${it.code})." } }
    }

    suspend fun trash(token: String, driveId: String) = withContext(Dispatchers.IO) {
        val body = JSONObject().put("trashed", true).toString().toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url("https://www.googleapis.com/drive/v3/files/$driveId")
            .bearer(token).patch(body).build()
        http.newCall(request).execute().use { check(it.isSuccessful) { "Drive delete failed (${it.code})." } }
    }

    private fun list(token: String, query: String): List<DriveFile> {
        val url = okhttp3.HttpUrl.Builder().scheme("https").host("www.googleapis.com").addPathSegments("drive/v3/files")
            .addQueryParameter("q", query).addQueryParameter("spaces", "drive").addQueryParameter("pageSize", "1000")
            .addQueryParameter("fields", "files($FIELDS)").build()
        return http.newCall(Request.Builder().url(url).bearer(token).build()).execute().use { response ->
            check(response.isSuccessful) { "Drive list failed (${response.code})." }
            JSONObject(response.body.string()).getJSONArray("files").let { array -> List(array.length()) { parseFile(array.getJSONObject(it)) } }
        }
    }

    private fun createFolder(token: String): String {
        val body = JSONObject().put("name", DRIVE_FOLDER_NAME).put("mimeType", "application/vnd.google-apps.folder")
            .toString().toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url("https://www.googleapis.com/drive/v3/files?fields=id").bearer(token).post(body).build()
        return http.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "Drive folder creation failed (${response.code})." }
            JSONObject(response.body.string()).getString("id")
        }
    }

    private fun parseFile(json: JSONObject) = DriveFile(
        json.getString("id"), json.optString("name"),
        runCatching { Instant.parse(json.optString("modifiedTime")).toEpochMilli() }.getOrDefault(0), json.optLong("version"),
        json.optJSONArray("owners")?.optJSONObject(0)?.optString("emailAddress"), json.has("sharedWithMeTime"),
    )

    private fun Request.Builder.bearer(token: String) = header("Authorization", "Bearer $token")
    private companion object { const val FIELDS = "id,name,modifiedTime,version,owners(emailAddress),sharedWithMeTime" }
}

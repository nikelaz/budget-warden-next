package com.lazarovco.budgetwarden.android.data

import com.lazarovco.budgetwarden.core.BWCloudBudget
import com.lazarovco.budgetwarden.core.BWHttpClient
import com.lazarovco.budgetwarden.core.BWHttpHeader
import com.lazarovco.budgetwarden.core.BWHttpRequest
import com.lazarovco.budgetwarden.core.BWHttpResponse
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Performs the core's Google Drive requests with [HttpURLConnection]. The core
 * calls it from background threads only.
 */
internal class HttpUrlConnectionClient(
    private val open: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
) : BWHttpClient {
    override fun execute(request: BWHttpRequest): BWHttpResponse {
        val connection = open(URL(request.url))
        try {
            connection.connectTimeout = TIMEOUT_MILLIS
            connection.readTimeout = TIMEOUT_MILLIS
            connection.useCaches = false
            // HttpURLConnection has no PATCH; Google APIs accept the override.
            if (request.method == "PATCH") {
                connection.requestMethod = "POST"
                connection.setRequestProperty("X-HTTP-Method-Override", "PATCH")
            } else {
                connection.requestMethod = request.method
            }
            request.headers.forEach { connection.setRequestProperty(it.name, it.value) }
            request.body?.let { body ->
                val bytes = body.toByteArray(Charsets.UTF_8)
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val body = stream?.use { it.readBytes().toString(Charsets.UTF_8) }.orEmpty()
            val headers = connection.headerFields
                .filterKeys { it != null }
                .flatMap { (name, values) -> values.map { BWHttpHeader(name = name, value = it) } }
            return BWHttpResponse(status = status, headers = headers, body = body)
        } catch (error: IOException) {
            throw IOException("Could not reach Google Drive: ${error.message ?: error.javaClass.simpleName}", error)
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val TIMEOUT_MILLIS = 60_000
    }
}

/**
 * Runs one sync per budget at a time. A request made while that budget is
 * syncing runs once more afterwards, so the latest save always reaches Drive.
 */
internal class CoalescingSyncScheduler(
    private val scope: CoroutineScope,
    private val syncBudget: suspend (String) -> Unit,
) {
    private val running = mutableSetOf<String>()
    private val again = mutableSetOf<String>()

    fun request(id: String) {
        synchronized(this) {
            if (!running.add(id)) {
                again.add(id)
                return
            }
        }
        scope.launch {
            while (true) {
                runCatching { syncBudget(id) }
                synchronized(this@CoalescingSyncScheduler) {
                    if (!again.remove(id)) {
                        running.remove(id)
                        return@launch
                    }
                }
            }
        }
    }
}

/** "Shared by Ana", "Google Drive · Shared", or "Google Drive". */
internal val BWCloudBudget.locationDescription: String
    get() {
        val who = ownerName ?: ownerEmail ?: "someone"
        return when {
            sharedWithMe && canEdit -> "Shared by $who"
            sharedWithMe -> "Shared by $who · View only"
            isShared -> "Google Drive · Shared"
            else -> "Google Drive"
        }
    }

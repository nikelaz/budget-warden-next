package com.lazarovco.budgetwarden.android.data

import com.google.common.truth.Truth.assertThat
import com.lazarovco.budgetwarden.core.BWCloudBudget
import com.lazarovco.budgetwarden.core.BWHttpHeader
import com.lazarovco.budgetwarden.core.BWHttpRequest
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CloudSyncTest {
    @Test
    fun syncRequestsDuringASyncRunOnceMoreAfterIt() = runTest {
        val started = mutableListOf<String>()
        val release = CompletableDeferred<Unit>()
        val scope = TestScope(StandardTestDispatcher(testScheduler))
        val scheduler = CoalescingSyncScheduler(scope) { id ->
            started += id
            if (started.size == 1) release.await()
        }

        scheduler.request("a")
        scope.advanceUntilIdle()
        repeat(3) { scheduler.request("a") }
        scheduler.request("b")
        scope.advanceUntilIdle()
        assertThat(started).containsExactly("a", "b")

        release.complete(Unit)
        scope.advanceUntilIdle()
        assertThat(started).containsExactly("a", "b", "a").inOrder()

        scheduler.request("a")
        scope.advanceUntilIdle()
        assertThat(started).containsExactly("a", "b", "a", "a").inOrder()
    }

    @Test
    fun failedSyncsDoNotStopLaterOnes() = runTest {
        var attempts = 0
        val scope = TestScope(StandardTestDispatcher(testScheduler))
        val scheduler = CoalescingSyncScheduler(scope) {
            attempts += 1
            error("offline")
        }
        scheduler.request("a")
        scope.advanceUntilIdle()
        scheduler.request("a")
        scope.advanceUntilIdle()
        assertThat(attempts).isEqualTo(2)
    }

    @Test
    fun budgetsDescribeWhoSharedThem() {
        val budget = BWCloudBudget(
            id = "1",
            name = "Home.budget",
            title = "Home",
            ownerName = "Ana",
            ownerEmail = "ana@example.com",
            sharedWithMe = false,
            isShared = false,
            canEdit = true,
            canShare = true,
            modifiedTime = null,
            webLink = null,
            localPath = null,
        )
        assertThat(budget.locationDescription).isEqualTo("Google Drive")
        assertThat(budget.copy(isShared = true).locationDescription).isEqualTo("Google Drive · Shared")
        assertThat(budget.copy(sharedWithMe = true).locationDescription).isEqualTo("Shared by Ana")
        assertThat(budget.copy(sharedWithMe = true, canEdit = false, ownerName = null).locationDescription)
            .isEqualTo("Shared by ana@example.com · View only")
    }

    @Test
    fun httpClientSendsPatchAsAnOverrideAndReturnsErrorBodies() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val seen = mutableListOf<String>()
        server.createContext("/") { exchange ->
            val body = exchange.requestBody.readBytes().toString(Charsets.UTF_8)
            seen += "${exchange.requestMethod} ${exchange.requestHeaders.getFirst("X-HTTP-Method-Override")} " +
                "${exchange.requestHeaders.getFirst("Authorization")} $body"
            val (status, answer) = if (exchange.requestURI.path == "/missing") 404 to "{\"error\":{}}" else 200 to "ok"
            val bytes = answer.toByteArray()
            exchange.responseHeaders.add("X-Test", "yes")
            exchange.sendResponseHeaders(status, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            val client = HttpUrlConnectionClient()
            val patched = client.execute(
                BWHttpRequest(
                    method = "PATCH",
                    url = "$base/upload",
                    headers = listOf(BWHttpHeader(name = "Authorization", value = "Bearer t")),
                    body = "{\"a\":1}",
                ),
            )
            assertThat(patched.status).isEqualTo(200)
            assertThat(patched.body).isEqualTo("ok")
            assertThat(patched.headers.any { it.name.equals("X-Test", ignoreCase = true) && it.value == "yes" }).isTrue()

            val missing = client.execute(BWHttpRequest(method = "GET", url = "$base/missing", headers = emptyList(), body = null))
            assertThat(missing.status).isEqualTo(404)
            assertThat(missing.body).isEqualTo("{\"error\":{}}")
            assertThat(seen).containsExactly("POST PATCH Bearer t {\"a\":1}", "GET null null ").inOrder()
        } finally {
            server.stop(0)
        }
    }
}

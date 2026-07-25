package com.lazarovco.budgetwarden.data

import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal object BudgetFileLocks {
    private val locks = ConcurrentHashMap<String, ReentrantLock>()

    fun <T> withLock(file: File, action: () -> T): T =
        locks.getOrPut(file.absoluteFile.normalize().path) { ReentrantLock() }.withLock(action)
}

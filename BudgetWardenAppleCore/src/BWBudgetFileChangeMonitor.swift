/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation

public final class BWBudgetFileChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let onChange: @Sendable () -> Void
    private var presenters: [any NSFilePresenter] = []

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func updatePresentedItems(
        vaultURL: URL?,
        budgetURLs: [URL]
    ) {
        var nextPresenters: [any NSFilePresenter] = []
        var seenBudgetPaths: Set<String> = []

        if let vaultURL {
            nextPresenters.append(BWBudgetDirectoryPresenter(
                url: vaultURL.standardizedFileURL,
                onChange: onChange
            ))
        }

        for budgetURL in budgetURLs {
            let standardizedURL = budgetURL.standardizedFileURL
            let path = standardizedURL.path

            guard BWFiles.isBudgetFile(standardizedURL),
                  !seenBudgetPaths.contains(path)
            else {
                continue
            }

            nextPresenters.append(BWBudgetFilePresenter(
                url: standardizedURL,
                onChange: onChange
            ))
            seenBudgetPaths.insert(path)
        }

        replacePresenters(with: nextPresenters)
    }

    public func stop() {
        replacePresenters(with: [])
    }

    private func replacePresenters(with nextPresenters: [any NSFilePresenter]) {
        lock.lock()
        let oldPresenters = presenters
        presenters = nextPresenters
        lock.unlock()

        for presenter in oldPresenters {
            NSFileCoordinator.removeFilePresenter(presenter)
        }

        for presenter in nextPresenters {
            NSFileCoordinator.addFilePresenter(presenter)
        }
    }
}

private final class BWBudgetDirectoryPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(
        url: URL,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.presentedItemURL = url
        self.onChange = onChange

        let queue = OperationQueue()
        queue.name = "BudgetWarden.BudgetDirectoryPresenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue

        super.init()
    }

    func presentedSubitemDidAppear(at url: URL) {
        notifyIfBudgetFile(url)
    }

    func presentedSubitemDidChange(at url: URL) {
        notifyIfBudgetFile(url)
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        if BWFiles.isBudgetFile(oldURL) || BWFiles.isBudgetFile(newURL) {
            onChange()
        }
    }

    func accommodatePresentedSubitemDeletion(
        at url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        notifyIfBudgetFile(url)
        completionHandler(nil)
    }

    private func notifyIfBudgetFile(_ url: URL) {
        guard BWFiles.isBudgetFile(url) else {
            return
        }

        onChange()
    }
}

private final class BWBudgetFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(
        url: URL,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.presentedItemURL = url
        self.onChange = onChange

        let queue = OperationQueue()
        queue.name = "BudgetWarden.BudgetFilePresenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue

        super.init()
    }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        onChange()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}

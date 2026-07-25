/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import SwiftUI

struct BWBudgetListView: View {
    let store: BWStore
    let createBudget: () -> Void
    let openBudget: () -> Void
    let openRecent: (URL) -> Void

    var body: some View {
        List {
            if store.recentFiles.isEmpty {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 42, weight: .regular))
                            .foregroundStyle(.secondary)

                        Text("No Budgets Yet")
                            .font(.title2.weight(.semibold))

                        Text("Create or open a new budget")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button(action: createBudget) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Create New Budget")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: openBudget) {
                        Label("Open Budget", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowInsets(EdgeInsets(
                    top: 16,
                    leading: 20,
                    bottom: 16,
                    trailing: 20
                ))
            } else {
                Section("Recently Opened") {
                    ForEach(store.recentFiles, id: \.self) { url in
                        Button {
                            openRecent(url)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text(BWFileLocationFormatter.displayPath(for: url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recentBudget_\(url.lastPathComponent)")
                        .contextMenu {
                            Button("Delete Budget", systemImage: "trash", role: .destructive) {
                                store.deleteRecentBudget(at: url)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let files = offsets.compactMap { index in
                            store.recentFiles.indices.contains(index)
                                ? store.recentFiles[index]
                                : nil
                        }
                        for file in files {
                            store.deleteRecentBudget(at: file)
                        }
                    }
                }
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .navigationTitle("Budgets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Budget", systemImage: "plus", action: createBudget)
                    Button("Open Budget", systemImage: "folder", action: openBudget)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Budget")
            }
        }
    }

}

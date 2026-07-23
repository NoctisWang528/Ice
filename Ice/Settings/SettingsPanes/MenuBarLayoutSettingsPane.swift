//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(spacing: 20) {
                header
                layoutBars
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        IceSection {
            VStack(spacing: 3) {
                Text(headerTitle)
                    .font(.title3.bold())
                Text(headerSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(15)
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        if hasItems {
            VStack(spacing: 14) {
                loadStateNotice

                VStack(spacing: 20) {
                    ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                        layoutBar(for: section)
                    }
                }
            }
        } else {
            loadStatePlaceholder
        }
    }

    private var headerTitle: String {
        if case .loadedLimited = itemManager.loadState {
            return "Detected menu bar items"
        }
        return "Drag to arrange your menu bar items into different sections."
    }

    private var headerSubtitle: String {
        if case .loadedLimited = itemManager.loadState {
            return "macOS 27 Accessibility enumeration is active. Safe third-party Visible items can be reordered; hiding is not yet supported."
        }
        return "Items can also be arranged by ⌘ Command + dragging them in the menu bar."
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Ice cannot arrange menu bar items in automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermissions: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var loadStateNotice: some View {
        switch itemManager.loadState {
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing menu bar items…")
                Spacer()
            }
            .foregroundStyle(.secondary)
        case .loadedLimited(let message):
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "info.circle")
                Text(message)
                Spacer()
                refreshButton
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var loadStatePlaceholder: some View {
        switch itemManager.loadState {
        case .loading:
            VStack(spacing: 10) {
                Text("Loading menu bar items…")
                ProgressView()
            }
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 220)
        case .permissionMissing:
            messagePlaceholder(
                title: "Accessibility permission is required",
                message: "Grant Accessibility permission in Advanced Settings, then refresh the menu bar item list.",
                showsAdvancedSettingsButton: true
            )
        case .empty(let message):
            messagePlaceholder(title: "No menu bar items found", message: message)
        case .failed(let message):
            messagePlaceholder(title: "Unable to load menu bar items", message: message)
        case .idle:
            messagePlaceholder(
                title: "Menu bar items have not been loaded",
                message: "Refresh to enumerate the current menu bar items."
            )
        case .loaded, .loadedLimited:
            messagePlaceholder(
                title: "No menu bar items available",
                message: "Refresh to enumerate the current menu bar items."
            )
        }
    }

    private var refreshButton: some View {
        Button("Refresh Menu Bar Items") {
            Task {
                await itemManager.refreshMenuBarItems()
                await appState.imageCache.updateCacheWithoutChecks(
                    sections: MenuBarSection.Name.allCases,
                    force: true
                )
            }
        }
        .disabled(itemManager.loadState == .loading)
    }

    private func messagePlaceholder(
        title: String,
        message: String,
        showsAdvancedSettingsButton: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title3.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                if showsAdvancedSettingsButton {
                    Button("Go to Advanced Settings") {
                        appState.navigationState.settingsNavigationIdentifier = .advanced
                    }
                }
                refreshButton
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading) {
                Text(name.localized)
                    .font(.headline)
                    .padding(.leading, 8)

                LayoutBar(imageCache: appState.imageCache, section: name)
            }
        }
    }
}

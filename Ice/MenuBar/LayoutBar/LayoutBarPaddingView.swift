//
//  LayoutBarPaddingView.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private let container: LayoutBarContainer

    /// The layout view's arranged views.
    var arrangedViews: [LayoutBarItemView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    init(appState: AppState, section: MenuBarSection.Name) {
        self.container = LayoutBarContainer(appState: appState, section: section)

        super.init(frame: .zero)

        addSubview(container)
        self.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),
            leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5),
        ])

        registerForDraggedTypes([.layoutBarItem])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let appState = container.appState,
            let draggingSource = sender.draggingSource as? LayoutBarItemView,
            let sourceSection = draggingSource.dragSourceSection,
            appState.itemManager.canMove(
                item: draggingSource.item,
                from: sourceSection,
                to: container.section
            )
        else {
            restoreLayoutFromCache()
            return false
        }

        if let index = arrangedViews.firstIndex(of: draggingSource) {
            if arrangedViews.count == 1 {
                Task {
                    // dragging source is the only view in the layout bar, so we
                    // need to find a target item
                    let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
                    let targetItem: MenuBarItem? = switch container.section {
                    case .visible: nil // visible section always has more than 1 item
                    case .hidden: items.first(matching: .hiddenControlItem)
                    case .alwaysHidden: items.first(matching: .alwaysHiddenControlItem)
                    }
                    if let targetItem {
                        guard appState.itemManager.canUseAsMoveTarget(
                            item: targetItem,
                            for: draggingSource.item,
                            from: sourceSection,
                            to: container.section
                        ) else {
                            restoreLayoutFromCache()
                            return
                        }
                        move(
                            item: draggingSource.item,
                            to: .leftOfItem(targetItem)
                        )
                    } else {
                        Logger.default.error("No target item for layout bar drag")
                        restoreLayoutFromCache()
                    }
                }
            } else if arrangedViews.indices.contains(index + 1) {
                // we have a view to the right of the dragging source
                let targetItem = arrangedViews[index + 1].item
                guard appState.itemManager.canUseAsMoveTarget(
                    item: targetItem,
                    for: draggingSource.item,
                    from: sourceSection,
                    to: container.section
                ) else {
                    restoreLayoutFromCache()
                    return false
                }
                move(item: draggingSource.item, to: .leftOfItem(targetItem))
            } else if arrangedViews.indices.contains(index - 1) {
                // we have a view to the left of the dragging source
                let targetItem = arrangedViews[index - 1].item
                guard appState.itemManager.canUseAsMoveTarget(
                    item: targetItem,
                    for: draggingSource.item,
                    from: sourceSection,
                    to: container.section
                ) else {
                    restoreLayoutFromCache()
                    return false
                }
                move(item: draggingSource.item, to: .rightOfItem(targetItem))
            } else {
                restoreLayoutFromCache()
                return false
            }
        } else {
            restoreLayoutFromCache()
            return false
        }

        return true
    }

    private func move(item: MenuBarItem, to destination: MenuBarItemManager.MoveDestination) {
        guard let appState = container.appState else {
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(25))
            defer {
                restoreLayoutFromCache()
            }
            do {
                try await appState.itemManager.move(item: item, to: destination)
                appState.itemManager.removeTemporarilyShownItemFromCache(with: item.tag)
            } catch {
                Logger.default.error("Error moving menu bar item: \(error, privacy: .public)")
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    /// Replaces any optimistic drag order with the manager's last confirmed cache.
    private func restoreLayoutFromCache() {
        guard let appState = container.appState else {
            return
        }
        container.canSetArrangedViews = true
        container.setArrangedViews(
            items: appState.itemManager.itemCache.managedItems(for: container.section)
        )
    }
}

import AppKit
import DynamicNotchKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NotchPanelController {
    private let mediaManager: MediaManager
    private let clipboardManager: ClipboardManager
    private let fileShelfManager: FileShelfManager
    private let todoListStore = TodoListStore()
    private let onOpenSettings: () -> Void
    private let isFileShelfEnabled: () -> Bool
    private let isClipboardEnabled: () -> Bool
    private let hoverDelay: () -> Double
    private let triggerWidth: () -> CGFloat
    private let triggerHeight: () -> CGFloat

    private var dynamicNotch: DynamicNotch<CombinedNotchView, EmptyView, EmptyView>?
    private var physicalNotch: PhysicalNotchPanel?
    private var notchWindow: NSWindow? {
        physicalNotch?.window ?? dynamicNotch?.windowController?.window
    }

    private var isDynamicNotchVisible = false
    private var isDraggingOverTrigger = false
    private var isDraggingOverPanel = false
    private var isDragSessionActive = false
    private var triggerWindows: [NSWindow] = []
    private var isHoveringTrigger = false
    private var isHoveringPanel = false
    private var pendingDragEndWorkItem: DispatchWorkItem?
    private var pendingDragWatchdogWorkItem: DispatchWorkItem?
    private var pendingShowWorkItem: DispatchWorkItem?
    private var hoverValidationTimer: Timer?
    private var visibilityTask: Task<Void, Never>?
    private var wantsNotchVisible = false
    private var keepVisibleUntil: Date?
    private var isMirrorActive = false

    private let dragSessionGracePeriod: TimeInterval = 0.8
    private let dragWatchdogInterval: TimeInterval = 0.65
    private let hoverValidationInterval: TimeInterval = 0.12
    private let visiblePanelHitTestPadding: CGFloat = 8
    private let externalInteractionHoldDuration: TimeInterval = 10

    init(
        mediaManager: MediaManager,
        clipboardManager: ClipboardManager,
        fileShelfManager: FileShelfManager,
        onOpenSettings: @escaping () -> Void,
        isFileShelfEnabled: @escaping () -> Bool,
        isClipboardEnabled: @escaping () -> Bool,
        hoverDelay: @escaping () -> Double,
        triggerWidth: @escaping () -> CGFloat,
        triggerHeight: @escaping () -> CGFloat
    ) {
        self.mediaManager = mediaManager
        self.clipboardManager = clipboardManager
        self.fileShelfManager = fileShelfManager
        self.onOpenSettings = onOpenSettings
        self.isFileShelfEnabled = isFileShelfEnabled
        self.isClipboardEnabled = isClipboardEnabled
        self.hoverDelay = hoverDelay
        self.triggerWidth = triggerWidth
        self.triggerHeight = triggerHeight
    }

    func showNotch() {
        // The floating presenter must finish hiding before it can open again.
        if isDynamicNotchVisible && !wantsNotchVisible && physicalNotch == nil { return }

        let shouldExpand = !isDynamicNotchVisible || (physicalNotch != nil && !wantsNotchVisible)
        wantsNotchVisible = true
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        startHoverValidationTimer()

        guard shouldExpand else { return }
        visibilityTask?.cancel()
        visibilityTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.configureNotchWindowLevel()
            isDynamicNotchVisible = true
            if let physicalNotch {
                physicalNotch.expand()
            } else if !NSScreen.screens.isEmpty {
                await dynamicNotch?.expand()
            }
            guard !Task.isCancelled, wantsNotchVisible else { return }
            self.configureNotchWindowLevel()
        }
    }

    private func hideNotch() {
        guard wantsNotchVisible else { return }
        wantsNotchVisible = false
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        notchWindow?.ignoresMouseEvents = false
        scheduleDragSessionEnd()

        visibilityTask?.cancel()
        guard isDynamicNotchVisible else {
            stopHoverValidationTimer()
            return
        }

        visibilityTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isDynamicNotchVisible else { return }
            if let physicalNotch {
                await physicalNotch.hide()
            } else {
                await dynamicNotch?.hide()
            }
            guard !Task.isCancelled, !wantsNotchVisible else { return }
            self.isDynamicNotchVisible = false
            self.stopHoverValidationTimer()
            self.refreshPointerHoverState()
            if self.shouldKeepNotchVisible {
                self.evaluateHoverState()
            }
        }
    }

    private var shouldKeepNotchVisible: Bool {
        isHoveringTrigger || isHoveringPanel || isDraggingOverTrigger || isDraggingOverPanel
            || isDragSessionActive || isExternalInteractionActive || isMirrorActive
    }

    private var isExternalInteractionActive: Bool {
        guard let keepVisibleUntil else { return false }
        return keepVisibleUntil > Date()
    }

    private func holdForExternalInteraction(duration: TimeInterval? = nil) {
        keepVisibleUntil = Date().addingTimeInterval(duration ?? externalInteractionHoldDuration)
        showNotch()
    }

    private func mirrorActiveChanged(_ active: Bool) {
        isMirrorActive = active
        if active {
            showNotch()
        } else {
            evaluateHoverState()
        }
    }

    private func evaluateHoverState() {
        if shouldKeepNotchVisible {
            if shouldShowImmediately {
                showNotch()
            } else {
                scheduleHoverShow()
            }
        } else {
            pendingShowWorkItem?.cancel()
            pendingShowWorkItem = nil
            hideNotch()
        }
    }

    private func triggerDraggingChanged(_ isDragging: Bool) {
        isDraggingOverTrigger = isDragging
        if isDragging {
            beginDragSession()
            scheduleDragWatchdog()
            isHoveringTrigger = false
        } else {
            scheduleDragSessionEnd()
        }
        configureNotchWindowLevel()
        evaluateHoverState()
    }

    private var shouldShowImmediately: Bool {
        isDraggingOverTrigger || isDraggingOverPanel || isDragSessionActive || isExternalInteractionActive
    }

    private func scheduleHoverShow() {
        guard !isDynamicNotchVisible || (physicalNotch != nil && !wantsNotchVisible) else { return }
        guard pendingShowWorkItem == nil else { return }

        let delay = max(0, hoverDelay())
        guard delay > 0 else {
            showNotch()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPointerHoverState()
                if self.shouldKeepNotchVisible {
                    self.showNotch()
                }
                self.pendingShowWorkItem = nil
            }
        }
        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func panelDraggingChanged(_ isDragging: Bool) {
        isDraggingOverPanel = isDragging
        if isDragging {
            beginDragSession()
            scheduleDragWatchdog()
        } else {
            scheduleDragSessionEnd()
        }
        configureNotchWindowLevel()
        evaluateHoverState()
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard isFileShelfEnabled(), !providers.isEmpty else {
            isDraggingOverTrigger = false
            isDraggingOverPanel = false
            endDragSession()
            configureNotchWindowLevel()
            evaluateHoverState()
            return false
        }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                [weak self] item, _ in
                guard let url = Self.url(from: item) else { return }
                DispatchQueue.main.async {
                    self?.fileShelfManager.addFile(url: url)
                }
            }
        }

        isDraggingOverTrigger = false
        isDraggingOverPanel = false
        endDragSession()
        configureNotchWindowLevel()
        showNotch()
        return true
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    func start() {
        setupTriggerWindows()
        updateContentWindowFrame()
    }

    func updateContentWindowFrame() {
        stopHoverValidationTimer()
        visibilityTask?.cancel()
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        notchWindow?.orderOut(nil)
        isDynamicNotchVisible = false
        wantsNotchVisible = false
        isHoveringPanel = false
        isHoveringTrigger = false
        isMirrorActive = false
        rebuildDynamicNotch()
        refreshPointerHoverState()
    }

    func updateTriggerWindows() {
        setupTriggerWindows()
        refreshPointerHoverState()
    }

    private func configureNotchWindowLevel() {
        guard let window = notchWindow else { return }

        let shouldLetTriggerHandleDrag =
            isDraggingOverTrigger
            && !isDraggingOverPanel
            && isPointerOverTrigger()
        let targetLevel: NSWindow.Level = isDragSessionActive ? .statusBar : .screenSaver
        if window.level != targetLevel {
            window.level = targetLevel
        }
        if window.ignoresMouseEvents != shouldLetTriggerHandleDrag {
            window.ignoresMouseEvents = shouldLetTriggerHandleDrag
        }
    }

    private func beginDragSession() {
        pendingDragEndWorkItem?.cancel()
        pendingDragEndWorkItem = nil
        isDragSessionActive = true
    }

    private func scheduleDragWatchdog() {
        pendingDragWatchdogWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPointerHoverState()
                if !self.isPointerOverTrigger(), !self.isPointerOverPanel() {
                    self.isDraggingOverTrigger = false
                    self.isDraggingOverPanel = false
                    self.endDragSession()
                    self.configureNotchWindowLevel()
                    self.evaluateHoverState()
                } else if self.isDraggingOverTrigger || self.isDraggingOverPanel || self.isDragSessionActive {
                    self.scheduleDragWatchdog()
                }
            }
        }
        pendingDragWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dragWatchdogInterval, execute: workItem)
    }

    private func scheduleDragSessionEnd() {
        pendingDragEndWorkItem?.cancel()

        guard !isDraggingOverTrigger, !isDraggingOverPanel else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isDraggingOverTrigger, !self.isDraggingOverPanel else {
                    return
                }
                self.endDragSession()
                self.configureNotchWindowLevel()
                self.evaluateHoverState()
            }
        }
        pendingDragEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + dragSessionGracePeriod, execute: workItem)
    }

    private func endDragSession() {
        pendingDragEndWorkItem?.cancel()
        pendingDragEndWorkItem = nil
        pendingDragWatchdogWorkItem?.cancel()
        pendingDragWatchdogWorkItem = nil
        isDragSessionActive = false
        notchWindow?.ignoresMouseEvents = false
    }

    private func isPointerOverTrigger(at location: NSPoint = NSEvent.mouseLocation) -> Bool {
        triggerWindows.contains { window in
            window.isVisible && NotchLayout.containsPointer(location, in: window.frame)
        }
    }

    private func isPointerOverPanel(at location: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard isDynamicNotchVisible,
              let panelWindow = notchWindow,
              panelWindow.isVisible,
              let screen = panelWindow.screen
        else { return false }

        return NotchLayout.containsPointer(location, in: visiblePanelInteractionFrame(on: screen))
    }

    private func startHoverValidationTimer() {
        guard hoverValidationTimer == nil else { return }
        hoverValidationTimer = Timer.scheduledTimer(
            withTimeInterval: hoverValidationInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPointerHoverState()
            }
        }
    }

    private func stopHoverValidationTimer() {
        hoverValidationTimer?.invalidate()
        hoverValidationTimer = nil
    }

    private func refreshPointerHoverState() {
        configureNotchWindowLevel()

        // Hover tracking can report an exit when the panel covers the trigger.
        // Use the same screen-space hit tests for notifications and the timer.
        let mouseLocation = NSEvent.mouseLocation
        let isActuallyHoveringTrigger = !isDraggingOverTrigger && isPointerOverTrigger(at: mouseLocation)
        let isActuallyHoveringPanel = isPointerOverPanel(at: mouseLocation)

        guard isActuallyHoveringTrigger != isHoveringTrigger
            || isActuallyHoveringPanel != isHoveringPanel
            || (wantsNotchVisible && !shouldKeepNotchVisible)
        else { return }

        isHoveringTrigger = isActuallyHoveringTrigger
        isHoveringPanel = isActuallyHoveringPanel
        evaluateHoverState()
    }

    private func visiblePanelInteractionFrame(on screen: NSScreen) -> NSRect {
        let defaults = UserDefaults.standard
        let showNowPlaying = defaults.object(forKey: "showNowPlaying") as? Bool ?? true
        let sectionCount = isMirrorActive ? 1 : NotchLayout.panelSectionCount(
            showNowPlaying: showNowPlaying,
            enableFileShelf: isFileShelfEnabled(),
            showClipboard: isClipboardEnabled(),
            showTodoList: defaults.bool(forKey: "showTodoList")
        )
        let metrics = NotchLayout.scaledMetrics(
            panelWidth: NotchConstants.basePanelWidth,
            panelHeight: NotchConstants.basePanelHeight,
            sectionCount: sectionCount,
            screenWidth: screen.visibleFrame.width
        )
        let cutout = PhysicalNotchPanel.cutout(on: screen)
        let menuBarHeight = cutout?.height ?? NSApplication.shared.mainMenu?.menuBarHeight ?? 24
        let padding = cutout != nil && !isDragSessionActive ? 0 : visiblePanelHitTestPadding
        let contentWidth = metrics.totalWidth
            + (NotchLayout.expandedSafeAreaInset * 2)
            + 30
            + (padding * 2)
        let contentHeight = menuBarHeight
            + metrics.totalHeight
            + NotchLayout.expandedSafeAreaInset
            + (padding * 2)
        let origin = NSPoint(
            x: (cutout?.midX ?? screen.frame.midX) - (contentWidth / 2),
            y: screen.frame.maxY - contentHeight
        )
        return NSRect(origin: origin, size: NSSize(width: contentWidth, height: contentHeight))
    }

    private func setupTriggerWindows() {
        for window in triggerWindows {
            window.orderOut(nil)
        }
        triggerWindows.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: triggerFrameWithPadding(on: screen),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .statusBar
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .transient]
            window.contentView = NSHostingView(
                rootView: TriggerAreaView(
                    onHoverChange: { [weak self] _ in
                        self?.refreshPointerHoverState()
                    },
                    onDragging: { [weak self] isDragging in
                        self?.triggerDraggingChanged(isDragging)
                    },
                    onDropProviders: { [weak self] providers in
                        self?.handleDroppedProviders(providers) ?? false
                    }
                )
            )
            window.orderFrontRegardless()
            triggerWindows.append(window)
        }
    }

    private func rebuildDynamicNotch() {
        let display = NSScreen.screens.first
        let cutout = display.flatMap { PhysicalNotchPanel.cutout(on: $0) }
        let combinedView = CombinedNotchView(
            mediaManager: mediaManager,
            clipboardManager: clipboardManager,
            fileShelfManager: fileShelfManager,
            todoListStore: todoListStore,
            usesFloatingStyle: cutout == nil,
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            },
            onMirrorActiveChange: { [weak self] active in
                self?.mirrorActiveChanged(active)
            },
            onHover: { [weak self] _ in
                self?.refreshPointerHoverState()
            },
            onDropTargetChange: { [weak self] isTargeted in
                self?.panelDraggingChanged(isTargeted)
            },
            onDropProviders: { [weak self] providers in
                self?.handleDroppedProviders(providers) ?? false
            },
            onExternalInteraction: { [weak self] in
                self?.holdForExternalInteraction()
            }
        )
        if let display, let cutout {
            physicalNotch = PhysicalNotchPanel(
                screen: display, cutout: cutout, content: combinedView
            ) { [weak self] in
                self?.refreshPointerHoverState()
            }
            dynamicNotch = nil
        } else {
            physicalNotch = nil
            dynamicNotch = DynamicNotch(hoverBehavior: []) { combinedView }
        }
    }

    private func triggerFrameWithPadding(on screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let menuBarHeight = NSApplication.shared.mainMenu?.menuBarHeight ?? 24
        let NotchMore = screenFrame.maxY - menuBarHeight
        let notchWidth = max(80, min(screenFrame.width, triggerWidth()))
        let hoverPadding = max(1, min(120, triggerHeight()))
        let notchX = screenFrame.minX + (screenFrame.width - notchWidth) / 2
        let base = NSRect(x: notchX, y: NotchMore, width: notchWidth, height: menuBarHeight)
        return NSRect(
            x: base.origin.x - 10,
            y: base.origin.y - hoverPadding,
            width: base.width + 20,
            height: base.height + hoverPadding
        )
    }

    struct TriggerAreaView: View {
        var onHoverChange: (Bool) -> Void
        var onDragging: (Bool) -> Void
        var onDropProviders: ([NSItemProvider]) -> Bool
        @State private var isDropTargeted: Bool = false

        var body: some View {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    onHoverChange(isHovering)
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    let didAccept = onDropProviders(providers)
                    onDragging(false)
                    return didAccept
                }
                .onChange(of: isDropTargeted, initial: false) { _, isTargeted in
                    onDragging(isTargeted)
                }
        }
    }
}

import AppKit
import SwiftUI

enum PresentationMode: Equatable {
    case attached
    case floating
}

@MainActor
final class MenuPresentationState: ObservableObject {
    @Published private(set) var mode: PresentationMode = .attached
    @Published private(set) var isWindowVisible: Bool = false

    fileprivate var onModeChange: (() -> Void)?

    func setPresentationMode(_ mode: PresentationMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        onModeChange?()
    }

    fileprivate func setWindowVisible(_ isVisible: Bool) {
        guard isWindowVisible != isVisible else { return }
        isWindowVisible = isVisible
    }
}

private final class AttachedWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [
                .nonactivatingPanel, .fullSizeContentView,
                .titled, .utilityWindow, .closable, .resizable,
            ],
            backing: .buffered,
            defer: false
        )
        contentView = NSView()
        isReleasedWhenClosed = false
        level = .mainMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        tabbingMode = .disallowed

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none

        // Increase title dragging area
        toolbar = NSToolbar(identifier: "AttachedWindowToolbar")
        toolbar?.allowsUserCustomization = false
        toolbar?.autosavesConfiguration = false
        toolbarStyle = .unified
        showsToolbarButton = false

        for buttonType in [
            NSWindow.ButtonType.closeButton, .miniaturizeButton,
            .zoomButton, .toolbarButton, .documentIconButton, .documentVersionsButton,
        ] {
            standardWindowButton(buttonType)?.isHidden = true
        }
    }

    func repositionWindow(relativeTo button: NSView?) {
        guard
            let button,
            let buttonWindow = button.window,
            let visibleFrame = buttonWindow.screen?.visibleFrame
        else { return }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)

        var originX = buttonFrameOnScreen.midX - (frame.size.width / 2)
        originX = min(max(originX, visibleFrame.minX), visibleFrame.maxX - frame.size.width)

        let originY = max(visibleFrame.minY, buttonFrameOnScreen.minY - frame.size.height)
        setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

private final class FloatingWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        contentView = NSView()
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        tabbingMode = .disallowed
    }
}

@MainActor
final class MenuPresentationController<Content: View>: NSObject, NSWindowDelegate {
    typealias ContentBuilder = (MenuPresentationState) -> Content

    private(set) var statusItem: NSStatusItem?
    private let presentationState = MenuPresentationState()
    private let statusItemMenu: NSMenu?
    private let hostingView: NSHostingView<AnyView>
    private var currentWindow: NSWindow
    private let attachedWindow: AttachedWindow
    private let floatingWindow: FloatingWindow

    private var presentationMode: PresentationMode { presentationState.mode }

    init(
        @ViewBuilder content: @escaping ContentBuilder,
        statusItemMenu: NSMenu? = nil,
        configureWindow: ((NSWindow, PresentationMode) -> Void)? = nil
    ) {
        hostingView = NSHostingView(rootView: AnyView(content(presentationState)))
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.autoresizingMask = [.width, .height]

        self.statusItemMenu = statusItemMenu

        attachedWindow = AttachedWindow()
        floatingWindow = FloatingWindow()
        currentWindow = attachedWindow

        super.init()

        attachedWindow.delegate = self
        floatingWindow.delegate = self
        configureWindow?(attachedWindow, .attached)
        configureWindow?(floatingWindow, .floating)

        presentationState.onModeChange = { [weak self] in
            guard let self else { return }

            if presentationMode == .attached {
                self.hideWindow()
            }

            self.syncActivationPolicy()
            self.setPresentationMode(presentationMode)
        }
        setPresentationMode(presentationMode)
    }

    func setPresentationMode(_ mode: PresentationMode) {
        let previousWindow = currentWindow
        let wasVisible = previousWindow.isVisible
        let previousFrame = previousWindow.frame
        previousWindow.orderOut(nil)

        switch mode {
        case .attached:
            currentWindow = attachedWindow
        case .floating:
            currentWindow = floatingWindow
        }
        installHostingView(in: currentWindow.contentView!)
        currentWindow.setFrame(previousFrame, display: false)

        if wasVisible {
            NSApp.activate()
            currentWindow.makeKeyAndOrderFront(nil)
            currentWindow.makeFirstResponder(nil)
        }
    }

    private func showWindow() {
        if presentationMode == .attached {
            attachedWindow.repositionWindow(relativeTo: statusItem?.button)
        }
        presentationState.setWindowVisible(true)
        if presentationMode == .floating {
            NSApp.activate(ignoringOtherApps: true)
        }
        currentWindow.makeKeyAndOrderFront(nil)
        currentWindow.makeFirstResponder(nil)
        syncActivationPolicy()
    }

    private func hideWindow() {
        currentWindow.orderOut(nil)
        presentationState.setWindowVisible(false)
        syncActivationPolicy()
    }

    private func syncActivationPolicy() {
        let desiredActivationPolicy: NSApplication.ActivationPolicy =
            presentationMode == .floating && currentWindow.isVisible ? .regular : .accessory

        if NSApp.activationPolicy() != desiredActivationPolicy {
            NSApp.setActivationPolicy(desiredActivationPolicy)
        }
    }

    private func installHostingView(in containerView: NSView) {
        hostingView.removeFromSuperview()
        hostingView.frame = containerView.bounds
        containerView.addSubview(hostingView)
    }

    func setStatusItem(_ item: NSStatusItem?) {
        statusItem = item
        guard let item else { return }
        configureStatusItemAction(for: item)
    }

    private func configureStatusItemAction(for item: NSStatusItem) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemAction)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
    }

    @objc private func handleStatusItemAction() {
        guard let statusItem else { return }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown:
            handleStatusItemLeftClick()
        case .rightMouseUp:
            handleStatusItemRightClick(from: statusItem)
        default:
            return
        }
    }

    func handleStatusItemLeftClick() {
        toggleFromStatusItem()
    }

    func handleStatusItemRightClick(from statusItem: NSStatusItem) {
        guard let statusItemMenu else { return }
        let selector = NSSelectorFromString("popUpStatusItemMenu:")
        if statusItem.responds(to: selector) {
            _ = statusItem.perform(selector, with: statusItemMenu)
        } else if let button = statusItem.button {
            statusItemMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height),
                in: button
            )
        }
    }

    private func toggleFromStatusItem() {
        if presentationMode == .floating, !currentWindow.isKeyWindow {
            showWindow()
        } else if currentWindow.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if presentationMode == .attached {
            hideWindow()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === floatingWindow {
            presentationState.setPresentationMode(.attached)
        } else if sender === attachedWindow {
            hideWindow()
        }
        return false
    }
}

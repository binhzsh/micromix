import AppKit
import SwiftUI

/// Only active timeline editors participate; unrelated windows keep their delegates.
@MainActor
final class TimelineCloseRegistry {
    static let shared = TimelineCloseRegistry()
    private var guards: [UUID: () -> Bool] = [:]

    func register(_ id: UUID, guard canClose: @escaping () -> Bool) { guards[id] = canClose }
    func unregister(_ id: UUID) { guards.removeValue(forKey: id) }
    func mayQuit() -> Bool { guards.values.allSatisfy { $0() } }
}

@MainActor
final class TimelineApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TimelineCloseRegistry.shared.mayQuit() ? .terminateNow : .terminateCancel
    }
}

/// Intercepts the owning workspace window only while its timeline sheet exists.
struct TimelineWindowGuard: NSViewRepresentable {
    let canClose: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.coordinator = context.coordinator
        context.coordinator.canClose = canClose
        context.coordinator.register()
        return view
    }
    func updateNSView(_ view: GuardView, context: Context) {
        context.coordinator.canClose = canClose
        view.install()
    }
    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) { coordinator.uninstall() }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
            DispatchQueue.main.async { [weak self] in self?.install() }
        }
        func install() {
            guard let window else { return }
            coordinator?.install(on: window.sheetParent ?? window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let id = UUID()
        var canClose: () -> Bool = { false }
        weak var window: NSWindow?
        weak var previousDelegate: (any NSWindowDelegate)?

        func register() {
            TimelineCloseRegistry.shared.register(id) { [weak self] in self?.canClose() ?? false }
        }
        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            restoreWindow()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }
        func uninstall() {
            TimelineCloseRegistry.shared.unregister(id)
            restoreWindow()
        }
        private func restoreWindow() {
            if let window, window.delegate === self { window.delegate = previousDelegate }
            window = nil
            previousDelegate = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard canClose() else { return false }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

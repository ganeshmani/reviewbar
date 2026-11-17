import AppKit
import Combine
import SwiftUI
import ReviewBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var bag: Set<AnyCancellable> = []
    private var spinner: Timer?
    private var phase: CGFloat = 0
    private var windows: [String: NSWindow] = [:]
    private var panel: NSPanel?
    private var showName: Notification.Name { .init("dev.reviewbar.show" + (model.demo ? ".demo" : "")) }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = Self.editMenu()
        // One copy per data folder: a second launch asks the running one to show itself, then exits.
        let lock = open(model.store.dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
            DistributedNotificationCenter.default().postNotificationName(showName, object: nil, deliverImmediately: true)
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: showName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }

        // First launch: put the icon at the right end of the menu bar, next to the system items,
        // so a crowded menu bar doesn't push it behind the notch. Cmd-drag still moves it.
        let posKey = "NSStatusItem Preferred Position ReviewBar"
        if UserDefaults.standard.object(forKey: posKey) == nil { UserDefaults.standard.set(1, forKey: posKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ReviewBar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: RootView().environmentObject(model).environmentObject(WindowRouter(self)))
        // Fixed size: a status-item popover that resizes or re-anchors while open can jump to the screen's left edge.
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 380, height: 600)

        model.onOpenDetail = { [weak self] _ in self?.show() }
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refreshIcon() }
            .store(in: &bag)
        HotKey.shared.action = { [weak self] in self?.toggle() }
        HotKey.shared.setEnabled(model.settings.hotkeyEnabled)
        model.start()
        refreshIcon()

        let args = CommandLine.arguments
        if args.contains("--debug-status") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let w = self.statusItem.button?.window
                print("status window:", w?.frame as Any, "visible:", w?.occlusionState.contains(.visible) as Any, "screen:", w?.screen?.frame as Any)
                fflush(stdout); exit(0)
            }
        }
        if args.contains("--open") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.show() } }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { Snapshot.run(model: model, router: WindowRouter(self), dir: args[i + 1]) }
    }

    private func refreshIcon() {
        let state = model.iconState
        let oldWidth = statusItem.button?.frame.width ?? 0
        statusItem.button?.image = StatusIcon.image(state, phase: phase)
        var title = ""
        if case .needs(let n) = state, n > 0 { title = "\(n)" }
        if case .failure(let n) = state, n > 0 { title = "\(n)" }
        if statusItem.button?.title != title { statusItem.button?.title = title }
        // A variable-width status item that changes size leaves an open popover anchored to its old spot
        // (it jumps to the screen's left edge). Re-anchor it after the button lays out again.
        // Re-anchor only when the icon actually changed width (spinner or count appeared), never on other state changes.
        if popover.isShown, let button = statusItem.button {
            button.superview?.layoutSubtreeIfNeeded()
            if abs(button.frame.width - oldWidth) > 0.5 { popover.positioningRect = button.bounds }
        }
        let needs = model.count(.needsDecision)
        statusItem.button?.setAccessibilityLabel("ReviewBar, \(needs) need decision, \(model.runningCount) running, \(model.count(.failed)) failed")
        if state == .running, spinner == nil {
            spinner = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.phase = (self.phase - 30).truncatingRemainder(dividingBy: 360)
                    self.statusItem.button?.image = StatusIcon.image(self.model.iconState, phase: self.phase)
                }
            }
        } else if state != .running {
            spinner?.invalidate(); spinner = nil
        }
    }

    @objc func toggle() {
        // Right-click or Control-click: small menu with Settings and Quit.
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            showMenu(); return
        }
        if popover.isShown { popover.performClose(nil) }
        else if let panel, panel.isVisible { panel.orderOut(nil) }
        else { show() }
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ReviewBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc func openSettings() { WindowRouter(self).settings() }

    /// The menu bar icon can be hidden (behind the notch or by a menu bar manager);
    /// then the inbox opens in a floating window instead of an invisible popover.
    /// On notched displays macOS hides status items that don't fit right of the notch (long app menus push them out).
    /// A hidden item still reports a window, so also require it to sit fully on screen and right of the notch.
    private var statusItemVisible: Bool {
        guard let w = statusItem.button?.window, let screen = w.screen else { return false }
        let f = w.frame
        guard w.occlusionState.contains(.visible), f.width > 0, screen.frame.contains(f) else { return false }
        if let right = screen.auxiliaryTopRightArea, f.minX < screen.frame.minX + right.minX - 1 { return false }
        return f.minX > screen.frame.minX + 1
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem.button, statusItemVisible {
            panel?.orderOut(nil)
            if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "ReviewBar"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentViewController = NSHostingController(rootView: RootView().environmentObject(model).environmentObject(WindowRouter(self)))
            if let vf = NSScreen.main?.visibleFrame { p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 400, y: vf.maxY - 8)) }
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show(); return false
    }

    func popoverDidClose(_ notification: Notification) {
        if case .post = model.route { model.route = .inbox }
        if case .approve = model.route { model.route = .inbox }
    }

    func openWindow<V: View>(_ key: String, title: String, size: NSSize, @ViewBuilder _ content: () -> V) {
        popover.performClose(nil)
        panel?.orderOut(nil)
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content().environmentObject(model))
        w.setContentSize(size)
        w.center()
        windows[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windows[key] = nil }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate {
    /// A menu bar app has no visible menu bar, but ⌘X/⌘C/⌘V/⌘A/⌘Z only reach text fields through the main menu's
    /// key equivalents. Never shown (LSUIElement), only used for shortcuts.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}

/// Lets SwiftUI views open the Settings and Run log windows.
@MainActor
final class WindowRouter: ObservableObject {
    weak var delegate: AppDelegate?
    init(_ d: AppDelegate) { delegate = d }
    func settings() {
        delegate?.openWindow("settings", title: "ReviewBar Settings", size: NSSize(width: 620, height: 520)) { SettingsView() }
    }
    func log(_ runID: String) {
        delegate?.openWindow("log-\(runID)", title: "Run log", size: NSSize(width: 680, height: 480)) { RunLogView(runID: runID) }
    }
    func closePopover() { delegate?.toggle() }
}

// Headless diagnostics: `ReviewBar --selftest-engine claude|codex` or `--selftest-forge <MR/PR URL>`.
if let i = CommandLine.arguments.firstIndex(where: { $0.hasPrefix("--selftest-") }), i + 1 < CommandLine.arguments.count {
    let flag = CommandLine.arguments[i], arg = CommandLine.arguments[i + 1]
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let settings = (try? Data(contentsOf: Store.defaultDir.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        if flag == "--selftest-engine" {
            let kind = EngineKind(rawValue: arg) ?? .claude
            let exe = (kind == .claude ? settings.claudePath : settings.codexPath).nilIfEmpty ?? Shell.which(kind.rawValue) ?? kind.rawValue
            print(await Diagnostics.testEngine(kind, executable: exe, model: kind == .claude ? settings.claudeModel : settings.codexModel,
                                               gate: Shell.split(settings.gateCommand)))
        } else {
            print(await Diagnostics.testForge(arg, accounts: settings.accounts))
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

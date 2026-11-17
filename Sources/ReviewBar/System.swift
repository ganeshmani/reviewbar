import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// MARK: - Notifications: grouped per MR thread; buttons are Open and Snooze only (FR-19)

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    var onSnooze: ((String) -> Void)?
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()   // unbundled `swift run` has no center
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 1 h", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "REVIEW", actions: [open, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "OPEN", actions: [open], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(thread: String, title: String, body: String, snoozable: Bool, quiet: Bool) {
        guard let center else { NSLog("ReviewBar notification: \(title) — \(body)"); return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = thread
        c.categoryIdentifier = snoozable ? "REVIEW" : "OPEN"
        c.userInfo = ["mr": thread]
        c.interruptionLevel = quiet ? .passive : .active    // quiet hours: straight to Notification Center
        c.sound = quiet ? nil : .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking never performs a remote action: it opens the detail view or snoozes (acceptance 12).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["mr"] as? String ?? ""
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if action == "SNOOZE" { self.onSnooze?(id) }
            else if id != "digest" { self.onOpen?(id) }
            else { self.onOpen?("") }
        }
        completionHandler()
    }
}

// MARK: - Prevent idle sleep while work is queued or running (FR-8a, same as caffeinate -i)

final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var held = false
    func hold() {
        guard !held else { return }
        held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "ReviewBar: code reviews queued or running" as CFString, &id) == kIOReturnSuccess
    }
    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
    }
}

// MARK: - Global shortcut ⌥⌘R (FR-20)

final class HotKey {
    static let shared = HotKey()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ on: Bool) {
        if on, ref == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
            let hkID = EventHotKeyID(signature: OSType(0x5242_4152), id: 1) // 'RBAR'
            RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey | cmdKey), hkID, GetApplicationEventTarget(), 0, &ref)
        } else if !on, let r = ref {
            UnregisterEventHotKey(r); ref = nil
            if let h = handler { RemoveEventHandler(h); handler = nil }
        }
    }
}

// MARK: - Launch at login (FR-21)

enum LaunchAtLogin {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Menu bar icon (idle · running · needs decision · failure · paused)

enum StatusIcon {
    /// Signal Bar mark (Brand Logo System): the menu bar line, a solid bead (what the AI did),
    /// an open bead (what you decided). Template image so it follows the menu bar colour.
    static func image(_ state: AppModel.IconState, phase: CGFloat) -> NSImage {
        let failed: Bool
        if case .failure = state { failed = true } else { failed = false }
        let paused = state == .paused
        let size = NSSize(width: paused ? 28 : 24, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let fg = failed ? NSColor.labelColor : NSColor.black.withAlphaComponent(paused ? 0.45 : 1)
            let y: CGFloat = 9, x0: CGFloat = 2, x1: CGFloat = 22
            let solid = NSPoint(x: 8, y: y), open = NSPoint(x: 16, y: y)
            fg.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: y - 0.8, width: x1 - x0, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(ovalIn: NSRect(x: solid.x - 3.4, y: y - 3.4, width: 6.8, height: 6.8)).fill()
            // Punch the line out behind the open bead so it reads as hollow.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: open.x - 3.6, y: y - 3.6, width: 7.2, height: 7.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            fg.setStroke()
            if state == .running {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: open, radius: 2.9, startAngle: phase, endAngle: phase + 250)
                arc.lineWidth = 1.5; arc.lineCapStyle = .round; arc.stroke()
            } else {
                let ring = NSBezierPath(ovalIn: NSRect(x: open.x - 2.9, y: y - 2.9, width: 5.8, height: 5.8))
                ring.lineWidth = 1.4; ring.stroke()
            }
            if paused {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 23.5, y: 5, width: 1.6, height: 8), xRadius: 0.5, yRadius: 0.5).fill()
                NSBezierPath(roundedRect: NSRect(x: 26.2, y: 5, width: 1.6, height: 8), xRadius: 0.5, yRadius: 0.5).fill()
            }
            if failed {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18.5, y: 11.5, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        // Template keeps it in step with light/dark menu bars; the failure dot needs its colour, so that state stays untemplated.
        img.isTemplate = !failed
        return img
    }
}

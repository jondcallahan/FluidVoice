import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Identity of the app the user was in when dictation started.
///
/// Application name is always resolved from the running process / bundle.
/// Window titles (conversation names, document names, tab titles) stay on
/// `windowTitle` and are never used as the app name.
struct RecordingAppContext: Equatable, Sendable {
    var processID: pid_t?
    var name: String
    var bundleId: String
    var windowTitle: String

    var tuple: (name: String, bundleId: String, windowTitle: String) {
        (name: self.name, bundleId: self.bundleId, windowTitle: self.windowTitle)
    }

    static func targetProcessID(
        preferred: pid_t? = nil,
        excluding excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> pid_t? {
        if let preferred, preferred > 0, preferred != excludedPID {
            return preferred
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != excludedPID
        {
            return front.processIdentifier
        }
        return self.firstOnScreenProcessID(excluding: excludedPID)
    }

    static func capture(
        preferredProcessID: pid_t? = nil,
        excluding excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> RecordingAppContext {
        let processID = self.targetProcessID(preferred: preferredProcessID, excluding: excludedPID)
        let application = processID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let windowTitle = self.windowTitle(for: processID) ?? ""

        return RecordingAppContext(
            processID: processID,
            name: self.applicationDisplayName(
                processID: processID,
                bundleIdentifier: application?.bundleIdentifier,
                reportedApplicationName: application?.localizedName ?? self.ownerName(for: processID),
                windowTitle: windowTitle
            ),
            bundleId: application?.bundleIdentifier ?? "unknown",
            windowTitle: windowTitle
        )
    }

    /// Resolves a display name from process/bundle identity. A reported name that
    /// is just the window title is ignored so conversation/document titles cannot
    /// masquerade as the application.
    static func applicationDisplayName(
        processID: pid_t?,
        bundleIdentifier: String?,
        reportedApplicationName: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        if let processID,
           let application = NSRunningApplication(processIdentifier: processID),
           let name = self.normalized(application.localizedName)
        {
            return name
        }
        if let bundleIdentifier, let name = self.displayName(forBundleIdentifier: bundleIdentifier) {
            return name
        }
        if let reported = self.normalized(reportedApplicationName),
           !self.isSameTitle(reported, windowTitle)
        {
            return reported
        }
        if let bundleIdentifier,
           let lastComponent = bundleIdentifier.split(separator: ".").last,
           !lastComponent.isEmpty
        {
            return String(lastComponent)
        }
        return "Unknown"
    }

    static func formatWindowContext(
        applicationName: String,
        windowTitle: String?,
        content: String
    ) -> String {
        let title = self.normalized(windowTitle) ?? applicationName
        return """
        Active Window: \(title)
        Application: \(applicationName)

        Window Content:
        \(content)
        """
    }

    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSameTitle(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs = self.normalized(rhs) else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func displayName(forBundleIdentifier bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        if let bundle = Bundle(url: url) {
            if let name = self.normalized(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) {
                return name
            }
            if let name = self.normalized(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) {
                return name
            }
        }
        let displayName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return self.normalized(displayName)
    }

    private static func windowTitle(for processID: pid_t?) -> String? {
        guard let processID else { return nil }

        if let title = self.cgWindowTitle(for: processID) {
            return title
        }

        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(processID)
        let focusedWindow = self.copyAXElement(kAXFocusedWindowAttribute, from: appElement)
            ?? self.copyAXElement(kAXMainWindowAttribute, from: appElement)
        guard let focusedWindow else { return nil }
        return self.normalized(self.copyAXString(kAXTitleAttribute, from: focusedWindow))
    }

    private static func ownerName(for processID: pid_t?) -> String? {
        guard let processID else { return nil }
        return self.firstWindowInfo(for: processID).flatMap {
            self.normalized($0[kCGWindowOwnerName as String] as? String)
        }
    }

    private static func cgWindowTitle(for processID: pid_t) -> String? {
        self.firstWindowInfo(for: processID).flatMap {
            self.normalized($0[kCGWindowName as String] as? String)
        }
    }

    private static func firstOnScreenProcessID(excluding excludedPID: pid_t) -> pid_t? {
        self.onScreenWindows()?.lazy
            .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
            .first { $0 != excludedPID && $0 > 0 }
    }

    private static func firstWindowInfo(for processID: pid_t) -> [String: Any]? {
        self.onScreenWindows()?.first { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == processID else {
                return false
            }
            let name = info[kCGWindowName as String] as? String
            return self.normalized(name) != nil
        } ?? self.onScreenWindows()?.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == processID
        }
    }

    private static func onScreenWindows() -> [[String: Any]]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    }

    private static func copyAXElement(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func copyAXString(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

enum AIPromptSnapshotFormatter {
    static func format(messages: [(role: String, content: String)]) -> String {
        messages
            .map { role, content in
                "===== \(role) =====\n\(content)"
            }
            .joined(separator: "\n\n")
    }

    static func format(messages: [[String: Any]]) -> String {
        let pairs = messages.compactMap { message -> (String, String)? in
            guard let role = message["role"] as? String,
                  let content = message["content"] as? String
            else {
                return nil
            }
            return (role, content)
        }
        return self.format(messages: pairs)
    }
}

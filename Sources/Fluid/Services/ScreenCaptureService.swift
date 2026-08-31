import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

@MainActor
enum ScreenCaptureService {
    private struct FocusedWindowHint: Sendable {
        let processID: pid_t
        let title: String?
        let frame: CGRect?
    }

    private static let captureTimeout: TimeInterval = 3.0
    private static let maximumCaptureDimension: CGFloat = 2800
    private static let focusedWindowFrameTolerance: CGFloat = 96

    nonisolated static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Heavy work stays off the main actor so overlay and audio startup are not delayed.
    nonisolated static func captureWindowContext(preferredProcessID: pid_t? = nil) async -> String? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let focusedWindowHint = focusedWindowHint(
            excluding: currentPID,
            preferredProcessID: preferredProcessID
        )

        guard
            let contextText = await withTimeout(
                seconds: captureTimeout,
                operation: {
                    await captureAndExtractWindowText(
                        focusedWindowHint: focusedWindowHint,
                        currentPID: currentPID
                    )
                }
            )
        else {
            DebugLogger.shared.debug("Screen context capture timed out or failed", source: "ScreenCaptureService")
            return nil
        }

        DebugLogger.shared.debug(
            "Captured screen context (\(contextText.count) chars)",
            source: "ScreenCaptureService"
        )
        return contextText
    }

    static func requestScreenCapturePermissionRegistration() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        if CGRequestScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DebugLogger.shared.debug(
                "Screen capture permission probe failed: \(error.localizedDescription)",
                source: "ScreenCaptureService"
            )
            return CGPreflightScreenCaptureAccess()
        }

        return CGPreflightScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated static func focusedWindowHint(
        excluding currentPID: pid_t,
        preferredProcessID: pid_t?
    ) -> FocusedWindowHint? {
        let targetPID = preferredProcessID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let targetPID, targetPID != currentPID else {
            return nil
        }

        var focusedTitle: String?
        var focusedFrame: CGRect?

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(targetPID)
            if let focusedWindow = copyAXElementAttribute(kAXFocusedWindowAttribute, from: appElement) {
                focusedTitle = RecordingAppContext.normalized(copyStringAttribute(kAXTitleAttribute, from: focusedWindow))

                if let position = copyCGPointAttribute(kAXPositionAttribute, from: focusedWindow),
                   let size = copyCGSizeAttribute(kAXSizeAttribute, from: focusedWindow)
                {
                    focusedFrame = CGRect(origin: position, size: size)
                }
            }
        }

        return FocusedWindowHint(
            processID: targetPID,
            title: focusedTitle,
            frame: focusedFrame
        )
    }

    private nonisolated static func captureAndExtractWindowText(
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard
                let window = findActiveWindow(
                    in: content.windows,
                    focusedWindowHint: focusedWindowHint,
                    currentPID: currentPID
                )
            else {
                return nil
            }

            let owningApplication = window.owningApplication
            let appName = RecordingAppContext.applicationDisplayName(
                processID: owningApplication?.processID,
                bundleIdentifier: owningApplication?.bundleIdentifier,
                reportedApplicationName: owningApplication?.applicationName,
                windowTitle: window.title
            )

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let captureScale = captureScale(for: window.frame.size)
            configuration.width = max(1, Int(window.frame.width * captureScale))
            configuration.height = max(1, Int(window.frame.height * captureScale))

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            return RecordingAppContext.formatWindowContext(
                applicationName: appName,
                windowTitle: window.title,
                content: RecordingAppContext.normalized(extractText(from: cgImage))
                    ?? "No text detected via OCR"
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func findActiveWindow(
        in windows: [SCWindow],
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard let processID = window.owningApplication?.processID else {
                return false
            }

            return processID != currentPID
                && window.windowLayer == 0
                && window.isOnScreen
                && window.frame.width > 0
                && window.frame.height > 0
        }

        guard let focusedWindowHint else {
            return candidates.first
        }

        let appWindows = candidates.filter {
            $0.owningApplication?.processID == focusedWindowHint.processID
        }

        guard !appWindows.isEmpty else {
            return candidates.first
        }

        if let focusedFrame = focusedWindowHint.frame,
           let closestWindow = closestFrameMatch(to: focusedFrame, in: appWindows),
           frameDistance(closestWindow.frame, focusedFrame) <= focusedWindowFrameTolerance
        {
            return closestWindow
        }

        if let focusedTitle = focusedWindowHint.title,
           let titledWindow = appWindows.first(where: { RecordingAppContext.normalized($0.title) == focusedTitle })
        {
            return titledWindow
        }

        return appWindows.first
    }

    private nonisolated static func closestFrameMatch(to frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        windows.min {
            frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
        }
    }

    private nonisolated static func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.origin.x - second.origin.x)
            + abs(first.origin.y - second.origin.y)
            + abs(first.size.width - second.size.width)
            + abs(first.size.height - second.size.height)
    }

    private nonisolated static func captureScale(for size: CGSize) -> CGFloat {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else {
            return 1
        }
        return min(2, maximumCaptureDimension / longestSide)
    }

    private nonisolated static func extractText(from cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try requestHandler.perform([request])
            guard let observations = request.results else {
                return nil
            }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private nonisolated static func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private nonisolated static func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize
        else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}

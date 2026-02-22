import AppKit
import SwiftUI

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private var singleInstanceLock: SingleInstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lock = SingleInstanceLock.acquire(lockName: "mcontrol.instance.lock") else {
            NSApp.terminate(nil)
            return
        }
        singleInstanceLock = lock
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct mControlApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel

    init() {
        let viewModel: AppViewModel

        do {
            viewModel = try AppViewModel.live()
        } catch {
            viewModel = AppViewModel.fallbackWithError(error.localizedDescription)
        }

        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(viewModel: viewModel)
        } label: {
            MenuBarStatusIcon(isActive: viewModel.hasActiveSessions)
        }
        .menuBarExtraStyle(.window)

        Window("mControl Dashboard", id: "dashboard") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 760, minHeight: 760)
        }

        Window("mControl Settings", id: "settings") {
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 520, minHeight: 460)
        }
    }
}

private struct MenuBarStatusIcon: View {
    let isActive: Bool

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(isActive: isActive))
            .renderingMode(.original)
            .accessibilityLabel(isActive ? "mControl active" : "mControl idle")
    }
}

private enum MenuBarIconRenderer {
    private static let iconSize = NSSize(width: 18, height: 18)
    private static let iconRect = NSRect(x: 1, y: 1, width: 16, height: 16)

    static func image(isActive: Bool) -> NSImage {
        let image = NSImage(size: iconSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let activeFillColor = NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.44, alpha: 1.0)

        if isActive {
            drawSymbol(named: "shield.fill", color: activeFillColor)
        }

        drawSymbol(named: "shield", color: .labelColor)
        image.isTemplate = false
        return image
    }

    private static func drawSymbol(named symbolName: String, color: NSColor) {
        guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        let symbolConfig = sizeConfig.applying(paletteConfig)
        let configuredSymbol = baseSymbol.withSymbolConfiguration(symbolConfig) ?? baseSymbol
        configuredSymbol.draw(in: iconRect)
    }
}

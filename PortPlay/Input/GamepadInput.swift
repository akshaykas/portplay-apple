import Foundation
import GameController

/// A controller connected to this Mac or iPad (not the one paired with the console).
/// Hold Select (View, Share or Create) and press a button, like the Windows version.
final class GamepadInput {
    enum Action: CaseIterable {
        case screenshot, record, replay, fullscreen, nextScaling, nextFilter, stats
    }

    enum Brand {
        case playstation, xbox, nintendo, other
    }

    /// How one button is printed on the controller. `symbol` is the SF Symbol
    /// Apple provides for that exact button, like a cross for a DualSense.
    struct ButtonLabel: Equatable {
        let text: String
        let symbol: String?
    }

    /// The buttons of the controller in use, for the shortcut list in settings.
    struct Layout: Equatable {
        let brand: Brand
        /// What the Select button is called on this controller
        let select: String
        let keys: [Action: ButtonLabel]
    }

    /// All called on the main thread.
    var onAction: ((Action) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onLayoutChange: ((Layout) -> Void)?
    var onConnect: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController {
                self?.bind(controller)
            }
            self?.reportStatus()
            self?.onConnect?()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.reportStatus()
        })
        // The last controller used becomes the current one
        observers.append(center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            self?.reportStatus()
        })
    }

    func begin() {
        GCController.controllers().forEach(bind)
        reportStatus()
    }

    var statusText: String {
        let names = GCController.controllers()
            .filter { $0.extendedGamepad != nil }
            .map { $0.vendorName ?? "Controller" }
        if names.isEmpty {
            #if os(iOS)
            return "Connect a controller to this iPad and press any button."
            #else
            return "Plug a controller into this Mac and press any button."
            #endif
        }
        return "Connected: \(names.joined(separator: ", "))"
    }

    private func reportStatus() {
        onStatusChange?(statusText)
        onLayoutChange?(layout)
    }

    /// The controller in use, or the generic names when none is connected.
    var layout: Layout {
        let controller = GCController.current?.extendedGamepad != nil
            ? GCController.current
            : GCController.controllers().first(where: { $0.extendedGamepad != nil })
        guard let controller, let pad = controller.extendedGamepad else {
            return Self.makeLayout(brand: .other, select: "Select", pad: nil)
        }

        let category = controller.productCategory.lowercased()
        let vendor = (controller.vendorName ?? "").lowercased()
        let brand: Brand
        let select: String
        if pad is GCDualSenseGamepad || category.contains("dualsense") {
            brand = .playstation
            select = "Create"
        } else if pad is GCDualShockGamepad || category.contains("dualshock") {
            brand = .playstation
            select = "Share"
        } else if pad is GCXboxGamepad || category.contains("xbox") || vendor.contains("xbox") {
            brand = .xbox
            select = "View"
        } else if category.contains("switch") || category.contains("joy-con") || vendor.contains("pro controller") {
            brand = .nintendo
            select = "−"
        } else {
            brand = .other
            select = "Select"
        }
        return Self.makeLayout(brand: brand, select: select, pad: pad)
    }

    private static func makeLayout(brand: Brand, select: String, pad: GCExtendedGamepad?) -> Layout {
        // Short names for when there's no symbol to show
        let names: [Action: String]
        switch brand {
        case .playstation:
            names = [.screenshot: "✕", .record: "○", .replay: "□", .fullscreen: "△", .nextScaling: "L1", .nextFilter: "R1", .stats: "Options"]
        case .xbox:
            names = [.screenshot: "A", .record: "B", .replay: "X", .fullscreen: "Y", .nextScaling: "LB", .nextFilter: "RB", .stats: "Menu"]
        case .nintendo, .other:
            names = [.screenshot: "A", .record: "B", .replay: "X", .fullscreen: "Y", .nextScaling: "LB", .nextFilter: "RB", .stats: "Start"]
        }

        func button(for action: Action) -> GCControllerButtonInput? {
            guard let pad else { return nil }
            switch action {
            case .screenshot: return pad.buttonA
            case .record: return pad.buttonB
            case .replay: return pad.buttonX
            case .fullscreen: return pad.buttonY
            case .nextScaling: return pad.leftShoulder
            case .nextFilter: return pad.rightShoulder
            case .stats: return pad.buttonMenu
            }
        }

        var keys: [Action: ButtonLabel] = [:]
        for action in Action.allCases {
            let symbol = button(for: action)?.sfSymbolsName
            // Nintendo puts A and B the other way round, so trust Apple's symbol for its name
            var text = names[action] ?? ""
            if brand == .nintendo, let name = symbol.flatMap(Self.letter(fromSymbol:)) {
                text = name
            }
            keys[action] = ButtonLabel(text: text, symbol: symbol)
        }
        return Layout(brand: brand, select: select, keys: keys)
    }

    /// "a.circle" becomes "A", "l.rectangle.roundedbottom" becomes "L".
    private static func letter(fromSymbol symbol: String) -> String? {
        guard let first = symbol.split(separator: ".").first, (1...2).contains(first.count) else { return nil }
        return first.uppercased()
    }

    private func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main

        let select = pad.buttonOptions
        func on(_ button: GCControllerButtonInput?, _ action: Action) {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed, select?.isPressed == true else { return }
                self?.onAction?(action)
            }
        }

        on(pad.buttonA, .screenshot)
        on(pad.buttonB, .record)
        on(pad.buttonX, .replay)
        on(pad.buttonY, .fullscreen)
        on(pad.leftShoulder, .nextScaling)
        on(pad.rightShoulder, .nextFilter)
        on(pad.buttonMenu, .stats)
    }
}

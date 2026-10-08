import Foundation
import GameController

/// A controller connected to this Mac or iPad (not the one paired with the console).
/// Hold Select (View, Share or Create) and press a button, like the Windows version.
final class GamepadInput {
    enum Action {
        case screenshot, record, replay, fullscreen, nextScaling, nextFilter, stats
    }

    /// All called on the main thread.
    var onAction: ((Action) -> Void)?
    var onStatusChange: ((String) -> Void)?
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

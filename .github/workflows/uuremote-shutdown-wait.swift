import AppKit
import Foundation


enum InjectedEvent: String {
    case none
    case ordinary
    case powerOff = "power-off"
}


final class ShutdownWaiter {
    private let seconds: Int
    private let injectedEvent: InjectedEvent
    private var finished = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(seconds: Int, injectedEvent: InjectedEvent) {
        self.seconds = seconds
        self.injectedEvent = injectedEvent
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .systemDefined && event.subtype == .powerOff {
            finish("shutdown/restart")
        }

        return event
    }

    private func finish(_ reason: String) {
        guard !finished else { return }

        finished = true
        print("WAIT_RESULT=\(reason)")
        fflush(stdout)
        NSApplication.shared.stop(nil)

        let wakeEvent = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )!
        NSApplication.shared.postEvent(wakeEvent, atStart: false)
    }

    private func scheduleInjectedEvent(on application: NSApplication) {
        guard injectedEvent != .none else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            [weak self] in
            guard let self else { return }

            let subtype: NSEvent.EventSubtype =
                self.injectedEvent == .powerOff ? .powerOff : .mouseEvent
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: subtype.rawValue,
                data1: 0,
                data2: 0
            )!
            application.postEvent(event, atStart: false)
        }
    }

    func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in
            self?.handle(event) ?? event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in
            _ = self?.handle(event)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            [weak self] in
            self?.finish("timeout")
        }

        scheduleInjectedEvent(on: application)
        application.run()

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}


let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.count == 1 || arguments.count == 2,
      let seconds = Int(arguments[0]),
      (0...21000).contains(seconds)
else {
    fputs(
        "usage: uuremote-shutdown-wait <0-21000> [none|ordinary|power-off]\n",
        stderr
    )
    exit(2)
}

let eventText = arguments.count == 2 ? arguments[1] : "none"

guard let injectedEvent = InjectedEvent(rawValue: eventText) else {
    fputs("invalid injected event: \(eventText)\n", stderr)
    exit(2)
}

let waiter = ShutdownWaiter(seconds: seconds, injectedEvent: injectedEvent)
withExtendedLifetime(waiter) {
    waiter.run()
}

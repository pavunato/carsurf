import Cocoa

guard CommandLine.arguments.count == 5,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]),
      let endY = Double(CommandLine.arguments[3]),
      let duration = Double(CommandLine.arguments[4]), duration > 0 else {
    fatalError("usage: carplay-swipe x startY endY duration")
}
guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is required for the invoking terminal.\n", stderr)
    exit(1)
}
func post(_ type: CGEventType, _ point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: point, mouseButton: .left)!
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}
post(.mouseMoved, CGPoint(x: x, y: y))
post(.leftMouseDown, CGPoint(x: x, y: y))
for step in 1...40 {
    Thread.sleep(forTimeInterval: duration / 40)
    post(.leftMouseDragged, CGPoint(x: x, y: y + (endY - y) * Double(step) / 40))
}
post(.leftMouseUp, CGPoint(x: x, y: endY))
// Allow the posted release to reach the simulator before this process exits.
Thread.sleep(forTimeInterval: 0.1)

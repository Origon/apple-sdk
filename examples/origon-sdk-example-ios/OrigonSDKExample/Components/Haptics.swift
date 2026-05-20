import UIKit

// App-wide haptic feedback. Generators are instantiated per-call and
// `prepare()`'d immediately before firing so the impact is low-latency
// without holding a long-lived generator reference.
enum Haptics {
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}

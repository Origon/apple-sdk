import SwiftUI
import UIKit

// UIKit-backed left-edge pan gesture recognizer wrapped for SwiftUI.
//
// Why UIKit instead of SwiftUI DragGesture:
//   UIScreenEdgePanGestureRecognizer automatically wins the conflict against
//   ScrollView's UIPanGestureRecognizer — UIKit's gesture system gives edge
//   pans priority out of the box. A SwiftUI DragGesture on a parent view
//   can't beat a child ScrollView's built-in pan.
//
// Usage:
//   .edgePanGesture(edge: .left) { state in
//       switch state {
//       case .changed(let translation): ...
//       case .ended(let translation, let velocity): ...
//       case .cancelled: ...
//       }
//   }

enum EdgePanState {
    case changed(translation: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled
}

extension View {
    func edgePanGesture(
        edge: UIRectEdge,
        enabled: Bool = true,
        handler: @escaping (EdgePanState) -> Void
    ) -> some View {
        overlay(EdgePanGestureView(edge: edge, enabled: enabled, handler: handler))
    }
}

private struct EdgePanGestureView: UIViewRepresentable {
    let edge: UIRectEdge
    let enabled: Bool
    let handler: (EdgePanState) -> Void

    func makeUIView(context: Context) -> PassThroughEdgeView {
        let view = PassThroughEdgeView()
        view.backgroundColor = .clear
        view.edge = edge
        view.isEdgeActive = enabled

        let recognizer = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.edges = edge
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: PassThroughEdgeView, context: Context) {
        uiView.isEdgeActive = enabled
        context.coordinator.handler = handler
    }

    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

    class Coordinator: NSObject {
        var handler: (EdgePanState) -> Void

        init(handler: @escaping (EdgePanState) -> Void) {
            self.handler = handler
        }

        @objc func handlePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view).x
            let velocity = recognizer.velocity(in: view).x

            switch recognizer.state {
            case .changed:
                handler(.changed(translation: translation))
            case .ended:
                handler(.ended(translation: translation, velocity: velocity))
            case .cancelled, .failed:
                handler(.cancelled)
            default:
                break
            }
        }
    }
}

// Only claims touches within a narrow strip along the specified edge.
// All other touches pass through to SwiftUI views underneath so toolbar
// buttons, message scroll, input field, etc. keep working normally.
fileprivate class PassThroughEdgeView: UIView {
    var edge: UIRectEdge = .left
    // When false the entire view passes through all touches — UIKit's
    // interactive pop gesture (or any other recognizer underneath) gets them.
    var isEdgeActive: Bool = true
    private let edgeWidth: CGFloat = 24

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isEdgeActive else { return nil }
        let inEdge: Bool
        switch edge {
        case .left:   inEdge = point.x <= edgeWidth
        case .right:  inEdge = point.x >= bounds.width - edgeWidth
        case .top:    inEdge = point.y <= edgeWidth
        case .bottom: inEdge = point.y >= bounds.height - edgeWidth
        default:      inEdge = false
        }
        return inEdge ? self : nil
    }
}

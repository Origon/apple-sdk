import SwiftUI
import UIKit

// Re-enables the interactive swipe-from-left-edge pop gesture on views that
// hide the default navigation-bar back button via
// `.navigationBarBackButtonHidden(true)`. By default SwiftUI disables the
// gesture recognizer's delegate in that case; this bridges to the enclosing
// UINavigationController and forces the delegate to allow the gesture.
//
// Usage: `.enableSwipeBack()` on any view that uses a custom back button.

extension View {
    func enableSwipeBack() -> some View {
        background(SwipeBackGestureEnabler())
    }

}

private struct SwipeBackGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SwipeBackController { SwipeBackController() }
    func updateUIViewController(_ uiViewController: SwipeBackController, context: Context) {}
}

private final class SwipeBackController: UIViewController, UIGestureRecognizerDelegate {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.delegate = self
        nav.interactivePopGestureRecognizer?.isEnabled = true
    }

    // Allow the gesture even when the default back button is hidden.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }
}


extension UIApplication {
    var isKeyboardVisible: Bool {
        findFirstResponder() != nil
    }

    private func findFirstResponder() -> UIResponder? {
        for scene in connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let fr = window.firstResponderInHierarchy() { return fr }
            }
        }
        return nil
    }
}

private extension UIView {
    func firstResponderInHierarchy() -> UIResponder? {
        if isFirstResponder { return self }
        for sub in subviews {
            if let fr = sub.firstResponderInHierarchy() { return fr }
        }
        return nil
    }
}

import SwiftUI

// Horizontal shake driven by an animatable counter. Increment the trigger
// value to fire a single shake pass; SwiftUI interpolates `animatableData`
// from the previous value to the new one, producing the oscillation.
//
// The wave is sculpted inside `effectValue` rather than through the outer
// `.animation(...)` curve — that way the sine stays temporally even (driven
// by a linear interpolation) while the *amplitude* tapers over the pass.
// The exponential decay envelope gives the shake a natural "hit and ring
// out" feel instead of the flat, mechanical bounce of a raw sine.
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 10
    // Number of half-oscillations per unit of animatableData. 3 ⇒
    // right → left → right → center, which reads as a crisp jiggle.
    var shakesPerUnit: CGFloat = 3
    // Decay exponent for the amplitude envelope. Higher values taper
    // faster; 1.3 keeps the first peak near full amplitude and fades the
    // trailing ones to ~10% of the initial hit.
    var decay: CGFloat = 1.3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Position within the current shake pass (0 → 1). `animatableData`
        // is monotonically increasing across successive triggers, so the
        // fractional part gives us a clean per-pass phase.
        let phase = animatableData - floor(animatableData)
        let envelope = pow(1 - phase, decay)
        let wave = sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(
            translationX: amount * envelope * wave,
            y: 0
        ))
    }
}

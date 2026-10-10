import SwiftUI

enum PlatformCompatibility {
    /// Exercise the iOS 17 navigation path on a newer simulator; never persists.
    static var forceLegacyUI: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "qaLegacyUI")
        #else
        false
        #endif
    }
}

/// Describe surfaces without storing an iOS 26-only type on older systems.
struct AdaptiveGlass {
    var tintColor: Color?
    var isInteractive = false
    static let regular = AdaptiveGlass()
    func tint(_ color: Color) -> Self { var copy = self; copy.tintColor = color; return copy }
    func interactive() -> Self { var copy = self; copy.isInteractive = true; return copy }

    @available(iOS 26.0, macOS 26.0, tvOS 26.0, *)
    var native: Glass {
        var value = Glass.regular
        if let tintColor { value = value.tint(tintColor) }
        return value.interactive(isInteractive)
    }
}

extension View {
    @ViewBuilder func adaptiveGlassEffect<S: Shape>(_ effect: AdaptiveGlass = .regular, in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *), !PlatformCompatibility.forceLegacyUI {
            glassEffect(effect.native, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.fill(effect.tintColor ?? .clear).allowsHitTesting(false) }
                .overlay { shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false) }
        }
    }

    @ViewBuilder func adaptiveSearchHeader<Header: View>(@ViewBuilder content: () -> Header) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: content)
        }
    }

    @ViewBuilder func adaptiveTabMinimization() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
        #else
        self
        #endif
    }
}

struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

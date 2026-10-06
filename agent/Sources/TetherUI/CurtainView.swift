import SwiftUI

/// What people in the room see while curtain mode is on.
public struct CurtainView: View {
    public init() {}

    public var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(nsImage: MenuBarIcon.image(.connected))
                    .renderingMode(.template)
                    .resizable().interpolation(.high)
                    .frame(width: 60, height: 48)
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("This Mac is being used remotely")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text("Press ⌃⌥⌘ Return to show the screen.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .multilineTextAlignment(.center)
            .padding(40)
        }
    }
}

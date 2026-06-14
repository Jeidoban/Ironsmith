import SwiftUI

struct IronsmithAppleSignInButton: View {
    let isSigningIn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .accessibilityHidden(true)
                Text("Sign in with Apple")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 280, height: 42)
            .background(.black, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
        .padding(.vertical, 4)
    }
}

#Preview("Apple Sign In Button") {
    VStack(spacing: 18) {
        IronsmithAppleSignInButton(isSigningIn: false, action: {})
        IronsmithAppleSignInButton(isSigningIn: true, action: {})
    }
    .padding()
}

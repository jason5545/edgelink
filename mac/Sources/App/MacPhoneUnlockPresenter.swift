import SwiftUI

enum PhoneUnlockPhase: Equatable {
    case verifyingTouchID
    case connecting
    case unlocking
    case succeeded
    case failed(String)
}

struct PhoneUnlockPhaseView: View {
    let phase: PhoneUnlockPhase
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            hero
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            if case .failed = phase {
                HStack(spacing: 12) {
                    Button(String(localized: "重試")) {
                        onRetry?()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "關閉")) {
                        onDismiss?()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            Spacer(minLength: 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch phase {
        case .verifyingTouchID:
            return String(localized: "驗證 \(BiometricAuthManager.shared.biometricLabel)")
        case .connecting:
            return String(localized: "連接手機…")
        case .unlocking:
            return String(localized: "解鎖手機…")
        case .succeeded:
            return String(localized: "手機已解鎖")
        case .failed:
            return String(localized: "解鎖失敗")
        }
    }

    private var subtitle: String {
        switch phase {
        case .verifyingTouchID:
            return String(localized: "在 Mac 上完成驗證後，將喚醒並解鎖手機")
        case .connecting:
            return String(localized: "正在建立安全通道")
        case .unlocking:
            return String(localized: "等待手機回應")
        case .succeeded:
            return String(localized: "繼續啟動螢幕共享")
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var hero: some View {
        switch phase {
        case .verifyingTouchID:
            TouchIDHero()
        case .connecting, .unlocking:
            RadarHero(unlocking: phase == .unlocking)
        case .succeeded:
            SuccessHero()
        case .failed:
            FailureHero()
        }
    }
}

private struct TouchIDHero: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 120, height: 120)
                .scaleEffect(pulsing ? 1.12 : 0.94)
            Circle()
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.5)
                .frame(width: 120, height: 120)
                .scaleEffect(pulsing ? 1.05 : 0.9)
            Image(systemName: "touchid")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(pulsing ? 1.04 : 1.0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

private struct RadarHero: View {
    let unlocking: Bool
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.accentColor.opacity(animating ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 130, height: 130)
                    .scaleEffect(animating ? 1.25 : 0.45)
                    .animation(
                        .easeOut(duration: 2.0)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.65),
                        value: animating
                    )
            }
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 88, height: 88)
                Image(systemName: "iphone")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: unlocking ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: 24, y: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 150, height: 150)
        .onAppear { animating = true }
    }
}

private struct SuccessHero: View {
    @State private var popped = false
    @State private var ringProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 132, height: 132)
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color.green)
                .frame(width: 96, height: 96)
                .scaleEffect(popped ? 1 : 0.2)
            Image(systemName: "lock.open.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .scaleEffect(popped ? 1 : 0.3)
        }
        .frame(width: 150, height: 150)
        .onAppear {
            withAnimation(.spring(duration: 0.45, bounce: 0.45)) {
                popped = true
            }
            withAnimation(.easeOut(duration: 0.7)) {
                ringProgress = 1
            }
        }
    }
}

private struct FailureHero: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.orange.opacity(0.14))
                .frame(width: 110, height: 110)
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.orange)
        }
        .frame(width: 150, height: 150)
    }
}

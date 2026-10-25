import SwiftUI

// the banner at the bottom of the about page: a shine sweeps across the wordmark now and then,
// and a strip of hazard tape scrolls along the bottom
struct AboutHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                wordmark
                Spacer(minLength: Space.m)
                HStack(spacing: Space.s) {
                    Text(Updater.currentVersion == "dev" ? "dev" : "v\(Updater.currentVersion)")
                        .font(.displayMedium(12))
                        .foregroundStyle(Color.zzzInk)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.zzzYellow, in: ChamferShape(cut: 6, leading: false))
                        .textSelection(.enabled)
                    Link(destination: Updater.repo) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 10, weight: .bold))
                            Text("GITHUB").tracking(1)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.displayMedium(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.white.opacity(0.1), in: ChamferShape(cut: 6, leading: false))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help(Updater.repo.absoluteString)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.l)

            HazardTape(paused: reduceMotion)
        }
        .background {
            ZStack {
                Color.zzzPanel
                Stripes(spacing: 18).fill(.white.opacity(0.025))
            }
        }
        .clipShape(ChamferShape(cut: 14, leading: false))
        .overlay(ChamferShape(cut: 14, leading: false).stroke(.white.opacity(0.08)))
    }

    private var wordmark: some View {
        let title = Text("ASAHIRO")
            .font(.display(38))
            .foregroundStyle(.white)
            .fixedSize()

        return title.overlay {
            TimelineView(.animation(paused: reduceMotion)) { ctx in
                GeometryReader { g in
                    // one sweep every five seconds, idle in between
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5)
                    let p = min(t / 1.1, 1)
                    LinearGradient(colors: [.clear, Color.zzzYellow, .white, Color.zzzYellow, .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 50)
                        .rotationEffect(.degrees(18))
                        .offset(x: -70 + p * (g.size.width + 140))
                        .opacity(reduceMotion ? 0 : 1)
                }
            }
            .mask(title)
            .allowsHitTesting(false)
        }
    }
}

// a thin strip of yellow and black caution stripes that crawls sideways
private struct HazardTape: View {
    let paused: Bool

    var body: some View {
        TimelineView(.animation(paused: paused)) { ctx in
            Stripes(spacing: 14, phase: paused ? 0 : CGFloat(ctx.date.timeIntervalSinceReferenceDate * 16))
                .fill(Color.zzzInk)
                .background(Color.zzzYellow)
        }
        .frame(height: 8)
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        SettingsGroup(header: "Updates") {
            SettingsRow(title: title, subtitle: subtitle) {
                switch updater.state {
                case .checking, .downloading:
                    ProgressView().controlSize(.small)
                case .ready:
                    Button("Relaunch") { updater.relaunch() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.zzzYellow)
                        .foregroundStyle(Color.zzzInk)
                case .failed:
                    Button("Try Again") { Task { await updater.check() } }.controlSize(.small)
                default:
                    Button("Check Now") { Task { await updater.check() } }.controlSize(.small)
                }
            }
            SettingsToggle(title: "Update automatically", subtitle: "Downloads new versions in the background and installs them when you quit.",
                           isOn: $updater.automatic)
        }
    }

    private var title: String {
        switch updater.state {
        case .idle: "Asahiro \(Updater.currentVersion)"
        case .checking: "Checking for updates…"
        case .upToDate: "Asahiro is up to date"
        case .downloading(let v): "Downloading Asahiro \(v)…"
        case .ready(let v): "Asahiro \(v) is ready"
        case .failed: "Couldn't update"
        }
    }

    private var subtitle: String? {
        switch updater.state {
        case .ready: "Installs when you quit, or relaunch now."
        case .failed(let message): message
        default: nil
        }
    }
}

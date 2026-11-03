import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The "Connect Phone" window: a QR code for Glimpse for Android, and the list of paired phones.
@MainActor
final class PairingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PairingWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Connect Phone"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PairingView(service: .shared))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        PeerService.shared.beginPairing()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        PeerService.shared.endPairing()
    }
}

private struct PairingView: View {
    @ObservedObject var service: PeerService

    var body: some View {
        VStack(spacing: 20) {
            if let device = service.justPaired {
                paired(device)
            } else {
                instructions
                code
            }
            if !service.devices.isEmpty {
                Divider()
                devices
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 420)
        .frame(minHeight: 520, alignment: .top)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect an Android phone")
                .font(.title2.weight(.semibold))
            Text("Browse the phone's photos here, and this Mac's shared folders on the phone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Install Glimpse for Android on the phone.")
                Text("2. Open it and tap **Scan code**.")
                Text("3. Scan this code. Both devices must use the same Wi-Fi.")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var code: some View {
        if let problem = service.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(height: 220)
        } else if let offer = service.offer {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(offer.expires.timeIntervalSince(context.date).rounded(.up))
                VStack(spacing: 10) {
                    QRCodeImage(text: offer.url.absoluteString)
                        .frame(width: 220, height: 220)
                        .opacity(remaining > 0 ? 1 : 0.15)
                        .accessibilityLabel("Pairing code for Glimpse for Android")
                    if remaining > 0 {
                        Text("The code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Button("Make a New Code") { service.makeOffer() }
                    }
                }
            }
        } else {
            ProgressView("Starting…")
                .frame(height: 220)
        }
    }

    private func paired(_ device: PairedDevice) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Connected to \(device.name)")
                .font(.title2.weight(.semibold))
            Text("The phone reconnects automatically when both devices use the same Wi-Fi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Pair Another Phone") { service.beginPairing() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired phones")
                .font(.headline)
            ForEach(service.devices) { device in
                HStack {
                    Image(systemName: "iphone")  // No Android glyph in SF Symbols.
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(device.name)
                        if let seen = device.lastSeen {
                            Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Unpair") { service.unpair(device) }
                        .accessibilityLabel("Unpair \(device.name)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sharp QR code: black modules on white, so every phone camera reads it in light and dark mode.
private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

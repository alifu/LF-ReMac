#if DEBUG
import Foundation
import RemoteCore
import SwiftUI

/// Debug-only dummy data for README screenshots (`-screenshots` launch argument). Nothing here touches the
/// Keychain or the network, and it does not exist in Release builds.
enum ScreenshotMode {
    static let isOn = CommandLine.arguments.contains("-screenshots")

    static let hostName = "Mac mini"

    /// Credentials backed by memory, pre-filled with two made-up paired Macs.
    static func credentials() -> PhoneCredentials {
        let credentials = PhoneCredentials(keyStore: InMemoryKeyStore(), deviceName: "Alex's iPhone")
        for host in dummyHosts {
            try? credentials.hostStore.add(host)
        }
        return credentials
    }

    private static var dummyHosts: [PairedHost] {
        [
            host("Mac mini", seed: 0x11, address: "192.168.1.20", wake: ["a4:83:e7:12:34:56"]),
            host("MacBook Pro", seed: 0x42, address: "192.168.1.34", wake: []),
        ]
    }

    private static func host(_ name: String, seed: UInt8, address: String, wake: [String]) -> PairedHost {
        let fingerprint = try! DeviceFingerprint(bytes: Data((0..<32).map { seed &+ UInt8($0) &* 7 }))
        return PairedHost(
            name: name, fingerprint: fingerprint, pairedAt: Date(timeIntervalSince1970: 1_760_000_000),
            lastKnownHost: address, lastKnownPort: 51820, wakeMACs: wake)
    }

    static var demoDisplays: HostDisplays {
        HostDisplays(
            displays: [
                DisplayInfo(id: "6C7A8F32-1B64-4F0E-9D2A-3B5E7C9A1D10", name: "Studio Display", pixelWidth: 5120, pixelHeight: 2880, isMain: true),
                DisplayInfo(id: "0A9B8C7D-6E5F-4A3B-8C1D-2E4F6A8B0C12", name: "LG UltraFine", pixelWidth: 3840, pixelHeight: 2160, isMain: false),
            ],
            selectedID: "6C7A8F32-1B64-4F0E-9D2A-3B5E7C9A1D10")
    }
}

/// A made-up Mac desktop drawn in SwiftUI, shown instead of the live video in screenshot mode.
struct DemoDesktopView: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.28, blue: 0.62), Color(red: 0.55, green: 0.25, blue: 0.62), Color(red: 0.95, green: 0.55, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                menuBar
                Spacer(minLength: 0)
            }
            window.padding(.top, 70).padding(.horizontal, 90)
            VStack { Spacer(); dock.padding(.bottom, 10) }
        }
        .accessibilityHidden(true)
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo")
            Text("Xcode").bold()
            Text("File"); Text("Edit"); Text("View")
            Spacer()
            Image(systemName: "wifi"); Text("Fri 9:41")
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 24)
        .background(.black.opacity(0.25))
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Circle().fill(.yellow).frame(width: 10, height: 10)
                Circle().fill(.green).frame(width: 10, height: 10)
                Spacer()
                Text("Report.swift").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10).background(Color(white: 0.93))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(codeLines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        Text(line.0).foregroundStyle(Color(red: 0.7, green: 0.2, blue: 0.6))
                        Text(line.1).foregroundStyle(.primary)
                    }
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.99))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private let codeLines: [(String, String)] = [
        ("struct ", "WeeklyReport {"), ("    let ", "title: String"), ("    var ", "totals: [Double]"),
        ("", ""), ("    func ", "summary() -> String {"), ("        return ", "\"\\(title): \\(totals.count) days\""),
        ("    }", ""), ("}", ""),
    ]

    private var dock: some View {
        HStack(spacing: 10) {
            ForEach([Color.blue, .green, .orange, .pink, .purple, .teal], id: \.self) { color in
                RoundedRectangle(cornerRadius: 9).fill(color.gradient).frame(width: 34, height: 34)
            }
        }
        .padding(8).background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension StreamClient {
    /// Pretends to be connected to the dummy Mac, with plausible numbers, for screenshots.
    func applyDemoState() {
        demoConnect(hostName: ScreenshotMode.hostName, stats: StreamStats(framesPerSecond: 30, megabitsPerSecond: 5.8, roundTripMilliseconds: 12),
                    displays: ScreenshotMode.demoDisplays)
    }
}
#endif

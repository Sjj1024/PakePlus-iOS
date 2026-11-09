//
//  ContentView.swift
//  PakePlus
//
//  Created by Song on 2025/3/29.
//

import SwiftUI
import UIKit

struct ContentView: View {
    // read value from info
    let webUrl = Bundle.main.object(forInfoDictionaryKey: "WEBURL") as? String ?? ""
    let debug = Bundle.main.object(forInfoDictionaryKey: "DEBUG") as? Bool ?? false
    let fullScreen = Bundle.main.object(forInfoDictionaryKey: "FULLSCREEN") as? Bool ?? false
    let launchImage = Bundle.main.object(forInfoDictionaryKey: "LAUNCHIMAGE") as? Bool ?? false
    let screenOn = Bundle.main.object(forInfoDictionaryKey: "SCREENON") as? Bool ?? false

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var license = XbLicenseStore()
    @State private var isWebLoaded: Bool = false
    @State private var heartbeatTimer: Timer?

    // 安全解析 WEBURL，避免 Force Unwrap 崩溃（地址为空/非法时给出提示页而不是闪退）
    private var webURL: URL? {
        let trimmed = webUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        Group {
            if license.active {
                if let url = webURL {
                    webContent(url)
                } else {
                    invalidWebUrlView
                }
            } else {
                CardKeyView()
            }
        }
        .environmentObject(license)
        .statusBarHidden(fullScreen)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = screenOn
            license.refresh()
            startHeartbeat()
            Task { await license.revalidateIfNeeded() }
        }
        .onDisappear { heartbeatTimer?.invalidate(); heartbeatTimer = nil }
        .onChange(of: scenePhase) { phase in
            UIApplication.shared.isIdleTimerDisabled = screenOn && (phase == .active)
            if phase == .active {
                license.refresh()
                Task { await license.revalidateIfNeeded() }
            }
        }
    }

    @ViewBuilder
    private func webContent(_ url: URL) -> some View {
        ZStack {
            // webview
            WebView(
                webUrl: url,
                debug: debug,
                onLoadFinished: {
                    isWebLoaded = true
                }
            )
            .ignoresSafeArea(edges: [.all])
            .allowsHitTesting(isWebLoaded)

            // loading screen
            if !isWebLoaded && launchImage {
                Image("LaunchScreen")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }

    private var invalidWebUrlView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("网页地址未配置或无效")
                .font(.headline)
            Text("请在 Info.plist 的 WEBURL 中填写要打开的网站地址")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.98, green: 0.98, blue: 0.99))
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // 定时巡检：本地到期/换机立即锁定，并按离线宽限期静默重验。
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                license.refresh()
                await license.revalidateIfNeeded()
            }
        }
    }
}

// #Preview {
//     ContentView()
// }

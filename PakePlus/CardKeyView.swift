import SwiftUI
import UIKit

@MainActor
final class XbLicenseStore: ObservableObject {
    @Published private(set) var active = XbLicense.active
    @Published private(set) var key = XbVault.load()?.cardKey ?? ""
    @Published private(set) var message = XbLicense.remainingText()

    func refresh() {
        active = XbLicense.active
        key = XbVault.load()?.cardKey ?? ""
        message = XbLicense.remainingText()
    }

    func activate(_ card: String) async -> (Bool, String) {
        let result = await XbService.verify(card)
        refresh()
        return result
    }

    func revalidateIfNeeded() async {
        guard XbLicense.needsRevalidation else { refresh(); return }
        await XbService.heartbeat()
        refresh()
    }
}

struct CardKeyView: View {
    @EnvironmentObject private var license: XbLicenseStore
    @State private var cardKey = ""
    @State private var busy = false
    @State private var status = ""
    @State private var isError = false
    @FocusState private var focused: Bool

    private let blue = Color(red: 0.0, green: 0.478, blue: 1.0)
    private let cyan = Color(red: 0.0, green: 0.667, blue: 1.0)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.957, green: 0.965, blue: 0.984).ignoresSafeArea()
                ScrollView {
                    VStack {
                        Spacer(minLength: 20)
                        card
                            .frame(maxWidth: 380)
                            .shadow(color: .black.opacity(0.10), radius: 22, x: 0, y: 8)
                        Spacer(minLength: 20)
                    }
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear { if cardKey.isEmpty { cardKey = license.key } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [blue, cyan], startPoint: .leading, endPoint: .trailing))
                    Image(systemName: "key.horizontal.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                Text("PakePlus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(red: 0.20, green: 0.20, blue: 0.20))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Rectangle().fill(Color(red: 0.94, green: 0.94, blue: 0.94)).frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color(red: 0.89, green: 0.95, blue: 1.0)).frame(width: 22, height: 22)
                        Image(systemName: "key.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(blue)
                    }
                    Text("授权密钥").font(.system(size: 15)).foregroundStyle(Color(red: 0.33, green: 0.33, blue: 0.33))
                }
                .padding(.bottom, 10)

                TextField("请输入卡密", text: $cardKey)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { Task { await activate() } }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.86, green: 0.87, blue: 0.90), lineWidth: 1))

                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("端到端加密传输").font(.system(size: 13))
                }
                .foregroundStyle(Color(red: 0.60, green: 0.60, blue: 0.60))
                .padding(.top, 6)

                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(isError ? Color.red : Color.green)
                        .padding(.top, 8)
                }

                Button { Task { await activate() } } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? "验证中…" : "立即验证 →")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(LinearGradient(colors: [blue, cyan], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(busy || cardKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity((busy || cardKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.68 : 1)
                .padding(.top, 18)
            }
            .padding(.horizontal, 20)
            .padding(.top, 25)
            .padding(.bottom, 30)

            Rectangle().fill(Color(red: 0.95, green: 0.95, blue: 0.95)).frame(height: 1)

            HStack(spacing: 30) {
                footerLink("领取卡密", icon: "cart.fill") { openQQ("1225838378") }
                footerLink("技术支持", icon: "questionmark.circle.fill") { openQQ("1437562514") }
                footerLink("VIP购买", icon: "crown.fill") { openURL("https://pzs.ssby.top") }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 15)
            .padding(.bottom, 5)

            Text("PakePlus © 2026")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.67, green: 0.67, blue: 0.67))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 15)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func footerLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 14))
            }
            .foregroundStyle(blue)
        }
        .buttonStyle(.plain)
    }

    private func openQQ(_ number: String) {
        if let url = URL(string: "mqqwpa://im/chat?chat_type=wpa&uin=\(number)&version=1&src_type=web"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            openURL("https://wpa.qq.com/msgrd?v=3&uin=\(number)&site=qq&menu=yes")
        }
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        UIApplication.shared.open(url)
    }

    private func activate() async {
        let trimmed = cardKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { status = "请输入卡密"; isError = true; return }
        focused = false
        busy = true
        status = ""
        let result = await license.activate(trimmed)
        busy = false
        status = result.0 ? "验证成功 · \(XbLicense.remainingText())" : result.1
        isError = !result.0
        if result.0 { cardKey = trimmed }
    }
}

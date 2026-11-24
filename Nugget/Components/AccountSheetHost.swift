//
//  AccountSheetHost.swift
//  Nugget
//
//  
//

import SwiftUI

/// Shared account/session state for the app. Used by the tab headers
/// (avatar) and the account section at the top of Settings.
@MainActor
@Observable
final class AccountSheetState {
    static let shared = AccountSheetState()

    // Primary Account (Library & Sync)
    var accountName = "Guest"
    var accountImageUrl: String?
    var isLoginSheetPresented = false
    let loginModel = LoginViewModel(sessionKind: .primary)

    // Premium Stream Account (256kbps Audio)
    var premiumAccountName = "Guest"
    var premiumAccountImageUrl: String?
    var isPremiumLoginSheetPresented = false
    let premiumLoginModel = LoginViewModel(sessionKind: .premium)

    private let cookieStore = CookieStore.primary
    private let premiumStore = CookieStore.premium
    private var hasAttemptedTokenRefresh = false
    private var isFetchingAccountInfo = false
    private var isFetchingPremiumInfo = false

    var isLoggedIn: Bool { loginModel.isLoggedIn }
    var isPremiumLoggedIn: Bool { premiumLoginModel.isLoggedIn }

    private init() {}

    func restoreSession() async {
        hasAttemptedTokenRefresh = false
        await loginModel.restoreSessionIfPresent()
        await premiumLoginModel.restoreSessionIfPresent()
        await InnerTubeClient.updateStreamAuth()
    }

    func fetchAccountInfo() async {
        guard loginModel.isLoggedIn, !isFetchingAccountInfo else { return }
        isFetchingAccountInfo = true
        defer { isFetchingAccountInfo = false }
        for attempt in 1...3 {
            let info: AccountInfo
            do {
                info = try await InnerTubeClient.nuggetShared.accountInfo()
            } catch {
                Log.loginViewModel.error("fetchAccountInfo: attempt \(attempt) failed: \(error)")
                return
            }
            let knownName = !info.name.isEmpty && info.name != "Guest"
            guard knownName else {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                Log.loginViewModel.notice("fetchAccountInfo: giving up — menu stayed guest-shaped")
                if !hasAttemptedTokenRefresh {
                    hasAttemptedTokenRefresh = true
                    // Release the in-flight guard so refreshRotatedSession's
                    // own accountInfo fetch can run after the cookie reissue.
                    isFetchingAccountInfo = false
                    await refreshRotatedSession()
                }
                return
            }
            accountName = info.name
            if let url = info.thumbnailUrl {
                accountImageUrl = url
                return
            }
            if accountImageUrl != nil || attempt == 3 {
                Log.loginViewModel.debug("fetchAccountInfo: name OK, no photo in response")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func fetchPremiumAccountInfo() async {
        guard premiumLoginModel.isLoggedIn, !isFetchingPremiumInfo else { return }
        isFetchingPremiumInfo = true
        defer { isFetchingPremiumInfo = false }
        let client = InnerTubeClient(config: .music)
        await client.loadState(from: premiumStore)
        for attempt in 1...3 {
            let info: AccountInfo
            do {
                info = try await client.accountInfo()
            } catch {
                Log.loginViewModel.error("fetchPremiumAccountInfo: attempt \(attempt) failed: \(error)")
                return
            }
            let knownName = !info.name.isEmpty && info.name != "Guest"
            guard knownName else {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                return
            }
            premiumAccountName = info.name
            if let url = info.thumbnailUrl {
                premiumAccountImageUrl = url
                return
            }
            if premiumAccountImageUrl != nil || attempt == 3 {
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func handleLoginChange(_ loggedIn: Bool) {
        if loggedIn {
            isLoginSheetPresented = false
            hasAttemptedTokenRefresh = false
            Task {
                await InnerTubeClient.updateStreamAuth()
                await fetchAccountInfo()
            }
        }
    }

    func handlePremiumLoginChange(_ loggedIn: Bool) {
        if loggedIn {
            isPremiumLoginSheetPresented = false
            Task {
                await InnerTubeClient.updateStreamAuth()
                await fetchPremiumAccountInfo()
            }
        }
    }

    func signOut() {
        loginModel.logout()
        WebLoginController.clearWebsiteData(for: .primary)
        accountName = "Guest"
        accountImageUrl = nil
        hasAttemptedTokenRefresh = false
        Task {
            await InnerTubeClient.updateStreamAuth()
        }
    }

    func signOutOfPremium() {
        premiumLoginModel.logout()
        WebLoginController.clearWebsiteData(for: .premium)
        premiumAccountName = "Guest"
        premiumAccountImageUrl = nil
        Task {
            await InnerTubeClient.updateStreamAuth()
        }
    }

    func refreshRotatedSession() async {
        let base = await cookieStore.cookies()
        let sapisid = await cookieStore.sapisid()
        guard sapisid != nil else { return }
        let refreshed = await SessionTokenRefresher.shared.refreshRotatedTokens(baseCookies: base)
        guard !refreshed.isEmpty else { return }
        await cookieStore.save(
            cookies: refreshed,
            sapisid: sapisid,
            visitorData: refreshed["visitor_data"],
            dataSyncId: await cookieStore.dataSyncId()
        )
        Log.loginViewModel.notice("refreshRotatedSession: reissued cookies persisted — reloading state")
        await InnerTubeClient.nuggetShared.loadState(from: cookieStore)
        await InnerTubeClient.updateStreamAuth()
        await fetchAccountInfo()
    }
}

struct LoginSheetHost: ViewModifier {
    @Bindable var state: AccountSheetState
    @ObservedObject private var loginModel = AccountSheetState.shared.loginModel
    @ObservedObject private var premiumLoginModel = AccountSheetState.shared.premiumLoginModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $state.isLoginSheetPresented) {
                NavigationStack {
                    LoginWebView(model: state.loginModel)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { state.isLoginSheetPresented = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $state.isPremiumLoginSheetPresented) {
                NavigationStack {
                    LoginWebView(model: state.premiumLoginModel)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { state.isPremiumLoginSheetPresented = false }
                            }
                        }
                }
            }
            .onChange(of: loginModel.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    state.isLoginSheetPresented = false
                    Task {
                        await InnerTubeClient.updateStreamAuth()
                        await state.fetchAccountInfo()
                    }
                }
            }
            .onChange(of: premiumLoginModel.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    state.isPremiumLoginSheetPresented = false
                    Task {
                        await InnerTubeClient.updateStreamAuth()
                        await state.fetchPremiumAccountInfo()
                    }
                }
            }
    }
}

extension View {
    func loginSheet(state: AccountSheetState) -> some View {
        modifier(LoginSheetHost(state: state))
    }
}

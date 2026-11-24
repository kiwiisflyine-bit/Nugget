//
//  LoginViewModel.swift
//  Nugget
//
//  
//

import Foundation
import Combine

// Drives sign-in and session verification, owns the CookieStore + InnerTube coordination
@MainActor
final class LoginViewModel: ObservableObject {
    @Published var cookies: [String: String] = [:]
    @Published var sapisid: String?
    @Published var visitorData: String?
    @Published var dataSyncId: String?
    @Published var isLoggedIn = false
    @Published var isPresented = false

    let sessionKind: SessionKind
    private let authService = AuthService.shared
    private var loadTask: Task<Void, Never>?

    init(sessionKind: SessionKind = .primary) {
        self.sessionKind = sessionKind
    }

    private func cookieStore() async -> CookieStore {
        await authService.store(for: sessionKind)
    }

    func handleLogin(cookies: [String: String], sapisid: String?, visitorData: String?, dataSyncId: String? = nil) {
        self.cookies = cookies
        self.sapisid = sapisid
        self.visitorData = visitorData
        self.dataSyncId = dataSyncId

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.authService.importSession(
                    from: self.cookieString(from: cookies),
                    dataSyncId: dataSyncId,
                    for: self.sessionKind
                )
                self.isLoggedIn = true
                self.isPresented = false
            } catch {
                Log.loginViewModel.error("importSession failed for \(self.sessionKind.rawValue): \(error)")
            }
        }
    }

    func logout() {
        Task { [weak self] in
            guard let self else { return }
            await self.authService.logout(sessionType: self.sessionKind)
            self.cookies = [:]
            self.sapisid = nil
            self.visitorData = nil
            self.dataSyncId = nil
            self.isLoggedIn = false
        }
    }

    func restoreSessionIfPresent() async {
        loadTask?.cancel()
        let store = await cookieStore()
        let task = Task { [weak self] in
            guard let self else { return }
            let loggedIn = await store.isLoggedIn()
            guard loggedIn else { return }

            self.cookies = await store.cookies()
            self.sapisid = await store.sapisid()
            self.visitorData = await store.visitorData()
            self.dataSyncId = await store.dataSyncId()
            self.isLoggedIn = true
        }
        loadTask = task
        await task.value
    }

    private func cookieString(from dict: [String: String]) -> String {
        dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}

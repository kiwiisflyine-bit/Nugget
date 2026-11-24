//
// AuthService.swift
//  Nugget
//
// 
//

import Foundation

// Errors specific to session import and login verification
enum AuthError: LocalizedError {
    case verificationFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let error):
            return "Failed to verify login: \(error?.localizedDescription ?? "unknown")"
        }
    }
}

// Acts as the session and auth entry point for the rest of the app
actor AuthService {
    static let shared = AuthService()

    private let innerTube = InnerTubeClient.nuggetShared
    private let cookieStore = CookieStore.primary
    private let premiumCookieStore = CookieStore.premium

    func store(for sessionType: SessionKind = .primary) -> CookieStore {
        switch sessionType {
        case .primary: return cookieStore
        case .premium: return premiumCookieStore
        }
    }

    // Imports a raw cookie string (e.g. from browser export) and persists it
    func importSession(
        from cookieString: String,
        dataSyncId: String? = nil,
        for sessionType: SessionKind = .primary
    ) async throws {
        let auth = try SessionImporter.importSession(from: cookieString, dataSyncId: dataSyncId)
        let targetStore = store(for: sessionType)
        await targetStore.save(
            cookies: auth.cookies,
            sapisid: auth.sapisid,
            visitorData: auth.visitorData,
            dataSyncId: auth.dataSyncId
        )

        switch sessionType {
        case .primary:
            await innerTube.loadState(from: targetStore)
            await InnerTubeClient.updateStreamAuth()
        case .premium:
            await InnerTubeClient.updateStreamAuth()
        }
    }

    // Probes `account/account_menu` to confirm the current session is still valid
    func verifyLogin(for sessionType: SessionKind = .primary) async throws -> Bool {
        do {
            switch sessionType {
            case .primary:
                return try await innerTube.verifySession()
            case .premium:
                let client = InnerTubeClient(config: .music)
                await client.loadState(from: premiumCookieStore)
                return try await client.verifySession()
            }
        } catch {
            throw AuthError.verificationFailed(error)
        }
    }

    // Re-hydrates InnerTube from whatever is currently saved in the CookieStores
    func loadPersistedSession() async {
        await innerTube.loadState(from: cookieStore)
        await InnerTubeClient.updateStreamAuth()
    }

    // Wipes cookies and SAPISID from the chosen CookieStore
    func logout(sessionType: SessionKind = .primary) async {
        let targetStore = store(for: sessionType)
        await targetStore.clear()
        switch sessionType {
        case .primary:
            await innerTube.loadState(from: targetStore)
            await InnerTubeClient.updateStreamAuth()
        case .premium:
            await InnerTubeClient.updateStreamAuth()
        }
    }
}

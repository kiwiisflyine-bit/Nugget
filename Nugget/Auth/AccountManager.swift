//
//  AccountManager.swift
//  Nugget
//
//  Created by Antigravity on 2026-11-13.
//

import Foundation

/// Manages two independent authentication sessions: primary (library & sync) and premium (audio streaming).
final class AccountManager {
    static let shared = AccountManager()

    /// Cookie store for primary account (library, search, liked songs, etc.)
    let primaryCookieStore: CookieStore
    /// Cookie store for premium streaming account (used for /player requests when 256AAC is selected).
    let premiumCookieStore: CookieStore

    private init() {
        self.primaryCookieStore = CookieStore()
        self.premiumCookieStore = CookieStore()
    }

    /// Returns the appropriate cookie store for a streaming request.
    /// - Parameter preferPremium: If true and a premium account is logged‑in, returns the premium store; otherwise primary.
    func cookieStore(forStreaming preferPremium: Bool) async -> CookieStore {
        if preferPremium {
            let loggedIn = await premiumCookieStore.isLoggedIn()
            return loggedIn ? premiumCookieStore : primaryCookieStore
        }
        return primaryCookieStore
    }
}

//
//  CookieStore.swift
//  Nugget
//
//  
//

import Foundation

// High-level session wrapper — delegates persistence to KeychainStorage
actor CookieStore {
  let sessionKey: String
  private let keychain: KeychainStorage

  static let primary = CookieStore(sessionKey: KeychainStorage.primarySessionKey)
  static let premium = CookieStore(sessionKey: KeychainStorage.premiumSessionKey)

  init(sessionKey: String = KeychainStorage.primarySessionKey, keychain: KeychainStorage = KeychainStorage()) {
    self.sessionKey = sessionKey
    self.keychain = keychain
  }

    func cookies() async -> [String: String] {
        guard let state = await state(), let cookie = state.cookie, !cookie.isEmpty else { return [:] }
        return parseCookieString(cookie)
    }

    func sapisid() async -> String? {
        await state()?.sapisidHash
    }

    func visitorData() async -> String? {
        await state()?.visitorData
    }

    func dataSyncId() async -> String? {
        await state()?.dataSyncId
    }

    func isLoggedIn() async -> Bool {
        await state()?.isLoggedIn ?? false
    }

    private func state() async -> SessionState? {
        try? await keychain.loadSessionState(for: sessionKey)
    }

    func save(cookies: [String: String], sapisid: String?, visitorData: String?, dataSyncId: String? = nil) {
        let cookieString = cookies
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        let state = SessionState(
            cookie: cookieString.isEmpty ? nil : cookieString,
            sapisidHash: sapisid,
            visitorData: visitorData,
            dataSyncId: dataSyncId,
            locale: .default
        )
        try? keychain.save(state, for: sessionKey)
    }

    func clear() {
        try? keychain.clear(for: sessionKey)
    }

  private func parseCookieString(_ cookieString: String) -> [String: String] {
    CookieParser.parse(cookieString)
  }
}

public enum SessionKind: String, Sendable, CaseIterable {
  case primary = "PrimarySyncSession"
  case premium = "PremiumStreamSession"
}

typealias PrimarySyncSession = CookieStore
typealias PremiumStreamSession = CookieStore

//
//  SettingsView.swift
//  Nugget
//
//  Created on 16/07/2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Bindable private var accountState = AccountSheetState.shared

    var body: some View {
        List {
            accountSection

            Section {
                SettingsNavigationRow("Appearance", icon: "paintpalette") {
                    AppearanceSettingsView()
                }
            } header: {
                Text("Appearance")
            }

            Section {
                SettingsNavigationRow("Player", icon: "play.circle") {
                    PlayerSettingsView()
                }
                SettingsNavigationRow("Downloads", icon: "arrow.down.circle") {
                    DownloadSettingsView()
                }
            } header: {
                Text("Playback & Offline")
            }

            Section {
                SettingsNavigationRow("Content", icon: "globe") {
                    ContentSettingsView()
                }
                SettingsNavigationRow("Lyrics", icon: "text.quote") {
                    LyricsSettingsView()
                }
            } header: {
                Text("Content & Lyrics")
            }

            Section {
                SettingsNavigationRow("Integrations", icon: "puzzlepiece.extension") {
                    IntegrationsSettingsView()
                }
            } header: {
                Text("Integrations")
            }

            Section {
                SettingsNavigationRow("About", icon: "info.circle") {
                    AboutSettingsView()
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .loginSheet(state: accountState)
        .task {
            await accountState.restoreSession()
            await accountState.fetchAccountInfo()
            await accountState.fetchPremiumAccountInfo()
        }
    }

    private var accountSection: some View {
        Section {
            // Primary Account (Library & Sync)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AccountButtonView(
                        isLoggedIn: accountState.isLoggedIn,
                        accountImageUrl: accountState.accountImageUrl,
                        onTap: {}
                    )
                    .scaleEffect(1.3)
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Primary Account")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if accountState.isLoggedIn {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }
                        Text(accountState.isLoggedIn ? accountState.accountName : "Guest")
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if accountState.isLoggedIn {
                        Button("Logout", action: accountState.signOut)
                            .buttonStyle(.bordered)
                            .tint(settings.accentColor)
                    } else {
                        Button("Login") { accountState.isLoginSheetPresented = true }
                            .buttonStyle(.borderedProminent)
                            .tint(settings.accentColor)
                    }
                }

                Text("Library, playlists, recommendations, and search.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            // Premium Stream Account (256kbps Audio)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AccountButtonView(
                        isLoggedIn: accountState.isPremiumLoggedIn,
                        accountImageUrl: accountState.premiumAccountImageUrl,
                        onTap: {}
                    )
                    .scaleEffect(1.3)
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Premium Stream Account")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if accountState.isPremiumLoggedIn {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else if accountState.isLoggedIn {
                                Image(systemName: "arrow.triangle.merge")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                            }
                        }
                        Text(accountState.isPremiumLoggedIn ? accountState.premiumAccountName : (accountState.isLoggedIn ? "Using Primary Account" : "Guest (Not logged in)"))
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if accountState.isPremiumLoggedIn {
                        Button("Logout", action: accountState.signOutOfPremium)
                            .buttonStyle(.bordered)
                            .tint(settings.accentColor)
                    } else {
                        Button("Login") { accountState.isPremiumLoginSheetPresented = true }
                            .buttonStyle(.borderedProminent)
                            .tint(settings.accentColor)
                    }
                }

                Text("High-quality audio streaming (256kbps AAC) and offline downloads.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } header: {
            Text("YouTube Accounts")
        }
    }
}

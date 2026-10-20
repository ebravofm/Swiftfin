//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

/// Shows the library whose name matches `name`, looked up in the user's views when the tab appears.
private struct NamedLibraryTabView: View {

    private struct LibraryNotFound: LocalizedError {

        let name: String

        var errorDescription: String? {
            "Library \"\(name)\" not found"
        }
    }

    @Injected(\.currentUserSession)
    private var userSession

    let name: String

    @State
    private var library: BaseItemDto?
    @State
    private var error: Error?

    var body: some View {
        Group {
            if let library {
                PagingLibraryView(library: ItemLibrary(parent: library))
            } else if let error {
                ErrorView(error: error)
            } else {
                ProgressView()
            }
        }
        .task(id: name) {
            await loadLibrary()
        }
    }

    private func loadLibrary() async {
        guard let userSession else { return }

        do {
            let request = Paths.getUserViews(parameters: .init(userID: userSession.user.id))
            let response = try await userSession.client.send(request)

            guard let match = response.value.items?.first(where: {
                $0.name?.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                error = LibraryNotFound(name: name)
                return
            }

            library = match
        } catch {
            self.error = error
        }
    }
}

// TODO: selected icon
@MainActor
struct TabItem: Displayable, @MainActor Identifiable, @MainActor Hashable {

    let content: AnyView
    let displayTitle: String
    let id: String
    let systemImage: String

    init(
        id: String,
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> some View
    ) {
        self.content = AnyView(content())
        self.id = id
        self.displayTitle = title
        self.systemImage = systemImage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

extension TabItem {

    static var adminDashboard: TabItem {
        TabItem(
            id: "admin-dashboard",
            title: L10n.dashboard,
            systemImage: "server.rack"
        ) {
            #if os(iOS)
            AdminDashboardView()
            #else
            EmptyView()
            #endif
        }
    }

    static func contentGroup(
        provider: some ContentGroupProvider
    ) -> TabItem {
        TabItem(
            id: provider.id,
            title: provider.displayTitle,
            systemImage: "house.fill"
        ) {
            ContentGroupView(provider: provider)
        }
    }

    static func item(id: String, displayTitle: String) -> TabItem {
        let item = BaseItemDto(id: id, name: displayTitle)
        let provider = ItemContentGroupProvider(item: item)

        return TabItem(
            id: id,
            title: displayTitle,
            systemImage: item.systemImage
        ) {
            ItemView(provider: provider)
        }
    }

    static func library(
        title: String,
        systemName: String,
        filters: ItemFilterCollection
    ) -> TabItem {
        TabItem(
            id: "library-\(UUID().uuidString)",
            title: title,
            systemImage: systemName
        ) {
            PagingLibraryView(
                library: ItemLibrary(
                    parent: BaseItemDto(name: title),
                    staticFilters: filters
                )
            )
            .if(UIDevice.isTV) { view in
                view.toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    /// A tab for the server library named `libraryName`, resolved by name so it survives the library being recreated.
    static func namedLibrary(
        libraryName: String,
        title: String,
        systemName: String
    ) -> TabItem {
        TabItem(
            id: "named-library-\(libraryName)",
            title: title,
            systemImage: systemName
        ) {
            NamedLibraryTabView(name: libraryName)
                .if(UIDevice.isTV) { view in
                    view.toolbar(.hidden, for: .navigationBar)
                }
        }
    }

    static var media: TabItem {
        TabItem(
            id: "media",
            title: L10n.media,
            systemImage: "rectangle.stack.fill"
        ) {
            PagingLibraryView(library: UserViewLibrary())
                .if(UIDevice.isTV) { view in
                    view.toolbar(.hidden, for: .navigationBar)
                }
        }
    }

    static var liveTV: TabItem {
        TabItem(
            id: "live-tv",
            title: L10n.liveTV,
            systemImage: "play.tv"
        ) {
            NavigationRoute.liveTV.destination
        }
    }

    static var search: TabItem {
        TabItem(
            id: "search",
            title: L10n.search,
            systemImage: "magnifyingglass"
        ) {
            SearchView()
                .if(UIDevice.isTV) { view in
                    view.toolbar(.hidden, for: .navigationBar)
                }
        }
    }

    static var settings: TabItem {
        TabItem(
            id: "settings",
            title: L10n.settings,
            systemImage: "gearshape"
        ) {
            SettingsView()
        }
    }
}

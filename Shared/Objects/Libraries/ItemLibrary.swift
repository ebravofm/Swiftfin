//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

@MainActor
struct ItemLibrary: MediaLibrary, SearchablePagingLibrary, WithRandomElementLibrary {

    struct Environment: WithDefaultValue {

        var grouping: BaseItemDto.Grouping?
        var filters: ItemFilterCollection

        static let `default`: Self = .init(
            grouping: nil,
            filters: .default
        )
    }

    let environment: Environment?
    let filterViewModel: FilterViewModel
    @SharedBaseItem
    var parent: BaseItemDto

    init(
        parent: BaseItemDto,
        filters: ItemFilterCollection? = nil,
        staticFilters: ItemFilterCollection = .default
    ) {
        var filters = filters ?? .default

        if let id = parent.id, Defaults[.Customization.Library.rememberSort] {
            let storedFilters = StoredValues[.User.libraryFilters(parentID: id)]

            filters.sortBy = storedFilters.sortBy
            filters.sortOrder = storedFilters.sortOrder
        }

        self.environment = .init(
            grouping: parent.groupings?.defaultSelection,
            filters: staticFilters.union(filters)
        )
        self.filterViewModel = .init(
            parent: parent,
            currentFilters: filters,
            staticFilters: staticFilters
        )
        self.parent = parent
    }

    func makeMenuContent(environment: Binding<Environment>) -> AnyView {
        Group {
            if let groupings = parent.groupings, groupings.elements.isNotEmpty {
                Picker(
                    selection: environment.map(
                        getter: { $0.grouping },
                        setter: { .init(grouping: $0, filters: environment.wrappedValue.filters) }
                    )
                ) {
                    ForEach(groupings.elements) { grouping in
                        Text(grouping.displayTitle)
                            .tag(grouping as BaseItemDto.Grouping?)
                    }
                } label: {
                    Text(L10n.grouping)

                    if let grouping = environment.wrappedValue.grouping {
                        Text(grouping.displayTitle)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .eraseToAnyView()
    }

    func makeLibraryBody(
        viewModel: PagingLibraryViewModel<Self>,
        @ViewBuilder content: @escaping () -> some View
    ) -> AnyView {
        ItemLibraryBody(
            filterViewModel: filterViewModel,
            viewModel: viewModel,
            content: content
        )
        .eraseToAnyView()
    }

    func libraryStyleOptions(environment: Environment) -> LibraryStyleOptions {
        let itemTypes = environment.filters.itemTypes.isEmpty ?
            parent.supportedItemTypes(for: environment.grouping) :
            environment.filters.itemTypes

        return BaseItemKind.libraryStyleOptions(for: itemTypes)
    }

    func retrievePage(
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> [ItemPatch] {
        var parameters = attachPage(
            to: attachFilters(
                to: makeBaseItemParameters(environment: environment),
                using: environment.filters
            ),
            pageState: pageState
        )
        parameters.userID = pageState.userSession.user.id

        // Without an explicit sort the server returns a playlist in the order it was built.
        if parent.libraryType == .playlist {
            parameters.sortBy = nil
            parameters.sortOrder = nil
        }

        let request = Paths.getItems(parameters: parameters)
        let response = try await pageState.userSession.client.send(request)

        return try pageState.items(from: response)
    }

    func retrieveRandomElement(
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> ItemPatch? {
        var parameters = attachFilters(
            to: makeBaseItemParameters(environment: environment),
            using: environment.filters
        )
        parameters.limit = 1
        parameters.sortBy = [.random]
        parameters.userID = pageState.userSession.user.id

        let request = Paths.getItems(parameters: parameters)
        let response = try await pageState.userSession.client.send(request)

        return try pageState.items(from: response).first
    }

    func retrieveSearchPage(
        query: String,
        environment: Environment,
        pageState: LibraryPageState
    ) async throws -> [ItemPatch] {
        var parameters = attachPage(
            to: attachFilters(
                to: makeBaseItemParameters(environment: environment),
                using: environment.filters
            ),
            pageState: pageState
        )
        parameters.searchTerm = filterViewModel.staticFilters.query ?? query
        parameters.userID = pageState.userSession.user.id

        let request = Paths.getItems(parameters: parameters)
        let response = try await pageState.userSession.client.send(request)

        return try pageState.items(from: response)
    }

    private func makeBaseItemParameters(environment: Environment) -> Paths.GetItemsParameters {
        var parameters = Paths.GetItemsParameters()
        parameters.enableUserData = true
        parameters.fields = PosterSubtitleField.itemFields
        parameters.includeItemTypes = parent.supportedItemTypes(for: environment.grouping)
        parameters.isRecursive = parent.isRecursiveCollection(for: environment.grouping)
        parameters.sortBy = [.name]
        parameters.sortOrder = [.ascending]

        guard let parentID = parent.id else { return parameters }

        if parent.isFolderCollection {
            parameters.parentID = parentID
            // With explicit item types the server treats an omitted value as recursive,
            // which would list every clip next to its artist folder.
            parameters.isRecursive = parent.collectionType == .musicvideos ? false : nil
            return parameters
        }

        switch parent.libraryType {
        case .person:
            parameters.personIDs = [parentID]

        case .studio:
            parameters.studioIDs = [parentID]

        default:
            parameters.parentID = parentID
        }

        return parameters
    }

    func materialize(_ page: [ItemPatch], pageState: LibraryPageState) throws -> [ItemEntry] {
        try page.compactMap { patch in
            if let type = patch.value.collectionType, !CollectionType.supportedCases.contains(type) {
                return nil
            }
            guard let record = try pageState.userSession.items.merge(patch, token: pageState.itemRequest) else {
                return nil
            }

            return ItemEntry(item: record, occurrence: patch.value.playlistItemID)
        }
    }

    func includes(_ element: ItemEntry, environment: Environment) -> Bool {
        element.item.confirmedUserData?.matches(environment.filters.traits) != false
    }

    func shouldRefreshForUserDataChange(environment: Environment) -> Bool {
        environment.filters.traits.contains {
            switch $0 {
            case .isFavorite, .isPlayed, .isUnplayed, .isResumable, .likes, .dislikes, .isFavoriteOrLikes: true
            default: false
            }
        } || environment.filters.sortBy.contains {
            switch $0 {
            case .datePlayed, .playCount, .isUnplayed, .isPlayed, .isFavoriteOrLiked, .seriesDatePlayed: true
            default: false
            }
        }
    }

    private func attachFilters(
        to parameters: Paths.GetItemsParameters,
        using filters: ItemFilterCollection
    ) -> Paths.GetItemsParameters {
        var parameters = parameters
        parameters.audioLanguages = filters.audioLanguages.map(\.value)
        parameters.filters = filters.traits
        parameters.genres = filters.genres.map(\.value)
        parameters.officialRatings = filters.officialRatings.map(\.value)
        parameters.sortBy = filters.sortBy
        parameters.sortOrder = filters.sortOrder
        parameters.subtitleLanguages = filters.subtitleLanguages.map(\.value)
        parameters.tags = filters.tags.map(\.value)
        parameters.years = filters.years.compactMap { Int($0.value) }

        parameters.isMovie = filters.categories.contains(.movies) ? true : nil
        parameters.isSeries = filters.categories.contains(.series) ? true : nil
        parameters.isNews = filters.categories.contains(.news) ? true : nil
        parameters.isKids = filters.categories.contains(.kids) ? true : nil
        parameters.isSports = filters.categories.contains(.sports) ? true : nil

        if let query = filters.query {
            parameters.searchTerm = query
        }

        if filters.itemTypes.isNotEmpty {
            parameters.includeItemTypes = filters.itemTypes
        }

        if let letter = filters.letter.first {
            if letter.value == "#" {
                parameters.nameLessThan = "A"
            } else {
                parameters.nameStartsWith = letter.value
            }
        }

        return parameters
    }

    private func attachPage(
        to parameters: Paths.GetItemsParameters,
        pageState: LibraryPageState
    ) -> Paths.GetItemsParameters {
        var parameters = parameters
        parameters.limit = pageState.pageSize
        parameters.startIndex = pageState.pageOffset
        return parameters
    }
}

private struct ItemLibraryBody<Content: View>: View {

    @Default(.Customization.Library.enabledDrawerFilters)
    private var enabledDrawerFilters

    @Router
    private var router

    @ObservedObject
    private var viewModel: PagingLibraryViewModel<ItemLibrary>

    private let content: Content
    private let filterViewModel: FilterViewModel

    private var filterTypes: [ItemFilterType] {
        enabledDrawerFilters.filter { !filterViewModel.staticFilters.containsFilters(ofType: $0) }
    }

    init(
        filterViewModel: FilterViewModel,
        viewModel: PagingLibraryViewModel<ItemLibrary>,
        @ViewBuilder content: () -> Content
    ) {
        self.filterViewModel = filterViewModel
        self.viewModel = viewModel
        self.content = content()
    }

    var body: some View {
        content
            .onFirstAppear {
                Task {
                    await filterViewModel.getQueryFilters()
                }
            }
            .onChange(of: filterViewModel.currentFilters) {
                rememberSort(from: filterViewModel.currentFilters)
            }
            .onReceive(
                filterViewModel.$currentFilters
                    .map { filterViewModel.staticFilters.union($0) }
                    .removeDuplicates()
                    .debounce(for: 1, scheduler: RunLoop.main)
            ) { filters in
                guard viewModel.environment.filters != filters else { return }

                viewModel.environment.filters = filters
            }
            #if os(tvOS)
            .filterBar(
                viewModel: filterViewModel,
                types: filterTypes
            )
            #endif
            .letterPickerBar(filterViewModel: filterViewModel)
            #if os(tvOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                LibraryPlayBar(parent: viewModel.library.parent)
            }
            #endif
            #if os(tvOS)
            .background(alignment: .top) {
                if !router.isRootOfPath {
                    FocusedPosterCinematicBackgroundView()
                }
            }
            #else
            .navigationBarFilterDrawer(
                viewModel: filterViewModel,
                types: filterTypes
            )
            #endif
    }

    private func rememberSort(from filters: ItemFilterCollection) {
        guard let id = viewModel.library.parent.id,
              Defaults[.Customization.Library.rememberSort]
        else { return }

        let storedFilters = StoredValues[.User.libraryFilters(parentID: id)]
            .mutating(\.sortBy, with: filters.sortBy)
            .mutating(\.sortOrder, with: filters.sortOrder)

        StoredValues[.User.libraryFilters(parentID: id)] = storedFilters
    }
}

// MARK: - Play All / Shuffle

/// Plays the items of a library or folder one after another.
@MainActor
final class ListMediaPlayerQueue: ViewModel, MediaPlayerQueue {

    weak var manager: MediaPlayerManager? {
        didSet {
            cancellables = []
            guard let manager else { return }

            manager.$playbackItem
                .sink { [weak self] newItem in
                    self?.didReceive(newItem: newItem)
                }
                .store(in: &cancellables)
        }
    }

    let displayTitle: String
    let id: String = "ListMediaPlayerQueue"

    @Published
    var nextItem: MediaPlayerItemProvider? = nil
    @Published
    var previousItem: MediaPlayerItemProvider? = nil

    @Published
    var hasNextItem: Bool = false
    @Published
    var hasPreviousItem: Bool = false

    lazy var hasNextItemPublisher: Published<Bool>.Publisher = $hasNextItem
    lazy var hasPreviousItemPublisher: Published<Bool>.Publisher = $hasPreviousItem
    lazy var nextItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $nextItem
    lazy var previousItemPublisher: Published<MediaPlayerItemProvider?>.Publisher = $previousItem

    private let items: [BaseItemDto]

    init(items: [BaseItemDto], displayTitle: String) {
        self.items = items
        self.displayTitle = displayTitle
        super.init()
    }

    var videoPlayerBody: some PlatformView {
        QueueOverlay(items: items)
    }

    func provider(for item: BaseItemDto) -> MediaPlayerItemProvider {
        MediaPlayerItemProvider(item: item) { [weak self] item, modifyItem in
            let bitrate = self?.manager?.playbackBitrate ?? Defaults[.VideoPlayer.Playback.appMaximumBitrate]
            return try await MediaPlayerItem.build(for: item, requestedBitrate: bitrate) { item in
                item.userData?.playbackPositionTicks = .zero
                modifyItem?(&item)
            }
        }
    }

    private func didReceive(newItem: MediaPlayerItem?) {
        guard let currentID = newItem?.baseItem.id,
              let index = items.firstIndex(where: { $0.id == currentID })
        else {
            nextItem = nil
            previousItem = nil
            hasNextItem = false
            hasPreviousItem = false
            return
        }

        let next = items[safe: index + 1].map { provider(for: $0) }
        let previous = items[safe: index - 1].map { provider(for: $0) }

        nextItem = next
        previousItem = previous
        hasNextItem = next != nil
        hasPreviousItem = previous != nil
    }

    private struct QueueOverlay: PlatformView {

        @EnvironmentObject
        private var manager: MediaPlayerManager

        let items: [BaseItemDto]

        private func select(item: BaseItemDto) {
            let provider = MediaPlayerItemProvider(item: item) { [manager] item, modifyItem in
                try await MediaPlayerItem.build(
                    for: item,
                    requestedBitrate: manager.playbackBitrate,
                    modifyItem: modifyItem
                )
            }

            manager.playNewItem(provider: provider)
        }

        private var list: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(items, id: \.id) { item in
                        Button {
                            select(item: item)
                        } label: {
                            Text(item.displayTitle)
                        }
                    }
                }
                .padding()
            }
        }

        var iOSView: some View {
            list
        }

        var tvOSView: some View {
            list
        }
    }
}

#if os(tvOS)

/// Play All and Shuffle buttons for a library or folder.
private struct LibraryPlayBar: View {

    @Injected(\.currentUserSession)
    private var userSession

    @Router
    private var router

    @State
    private var isLoading = false
    @State
    private var error: Error?

    let parent: BaseItemDto

    private var isVisible: Bool {
        // The playlists view only lists playlists, so there is nothing to play at that level.
        guard parent.id != nil, parent.collectionType != .livetv, parent.collectionType != .playlists else { return false }

        switch parent.libraryType {
        case .collectionFolder, .userView, .folder, .playlist:
            return true
        default:
            return false
        }
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 24) {
                Button {
                    play(shuffle: false)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }

                Button {
                    play(shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }

                Spacer()
            }
            .disabled(isLoading)
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .errorMessage($error)
        }
    }

    /// Plays everything under `parent`, ordered by artist or shuffled.
    private func play(shuffle: Bool) {
        guard let userSession, let parentID = parent.id else { return }

        isLoading = true

        Task {
            defer { isLoading = false }

            do {
                var parameters = Paths.GetItemsParameters()
                parameters.userID = userSession.user.id
                parameters.parentID = parentID
                parameters.isRecursive = true
                parameters.includeItemTypes = [.movie, .musicVideo, .video, .episode]
                parameters.fields = PosterSubtitleField.itemFields
                parameters.enableUserData = true
                parameters.limit = 1000

                if shuffle {
                    parameters.sortBy = [.random]
                } else if parent.libraryType != .playlist {
                    // A playlist keeps the order it was built in, so it gets no sort.
                    parameters.sortBy = [.artist, .sortName]
                    parameters.sortOrder = [.ascending]
                }

                let response = try await userSession.client.send(Paths.getItems(parameters: parameters))

                guard let items = response.value.items, let first = items.first else { return }

                let queue = ListMediaPlayerQueue(items: items, displayTitle: parent.displayTitle)

                router.route(
                    to: .videoPlayer(
                        provider: queue.provider(for: first),
                        queue: queue
                    )
                )
            } catch {
                self.error = error
            }
        }
    }
}

#endif

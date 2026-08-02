//
//  ContentView.swift
//  Music Spinner
//
//  Created by Elliot Williams on 2025-07-12.
//

import SwiftUI
import MediaPlayer
import AVFoundation

// MARK: - Album Metadata Cache
struct AlbumMetadata: Codable {
    let id: String
    let title: String
    let artist: String
    let songCount: Int
    let hasArtwork: Bool
    let lastUpdated: Date
    
    init(from album: MusicAlbum) {
        self.id = album.id
        self.title = album.title
        self.artist = album.artist
        self.songCount = album.songs.count
        self.hasArtwork = album.artwork != nil
        self.lastUpdated = Date()
    }
}

class AlbumMetadataCache {
    static let shared = AlbumMetadataCache()
    
    private let metadataCacheURL: URL
    private let cacheQueue = DispatchQueue(label: "MetadataCacheQueue", qos: .utility)
    
    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        metadataCacheURL = cacheDir.appendingPathComponent("MusicSpinnerMetadata.json")
    }
    
    func saveAlbumMetadata(_ albums: [MusicAlbum]) {
        cacheQueue.async {
            let metadata = albums.map { AlbumMetadata(from: $0) }
            if let data = try? JSONEncoder().encode(metadata) {
                try? data.write(to: self.metadataCacheURL)
                print("💾 Cached metadata for \(albums.count) albums")
            }
        }
    }
    
    func loadAlbumMetadata() -> [AlbumMetadata]? {
        guard let data = try? Data(contentsOf: metadataCacheURL),
              let metadata = try? JSONDecoder().decode([AlbumMetadata].self, from: data) else {
            return nil
        }
        
        // Filter out metadata older than 7 days
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let validMetadata = metadata.filter { $0.lastUpdated > cutoffDate }
        
        print("📖 Loaded metadata for \(validMetadata.count) albums from cache")
        return validMetadata
    }
    
    func clearMetadataCache() {
        cacheQueue.async {
            try? FileManager.default.removeItem(at: self.metadataCacheURL)
        }
    }
}

// MARK: - Advanced Image Cache Manager
class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    private let maxMemoryCacheSize: Int = 30 * 1024 * 1024 // Reduced for better memory management
    private let maxDiskCacheSize: Int = 100 * 1024 * 1024 // Reduced for better performance
    private let cacheQueue = DispatchQueue(label: "ImageCacheQueue", qos: .utility)
    
    // Memory pressure handling
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    
    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = cacheDir.appendingPathComponent("MusicSpinnerImageCache")
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = maxMemoryCacheSize
        memoryCache.countLimit = 50 // Reduced for better memory management
        
        // Setup memory pressure monitoring
        setupMemoryPressureMonitoring()
        
        // Setup notification observers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    private func setupMemoryPressureMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        memoryPressureSource?.resume()
    }
    
    @objc private func handleMemoryWarning() {
        clearMemoryCache()
    }
    
    private func handleMemoryPressure() {
        clearMemoryCache()
    }
    
    func getImage(for albumId: String) -> UIImage? {
        let key = NSString(string: albumId)
        if let cachedImage = memoryCache.object(forKey: key) {
            return cachedImage
        }
        let diskURL = diskCacheURL.appendingPathComponent("\(albumId).jpg")
        if let diskImage = UIImage(contentsOfFile: diskURL.path) {
            let cost = Int(diskImage.size.width * diskImage.size.height * 4)
            memoryCache.setObject(diskImage, forKey: key, cost: cost)
            return diskImage
        }
        return nil
    }
    
    func setImage(_ image: UIImage, for albumId: String) {
        let key = NSString(string: albumId)
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key, cost: cost)
        cacheQueue.async {
            let diskURL = self.diskCacheURL.appendingPathComponent("\(albumId).jpg")
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                try? imageData.write(to: diskURL)
            }
        }
    }
    
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    func clearDiskCache() {
        cacheQueue.async {
            try? FileManager.default.removeItem(at: self.diskCacheURL)
            try? FileManager.default.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        }
    }
    
    func getCacheSize() -> Int {
        var size = 0
        if let enumerator = FileManager.default.enumerator(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    size += fileSize
                }
            }
        }
        return size
    }
}

// MARK: - Model
struct MusicAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    private var _artwork: UIImage?
    var colors: [Color] = []
    let songs: [MPMediaItem]
    
    var artwork: UIImage? {
        get { _artwork ?? ImageCacheManager.shared.getImage(for: id) }
        set { _artwork = newValue }
    }
    
    init(id: String, title: String, artist: String, artwork: UIImage? = nil, colors: [Color] = [.gray, .black], songs: [MPMediaItem]) {
        self.id = id
        self.title = title
        self.artist = artist
        self._artwork = artwork
        self.colors = colors
        self.songs = songs
    }
}

// MARK: - Audio Player Manager
class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrack: MPMediaItem?
    @Published var playbackProgress: Double = 0.0
    @Published var currentTrackIndex = 0
    @Published var errorMessage: String?
    @Published var isShuffleEnabled = false
    @Published var isRepeatEnabled = false
    @Published var currentAlbum: MusicAlbum?
    
    private let musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    private var progressTimer: Timer?
    private var currentPlaylist: [MPMediaItem] = []
    
    init() {
        setupMusicPlayerObservers()
    }
    
    deinit {
        cleanup()
    }
    
    private func cleanup() {
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func setupMusicPlayerObservers() {
        musicPlayer.beginGeneratingPlaybackNotifications()
        
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.updatePlaybackState()
        }
        
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            self?.updateCurrentTrack()
        }
        
        startProgressTimer()
    }
    
    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let currentItem = self.musicPlayer.nowPlayingItem else { return }
            let currentTime = self.musicPlayer.currentPlaybackTime
            let duration = currentItem.playbackDuration
            if duration > 0 {
                self.playbackProgress = currentTime / duration
            }
        }
    }
    
    private func updatePlaybackState() {
        let newState = musicPlayer.playbackState == .playing
        if isPlaying != newState {
            isPlaying = newState
            print("🎵 Playback state changed to: \(isPlaying ? "Playing" : "Paused")")
        }
    }
    
    private func updateCurrentTrack() {
        currentTrack = musicPlayer.nowPlayingItem
        if let track = currentTrack {
            print("🎵 Now playing: \(track.title ?? "Unknown") by \(track.artist ?? "Unknown")")
            updateCurrentTrackIndex()
        }
    }
    
    private func updateCurrentTrackIndex() {
        guard let currentTrack = currentTrack else { return }
        if let index = currentPlaylist.firstIndex(of: currentTrack) {
            currentTrackIndex = index
        }
    }
    
    // MARK: - Playback Controls
    
    func playTrack(_ track: MPMediaItem) {
        print("🎵 Attempting to play track: \(track.title ?? "Unknown")")
        
        let collection = MPMediaItemCollection(items: [track])
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: collection)
        musicPlayer.setQueue(with: descriptor)
        musicPlayer.nowPlayingItem = track
        musicPlayer.play()
        
        currentTrack = track
        currentPlaylist = [track]
        currentTrackIndex = 0
        playbackProgress = 0.0
        errorMessage = nil
        
        print("🎵 Started playing: \(track.title ?? "Unknown")")
    }
    
    func playAlbum(_ album: MusicAlbum, startingAt index: Int = 0) {
        guard !album.songs.isEmpty, index >= 0, index < album.songs.count else {
            print("❌ Invalid album or index for playback")
            return
        }
        
        print("🎵 Playing album: \(album.title) starting at track \(index + 1)")
        
        currentAlbum = album
        currentPlaylist = album.songs
        
        let collection = MPMediaItemCollection(items: album.songs)
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: collection)
        musicPlayer.setQueue(with: descriptor)
        musicPlayer.nowPlayingItem = album.songs[index]
        musicPlayer.play()
        
        currentTrack = album.songs[index]
        currentTrackIndex = index
        playbackProgress = 0.0
        errorMessage = nil
        
        print("🎵 Started playing album: \(album.title)")
    }
    
    func pause() {
        musicPlayer.pause()
        print("⏸️ Paused playback")
    }
    
    func resume() {
        musicPlayer.play()
        print("▶️ Resumed playback")
    }
    
    func stop() {
        musicPlayer.stop()
        currentTrack = nil
        currentAlbum = nil
        currentPlaylist = []
        currentTrackIndex = 0
        playbackProgress = 0.0
        errorMessage = nil
        print("⏹️ Stopped playback")
    }
    
    func skipToNext() {
        if isShuffleEnabled && !currentPlaylist.isEmpty {
            let randomIndex = Int.random(in: 0..<currentPlaylist.count)
            let randomTrack = currentPlaylist[randomIndex]
            musicPlayer.nowPlayingItem = randomTrack
            musicPlayer.play()
            currentTrackIndex = randomIndex
        } else {
            musicPlayer.skipToNextItem()
        }
        playbackProgress = 0.0
        print("⏭️ Skipped to next track")
    }
    
    func skipToPrevious() {
        if isShuffleEnabled && !currentPlaylist.isEmpty {
            let randomIndex = Int.random(in: 0..<currentPlaylist.count)
            let randomTrack = currentPlaylist[randomIndex]
            musicPlayer.nowPlayingItem = randomTrack
            musicPlayer.play()
            currentTrackIndex = randomIndex
        } else {
            musicPlayer.skipToPreviousItem()
        }
        playbackProgress = 0.0
        print("⏮️ Skipped to previous track")
    }
    
    func seekTo(progress: Double) {
        guard let currentItem = musicPlayer.nowPlayingItem else { return }
        let duration = currentItem.playbackDuration
        let targetTime = duration * progress
        musicPlayer.currentPlaybackTime = targetTime
        playbackProgress = progress
        print("🔄 Seeked to \(Int(progress * 100))%")
    }
    
    func toggleShuffle() {
        isShuffleEnabled.toggle()
        musicPlayer.shuffleMode = isShuffleEnabled ? .songs : .off
        print("🔀 Shuffle \(isShuffleEnabled ? "enabled" : "disabled")")
    }
    
    func toggleRepeat() {
        isRepeatEnabled.toggle()
        musicPlayer.repeatMode = isRepeatEnabled ? .all : .none
        print("🔁 Repeat \(isRepeatEnabled ? "enabled" : "disabled")")
    }
    
    // MARK: - Utility Methods
    
    func getCurrentTrackTitle() -> String {
        return currentTrack?.title ?? "No track playing"
    }
    
    func getCurrentTrackArtist() -> String {
        return currentTrack?.artist ?? "Unknown Artist"
    }
    
    func getCurrentTrackArtwork() -> UIImage? {
        return currentTrack?.artwork?.image(at: CGSize(width: 300, height: 300))
    }
    
    func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func getCurrentTime() -> String {
        guard let currentItem = musicPlayer.nowPlayingItem else { return "0:00" }
        let currentTime = musicPlayer.currentPlaybackTime
        return formatTime(currentTime)
    }
    
    func getTotalTime() -> String {
        guard let currentItem = musicPlayer.nowPlayingItem else { return "0:00" }
        let totalTime = currentItem.playbackDuration
        return formatTime(totalTime)
    }
}

// MARK: - ViewModel
@MainActor
class MusicViewModel: ObservableObject {
    @Published var albums: [MusicAlbum] = []
    @Published var isLoading = false
    @Published var error: Error?
    @Published var showPermissionAlert = false
    @Published var loadingProgress: Double = 0.0
    
    private var colorCache: [String: [Color]] = [:]
    private let imageCache = ImageCacheManager.shared
    private let metadataCache = AlbumMetadataCache.shared
    private let artworkLoadingQueue = DispatchQueue(label: "ArtworkLoading", qos: .userInitiated, attributes: .concurrent)
    private let batchSize = 50 // Process albums in batches to prevent memory spikes
    private let maxConcurrentTasks = 10 // Limit concurrent artwork loading
    
    func fetchAlbums() async {
        guard !isLoading else { return }
        isLoading = true
        await requestAuthorization()
    }
    
    private func requestAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus)
            }
        }
        
        await MainActor.run {
            switch status {
            case .authorized:
                Task { await self.loadAlbums() }
            case .denied, .restricted:
                self.error = NSError(domain: "Music", code: 403, userInfo: [
                    NSLocalizedDescriptionKey: "Music library access denied. Please enable access in Settings."
                ])
                self.showPermissionAlert = true
                self.isLoading = false
            default:
                self.error = NSError(domain: "Music", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "Authorization error"
                ])
                self.isLoading = false
            }
        }
    }
    
    private func loadAlbums() async {
        // Try to load cached metadata first for instant app startup
        if let cachedMetadata = metadataCache.loadAlbumMetadata() {
            print("🚀 Using cached metadata for fast startup")
            
            // Create albums from cached metadata
            let cachedAlbums = cachedMetadata.compactMap { metadata -> MusicAlbum? in
                // Try to find the actual collection to get songs
                let query = MPMediaQuery.albums()
                guard let collection = query.collections?.first(where: {
                    String($0.representativeItem?.albumPersistentID ?? 0) == metadata.id
                }) else { return nil }
                
                return MusicAlbum(
                    id: metadata.id,
                    title: metadata.title,
                    artist: metadata.artist,
                    songs: collection.items
                )
            }
            
            // Update UI immediately with cached data
            await MainActor.run {
                self.albums = cachedAlbums.sorted { $0.title < $1.title }
                self.loadingProgress = 0.8 // Almost done since we have cached data
            }
            
            // Load artwork for cached albums in background
            await loadArtworkInBatches(for: cachedAlbums)
            
            await MainActor.run {
                self.isLoading = false
                self.loadingProgress = 1.0
            }
            
            // Save updated metadata in background
            metadataCache.saveAlbumMetadata(cachedAlbums)
            return
        }
        
        // Full load if no cache available
        let query = MPMediaQuery.albums()
        let collections = query.collections ?? []
        
        // Clear any existing memory cache to prevent memory issues
        imageCache.clearMemoryCache()
        
        // Process albums in batches to prevent memory spikes
        let totalCount = collections.count
        var processedAlbums: [MusicAlbum] = []
        
        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, totalCount)
            let batch = Array(collections[batchStart..<batchEnd])
            
            let batchAlbums = batch.compactMap { collection -> MusicAlbum? in
                guard let item = collection.representativeItem else { return nil }
                let albumId = String(item.albumPersistentID)
                return MusicAlbum(
                    id: albumId,
                    title: item.albumTitle ?? "Unknown Album",
                    artist: item.albumArtist ?? "Unknown Artist",
                    songs: collection.items
                )
            }
            
            processedAlbums.append(contentsOf: batchAlbums)
            
            // Update progress and UI
            await MainActor.run {
                self.loadingProgress = Double(batchEnd) / Double(totalCount) * 0.5 // First 50% for loading
                self.albums = processedAlbums.sorted { $0.title < $1.title }
            }
            
            // Small delay to prevent UI blocking and allow memory cleanup
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms for better memory management
        }
        
        await MainActor.run {
            self.albums = processedAlbums.sorted { $0.title < $1.title }
            self.loadingProgress = 0.5
        }
        
        // Load artwork in controlled batches
        await loadArtworkInBatches(for: processedAlbums)
        
        await MainActor.run {
            self.isLoading = false
            self.loadingProgress = 1.0
        }
        
        // Save metadata to cache for next launch
        metadataCache.saveAlbumMetadata(processedAlbums)
    }
    
    private func loadArtworkInBatches(for albums: [MusicAlbum]) async {
        let totalAlbums = albums.count
        var processedCount = 0
        
        // Use smaller batch size for artwork loading to prevent memory issues
        let artworkBatchSize = 20
        
        for batchStart in stride(from: 0, to: totalAlbums, by: artworkBatchSize) {
            let batchEnd = min(batchStart + artworkBatchSize, totalAlbums)
            let batch = Array(albums[batchStart..<batchEnd])
            
            await withTaskGroup(of: Void.self) { group in
                for album in batch {
                    group.addTask { [weak self] in
                        let task = Task {
                            await self?.loadArtwork(for: album)
                        }
                        _ = await task.result
                    }
                }
            }
            
            processedCount += batch.count
            await MainActor.run {
                self.loadingProgress = 0.5 + (Double(processedCount) / Double(totalAlbums)) * 0.5
            }
            
            // Clear memory cache periodically during artwork loading
            if processedCount % 100 == 0 {
                self.imageCache.clearMemoryCache()
            }
            
            // Small delay to allow memory cleanup
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
        }
    }
    
    func loadArtwork(for album: MusicAlbum) async {
        // Check cache first
        if ImageCacheManager.shared.getImage(for: album.id) != nil {
            return
        }
        
        let query = MPMediaQuery.albums()
        guard let collection = query.collections?.first(where: {
            String($0.representativeItem?.albumPersistentID ?? 0) == album.id
        }), let item = collection.representativeItem else { return }
        
        // Use smaller artwork size for better performance and memory usage
        let artwork = item.artwork?.image(at: CGSize(width: 120, height: 120))
        if let artwork = artwork {
            // Cache the image
            ImageCacheManager.shared.setImage(artwork, for: album.id)
            
            await MainActor.run {
                if let index = self.albums.firstIndex(where: { $0.id == album.id }) {
                    var updatedAlbum = self.albums[index]
                    updatedAlbum.artwork = artwork
                    self.albums[index] = updatedAlbum
                }
            }
        }
    }
}

// MARK: - Particle Effect
struct ParticleEffect: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let color: Color
    let scale: CGFloat
    let velocity: CGPoint
    let lifetime: Double
    
    static func create(at position: CGPoint, with color: Color) -> ParticleEffect {
        ParticleEffect(
            x: position.x,
            y: position.y,
            color: color,
            scale: Double.random(in: 0.5...1.5),
            velocity: CGPoint(
                x: Double.random(in: -2...2),
                y: Double.random(in: -3...0)
            ),
            lifetime: Double.random(in: 1...3)
        )
    }
}

struct ParticleView: View {
    let particle: ParticleEffect
    @State private var opacity: Double = 1.0
    @State private var offset: CGSize = .zero
    
    var body: some View {
        Circle()
            .fill(particle.color)
            .frame(width: 8, height: 8)
            .scaleEffect(particle.scale)
            .opacity(opacity)
            .offset(offset)
            .onAppear {
                withAnimation(.linear(duration: particle.lifetime)) {
                    opacity = 0
                    offset = CGSize(
                        width: particle.velocity.x * 100,
                        height: particle.velocity.y * 100
                    )
                }
            }
    }
}

// MARK: - Main View
struct MusicSpinnerPlayer: View {
    @StateObject private var viewModel = MusicViewModel()
    @StateObject private var audioPlayer = AudioPlayerManager()
    
    @State private var selectedAlbum: MusicAlbum?
    @State private var isSpinning = false
    @State private var spinAmount: Double = 0
    @State private var spinVelocity: Double = 0
    @State private var isSpinCompleted = false
    @State private var showPlayButton = false
    
    // New animation states
    @State private var sparkleAnimation = false
    @State private var pulseAnimation = false
    @State private var selectedScale: CGFloat = 1.0
    @State private var showSparkles = false
    @State private var particles: [ParticleEffect] = []
    
    // Background color animation states
    @State private var currentBackgroundColors: [Color] = [.purple, .indigo, .black]
    @State private var isAnimatingColors = false
    @State private var colorAnimationTimer: Timer?
    
    // New feature states
    @State private var showShuffleButton = false
    @State private var favoriteAlbums: Set<String> = []
    @State private var showFavoritesOnly = false
    @State private var showMediaControls = false
    
    // Optimization: Only show subset of albums on wheel for large libraries
    private var displayedAlbums: [MusicAlbum] {
        let maxDisplayedAlbums = 20
        return viewModel.albums.count > maxDisplayedAlbums ? 
            Array(viewModel.albums.prefix(maxDisplayedAlbums)) : 
            viewModel.albums
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dynamic Background gradient
                LinearGradient(
                    gradient: Gradient(colors: currentBackgroundColors),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: isAnimatingColors ? 0.3 : 1.2), value: currentBackgroundColors)
                
                if viewModel.isLoading {
                    // Enhanced Loading View with Pulsing Animation
                    VStack(spacing: 20) {
                        Text("LOADING MUSIC LIBRARY")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .shadow(radius: 5)
                            .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseAnimation)
                            .onAppear {
                                pulseAnimation = true
                            }
                        
                        ProgressView(value: viewModel.loadingProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                            .frame(width: 200)
                        
                        Text("\(Int(viewModel.loadingProgress * 100))%")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("Found \(viewModel.albums.count) albums")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else {
                    VStack {
                        Spacer()
                        
                        // Enhanced Title with Sparkle Effect
                        Text("MUSIC SPINNER")
                            .font(.largeTitle)
                            .fontWeight(.black)
                            .foregroundColor(.white)
                            .shadow(color: .cyan, radius: sparkleAnimation ? 20 : 10)
                            .padding(.top, 30)
                            .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: sparkleAnimation)
                            .onAppear {
                                sparkleAnimation = true
                            }
                        
                        // Album count info with fade-in animation
                        Text("\(viewModel.albums.count) albums loaded")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 5)
                            .opacity(viewModel.albums.isEmpty ? 0 : 1)
                            .animation(.easeIn(duration: 0.5), value: viewModel.albums.count)
                        
                        Spacer()
                        
                        // Enhanced Album wheel with particles and pointer
                        ZStack {
                            // Particle effects
                            ForEach(particles, id: \.id) { particle in
                                ParticleView(particle: particle)
                                    .position(x: particle.x, y: particle.y)
                            }
                            
                            // Album wheel
                            ForEach(Array(displayedAlbums.enumerated()), id: \.element.id) { index, album in
                                let isTopPosition = index == 0 // Top position after spin
                                AlbumWheelItem(album: album, isSelected: selectedAlbum?.id == album.id, isTopPosition: isTopPosition)
                                    .rotationEffect(.degrees(Double(index) * (360 / Double(displayedAlbums.count))))
                                    .offset(y: -geometry.size.width * 0.30) // Moved closer to center
                                    .rotationEffect(.degrees(spinAmount))
                                    .scaleEffect(getScaleForAlbum(album, at: index))
                                    .zIndex(selectedAlbum?.id == album.id ? 10 : 1) // Bring selected to front
                                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: selectedAlbum?.id)
                            }
                            
                            // Pointer/Indicator at the top
                            VStack {
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                                    .shadow(color: .black, radius: 5)
                                    .offset(y: -geometry.size.width * 0.30 - 70) // Adjusted for new position
                                Spacer()
                            }
                            
                            // Large selected album display at top
                            if let selectedAlbum = selectedAlbum, !isSpinning {
                                VStack {
                                    if let artwork = selectedAlbum.artwork {
                                        Image(uiImage: artwork)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 120, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(Color.white, lineWidth: 4)
                                            )
                                            .shadow(color: Color.white.opacity(0.5), radius: 20, x: 0, y: 10)
                                    } else {
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(LinearGradient(gradient: Gradient(colors: [.gray, .black]), startPoint: .top, endPoint: .bottom))
                                            .frame(width: 120, height: 120)
                                            .overlay(
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 40))
                                                    .foregroundColor(.white.opacity(0.7))
                                            )
                                    }
                                    
                                    Text(selectedAlbum.title)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .padding(.horizontal)
                                        .shadow(color: .black, radius: 3)
                                    
                                    Text(selectedAlbum.artist)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(1)
                                        .shadow(color: .black, radius: 2)
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(Color.black.opacity(0.3))
                                        .blur(radius: 3)
                                )
                                .offset(y: -geometry.size.width * 0.55) // Position above the wheel
                                .zIndex(5)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.1).combined(with: .opacity),
                                    removal: .scale(scale: 0.1).combined(with: .opacity)
                                ))
                                .animation(.spring(response: 0.6, dampingFraction: 0.7), value: selectedAlbum.id)
                            }
                        }
                        .rotationEffect(.degrees(spinAmount))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    spinVelocity = value.translation.width / 5
                                }
                                .onEnded { _ in
                                    startSpin()
                                }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        
                        // Enhanced Spin button with bounce animation - moved up
                        Button(action: startSpin) {
                            Text("SPIN")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding()
                                .frame(width: 180)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.blue, .purple]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .cornerRadius(30)
                                .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 10)
                                .opacity(isSpinning ? 0.5 : 1.0)
                                .scaleEffect(isSpinning ? 1.2 : 1.0)
                                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isSpinning)
                        }
                        .padding(.bottom, 20)
                        .disabled(isSpinning || viewModel.albums.isEmpty)
                        
                        Spacer()
                        
                        // Enhanced Play button with glow effect
                        if showPlayButton, let album = selectedAlbum {
                            VStack(spacing: 10) {
                                Text("🎵 \(album.title) 🎵")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .shadow(color: .cyan, radius: 5)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                                
                                Button(action: {
                                    playSelectedAlbum(album)
                                }) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 70))
                                        .foregroundColor(.white)
                                        .shadow(color: audioPlayer.isPlaying ? .green : .blue, radius: audioPlayer.isPlaying ? 20 : 10)
                                        .scaleEffect(audioPlayer.isPlaying ? 1.2 : 1.0)
                                        .animation(.easeInOut(duration: 0.3), value: audioPlayer.isPlaying)
                                }
                                .padding(.bottom, 10)
                            }
                        }
                        
                        // Show Controls Button
                        if audioPlayer.currentTrack != nil {
                            Button(action: {
                                showMediaControls = true
                            }) {
                                HStack {
                                    Image(systemName: "music.note")
                                    Text("Show Controls")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.gray, .black]),
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .cornerRadius(20)
                                .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
                            }
                            .padding(.bottom, 20)
                        }
                        
                        Spacer()
                    }
                }
            }
            
            // Media Controls Overlay
            if showMediaControls {
                ZStack {
                    // Semi-transparent background
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showMediaControls = false
                        }
                    
                    // Controls panel
                    VStack {
                        // Exit button
                        HStack {
                            Spacer()
                            Button(action: {
                                showMediaControls = false
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            .padding(.trailing, 20)
                            .padding(.top, 20)
                        }
                        
                        Spacer()
                        
                        // Playback controls
                        PlaybackControlPanel(
                            audioPlayer: audioPlayer,
                            onPlayPause: {
                                if audioPlayer.isPlaying {
                                    audioPlayer.pause()
                                } else {
                                    audioPlayer.resume()
                                }
                            },
                            onNext: {
                                audioPlayer.skipToNext()
                            },
                            onPrevious: {
                                audioPlayer.skipToPrevious()
                            },
                            onShuffle: {
                                audioPlayer.toggleShuffle()
                            },
                            onRepeat: {
                                audioPlayer.toggleRepeat()
                            },
                            onSeek: { progress in
                                audioPlayer.seekTo(progress: progress)
                            }
                        )
                        .padding(.horizontal, 20)
                        
                        Spacer()
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showMediaControls)
            }
        }
        .task {
            await viewModel.fetchAlbums()
            if let first = viewModel.albums.first {
                selectedAlbum = first
                // Set initial background colors from first album or default
                currentBackgroundColors = extractColorsFromAlbum(first) ?? [.purple, .indigo, .black]
            }
        }
    }
    
    private func startSpin() {
        guard !isSpinning else { return }
        
        isSpinning = true
        showPlayButton = false
        
        // Start background color animation
        startColorAnimation()
        
        // Calculate target album and rotation
        let targetAlbumIndex = Int.random(in: 0..<displayedAlbums.count)
        let targetAlbum = displayedAlbums[targetAlbumIndex]
        
        // Calculate the angle needed to land on the target album
        let anglePerAlbum = 360.0 / Double(displayedAlbums.count)
        let targetAngle = Double(targetAlbumIndex) * anglePerAlbum
        
        // Add multiple full rotations plus the target angle
        let fullRotations = Double.random(in: 3...6) * 360.0
        let finalAngle = spinAmount + fullRotations + (360.0 - targetAngle) // Negative because wheel rotates opposite
        
        // Initial quick spin
        withAnimation(.easeOut(duration: 0.5)) {
            spinAmount += Double.random(in: 180...360)
        }
        
        // Main spin with precise landing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 2.5).delay(0.0)) {
                spinAmount = finalAngle
            }
            
            // Select the target album after spin completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                stopColorAnimation()
                selectSpecificAlbum(targetAlbum)
                isSpinning = false
                showPlayButton = true
            }
        }
    }
    
    private func selectRandomAlbum() {
        guard !viewModel.albums.isEmpty else { return }
        let randomIndex = Int.random(in: 0..<viewModel.albums.count)
        selectedAlbum = viewModel.albums[randomIndex]
        
        // Enhanced haptic feedback
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        
        // Create particle effect
        createParticleEffect()
        
        // Animate selected scale
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            selectedScale = 1.3
        }
        
        // Reset scale after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                selectedScale = 1.0
            }
        }
    }
    
    private func selectSpecificAlbum(_ album: MusicAlbum) {
        selectedAlbum = album
        
        // Transition to album-specific colors
        let albumColors = extractColorsFromAlbum(album) ?? [.purple, .indigo, .black]
        withAnimation(.easeInOut(duration: 1.0)) {
            currentBackgroundColors = albumColors
        }
        
        // Enhanced haptic feedback
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        
        // Create particle effect
        createParticleEffect()
        
        // Animate selected scale
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            selectedScale = 1.3
        }
        
        // Reset scale after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                selectedScale = 1.0
            }
        }
    }
    
    private func playSelectedAlbum(_ album: MusicAlbum) {
        guard !album.songs.isEmpty else { return }
        
        // Play the entire album starting from the first track
        audioPlayer.playAlbum(album, startingAt: 0)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Create celebration particle effect
        createCelebrationParticles()
        
        print("🎵 Started playing album: \(album.title) with \(album.songs.count) tracks")
    }
    
    private func createParticleEffect() {
        let centerX = UIScreen.main.bounds.width / 2
        let centerY = UIScreen.main.bounds.height / 2
        
        for _ in 0..<15 {
            let particle = ParticleEffect.create(
                at: CGPoint(x: centerX, y: centerY),
                with: [.yellow, .cyan, .white, .purple].randomElement() ?? .yellow
            )
            particles.append(particle)
        }
        
        // Remove particles after their lifetime
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            particles.removeAll()
        }
    }
    
    private func createCelebrationParticles() {
        let centerX = UIScreen.main.bounds.width / 2
        let centerY = UIScreen.main.bounds.height / 2
        
        for _ in 0..<25 {
            let particle = ParticleEffect.create(
                at: CGPoint(
                    x: centerX + CGFloat.random(in: -50...50),
                    y: centerY + CGFloat.random(in: -50...50)
                ),
                with: [.green, .blue, .white, .cyan].randomElement() ?? .green
            )
            particles.append(particle)
        }
        
        // Remove particles after their lifetime
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            particles.removeAll()
        }
    }
    
    // MARK: - Color Animation Functions
    private func startColorAnimation() {
        isAnimatingColors = true
        
        // Array of vibrant color combinations for spinning animation
        let colorSets: [[Color]] = [
            [.red, .orange, .yellow],
            [.blue, .cyan, .teal],
            [.purple, .pink, .red],
            [.green, .mint, .cyan],
            [.orange, .red, .pink],
            [.indigo, .blue, .purple],
            [.yellow, .orange, .red],
            [.teal, .blue, .indigo]
        ]
        
        var colorIndex = 0
        colorAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                currentBackgroundColors = colorSets[colorIndex % colorSets.count]
            }
            colorIndex += 1
        }
    }
    
    private func stopColorAnimation() {
        isAnimatingColors = false
        colorAnimationTimer?.invalidate()
        colorAnimationTimer = nil
    }
    
    // MARK: - Album Color Extraction
    private func extractColorsFromAlbum(_ album: MusicAlbum) -> [Color]? {
        guard let artwork = album.artwork else {
            return generateRandomColorPalette()
        }
        
        // Extract dominant colors from album artwork
        let dominantColors = extractDominantColors(from: artwork)
        
        if dominantColors.count >= 2 {
            return dominantColors
        } else {
            // Fallback to generated palette based on the single dominant color
            let fallbackUIColor = dominantColors.first.map { UIColor($0) } ?? UIColor.purple
            return generateColorPalette(from: fallbackUIColor)
        }
    }
    
    private func extractDominantColors(from image: UIImage) -> [Color] {
        guard image.cgImage != nil else { return [Color.purple, Color.indigo, Color.black] }
        let cgImage = image.cgImage!
        
        // Resize image for faster processing
        let size = CGSize(width: 50, height: 50)
        UIGraphicsBeginImageContext(size)
        image.draw(in: CGRect(origin: .zero, size: size))
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext(),
              let resizedCGImage = resizedImage.cgImage else {
            UIGraphicsEndImageContext()
            return [Color.purple, Color.indigo, Color.black]
        }
        UIGraphicsEndImageContext()
        
        // Extract pixel data
        let width = resizedCGImage.width
        let height = resizedCGImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return [Color.purple, Color.indigo, Color.black]
        }
        
        context.draw(resizedCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Analyze colors
        var colorCounts: [String: Int] = [:]
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let r = pixelData[pixelIndex]
                let g = pixelData[pixelIndex + 1]
                let b = pixelData[pixelIndex + 2]
                
                // Group similar colors
                let colorKey = "\(r/32)_\(g/32)_\(b/32)"
                colorCounts[colorKey, default: 0] += 1
            }
        }
        
        // Get top colors
        let sortedColors = colorCounts.sorted { $0.value > $1.value }
        var dominantColors: [Color] = []
        
        for (colorKey, _) in sortedColors.prefix(3) {
            let components = colorKey.split(separator: "_")
            if components.count == 3,
               let r = Int(components[0]),
               let g = Int(components[1]),
               let b = Int(components[2]) {
                let color = Color(
                    red: Double(r * 32) / 255.0,
                    green: Double(g * 32) / 255.0,
                    blue: Double(b * 32) / 255.0
                )
                dominantColors.append(color)
            }
        }
        
        // Ensure we have enough colors and add some variation
        if dominantColors.count < 3 {
            dominantColors.append(Color.black.opacity(0.8))
        }
        
        return dominantColors
    }
    
    private func generateColorPalette(from baseColor: UIColor) -> [Color] {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        
        baseColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        
        let color1 = Color(UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0))
        let color2 = Color(UIColor(hue: hue, saturation: max(0.1, saturation - 0.3), brightness: min(1.0, brightness + 0.2), alpha: 1.0))
        let color3 = Color(UIColor(hue: hue, saturation: min(1.0, saturation + 0.2), brightness: max(0.1, brightness - 0.4), alpha: 1.0))
        
        return [color1, color2, color3]
    }
    
    private func generateRandomColorPalette() -> [Color] {
        let palettes: [[Color]] = [
            [.purple, .indigo, .black],
            [.blue, .cyan, .teal],
            [.red, .orange, .yellow],
            [.green, .mint, .cyan],
            [.pink, .purple, .indigo],
            [.orange, .red, .pink]
        ]
        return palettes.randomElement() ?? [.purple, .indigo, .black]
    }
    
    // MARK: - Helper Functions
    private func getScaleForAlbum(_ album: MusicAlbum, at index: Int) -> CGFloat {
        if selectedAlbum?.id == album.id {
            return selectedScale
        }
        // Make the top position (index 0) slightly larger
        return index == 0 ? 1.1 : 1.0
    }
}

// MARK: - Playback Control Panel
struct PlaybackControlPanel: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onSeek: (Double) -> Void
    
    @State private var isDragging = false
    @State private var dragProgress: Double = 0.0
    
    var body: some View {
        VStack(spacing: 16) {
            // Currently playing track info
            if let currentTrack = audioPlayer.currentTrack {
                VStack(spacing: 8) {
                    // Track artwork
                    if let artwork = audioPlayer.getCurrentTrackArtwork() {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    
                    // Track title and artist
                    Text(audioPlayer.getCurrentTrackTitle())
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black, radius: 2)
                    
                    Text(audioPlayer.getCurrentTrackArtist())
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .shadow(color: .black, radius: 1)
                    
                    // Album info if available
                    if let currentAlbum = audioPlayer.currentAlbum {
                        Text("from \(currentAlbum.title)")
                            .font(.caption.italic())
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Progress bar and time
            VStack(spacing: 4) {
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(height: 4)
                        
                        // Progress fill
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geometry.size.width * CGFloat(isDragging ? dragProgress : audioPlayer.playbackProgress), height: 4)
                            .shadow(color: .white.opacity(0.8), radius: 2)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                dragProgress = min(max(0, Double(value.location.x / geometry.size.width)), 1.0)
                            }
                            .onEnded { _ in
                                onSeek(dragProgress)
                                isDragging = false
                            }
                    )
                }
                .frame(height: 20)
                
                // Time labels
                HStack {
                    Text(audioPlayer.getCurrentTime())
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Spacer()
                    
                    Text(audioPlayer.getTotalTime())
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            
            // Main control buttons
            HStack(spacing: 30) {
                // Shuffle button
                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                        .font(.title2)
                        .foregroundColor(audioPlayer.isShuffleEnabled ? .blue : .white.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(audioPlayer.isShuffleEnabled ? Color.blue.opacity(0.2) : Color.clear)
                        )
                }
                
                // Previous button
                Button(action: onPrevious) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                
                // Play/Pause button
                Button(action: onPlayPause) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .foregroundColor(.black)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
                        )
                        .scaleEffect(audioPlayer.isPlaying ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: audioPlayer.isPlaying)
                }
                
                // Next button
                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                
                // Repeat button
                Button(action: onRepeat) {
                    Image(systemName: "repeat")
                        .font(.title2)
                        .foregroundColor(audioPlayer.isRepeatEnabled ? .green : .white.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(audioPlayer.isRepeatEnabled ? Color.green.opacity(0.2) : Color.clear)
                        )
                }
            }
            .padding(.vertical, 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.4))
                .blur(radius: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Album Wheel Item
struct AlbumWheelItem: View {
    let album: MusicAlbum
    let isSelected: Bool
    let isTopPosition: Bool // Add this parameter
    
    // Default initializer for backward compatibility
    init(album: MusicAlbum, isSelected: Bool, isTopPosition: Bool = false) {
        self.album = album
        self.isSelected = isSelected
        self.isTopPosition = isTopPosition
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Album artwork
            if let artwork = album.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: isSelected ? .yellow : .clear, radius: 15)
                    .rotation3DEffect(
                        .degrees(isSelected ? 15 : 0),
                        axis: (x: 1, y: 0, z: 0)
                    )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(gradient: Gradient(colors: [.gray, .black]), startPoint: .top, endPoint: .bottom))
                    .frame(width: 70, height: 70)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.7))
                    )
            }
            
            // Album title
            Text(album.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 80)
                .lineLimit(1)
                .shadow(color: .black, radius: 2, x: 0, y: 1)
        }
        .padding(5)
        .background(
            isSelected ? Color.white.opacity(0.2) : Color.clear
        )
        .cornerRadius(12)
    }
}

// MARK: - App Entry
@main
struct MusicSpinnerApp: App {
    var body: some Scene {
        WindowGroup {
            MusicSpinnerPlayer()
        }
    }
}

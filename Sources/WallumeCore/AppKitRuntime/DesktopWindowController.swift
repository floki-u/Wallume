import Foundation

@MainActor
public final class DesktopWindowController {
    private let factory: any DesktopSurfaceFactory
    private var surfaces = [DisplayID: (surface: any DesktopSurface, frame: CGRect)]()
    private var appliedPresentations = [DisplayID: AppliedPresentation]()

    public init(factory: any DesktopSurfaceFactory) { self.factory = factory }

    public func reconcile(_ screens: [DesktopScreen]) -> [DesktopSurfaceFailure] {
        var failures = [DesktopSurfaceFailure]()
        let next = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0) })
        for (id, value) in surfaces where next[id] == nil {
            value.surface.close()
            surfaces.removeValue(forKey: id)
            appliedPresentations.removeValue(forKey: id)
        }
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            if let current = surfaces[screen.id] {
                if current.frame != screen.frame { current.surface.show(frame: screen.frame); surfaces[screen.id] = (current.surface, screen.frame) }
                continue
            }
            do { let surface = try factory.makeSurface(for: screen); surface.show(frame: screen.frame); surfaces[screen.id] = (surface, screen.frame) }
            catch { failures.append(.init(displayID: screen.id, message: String(describing: error))) }
        }
        return failures.sorted { $0.displayID < $1.displayID }
    }

    public func apply(
        snapshot: RuntimeSnapshot,
        mediaByID: [UUID: MediaItem],
        modesByDisplay: [DisplayID: WallpaperPresentationMode] = [:]
    ) -> [DesktopSurfaceFailure] {
        let sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.displayID, $0) })
        let failures = Dictionary(snapshot.failures.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
        var presentationFailures = [DesktopSurfaceFailure]()
        for (displayID, value) in surfaces {
            let desired: AppliedPresentation
            let presentation: PlaybackPresentation?
            let fallbackURL: URL?
            let mode: WallpaperPresentationMode
            if let session = sessions[displayID], let media = mediaByID[session.mediaID] {
                mode = modesByDisplay[displayID] ?? .fill
                presentation = PlaybackPresentation(resourceID: session.resourceID)
                fallbackURL = media.coverURL
                desired = .playback(resourceID: session.resourceID, fallbackURL: media.coverURL, mode: mode)
            } else if let failure = failures[displayID], let media = mediaByID[failure.mediaID] {
                mode = modesByDisplay[displayID] ?? .fill
                presentation = nil
                fallbackURL = media.coverURL
                desired = .fallback(url: media.coverURL, mode: mode)
            } else {
                mode = .fill
                presentation = nil
                fallbackURL = nil
                desired = .blank
            }
            guard appliedPresentations[displayID] != desired else { continue }
            do {
                try value.surface.setPresentation(presentation, fallbackURL: fallbackURL, mode: mode)
                appliedPresentations[displayID] = desired
            } catch {
                appliedPresentations.removeValue(forKey: displayID)
                presentationFailures.append(.init(
                    displayID: displayID,
                    message: error.localizedDescription
                ))
            }
        }
        return presentationFailures.sorted { $0.displayID < $1.displayID }
    }

    public func closeAll() {
        surfaces.values.forEach { $0.surface.close() }
        surfaces.removeAll()
        appliedPresentations.removeAll()
    }

}

private enum AppliedPresentation: Equatable {
    case playback(resourceID: UUID, fallbackURL: URL, mode: WallpaperPresentationMode)
    case fallback(url: URL, mode: WallpaperPresentationMode)
    case blank
}

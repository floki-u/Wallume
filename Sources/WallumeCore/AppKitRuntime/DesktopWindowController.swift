import Foundation

@MainActor
public final class DesktopWindowController {
    private let factory: any DesktopSurfaceFactory
    private var surfaces = [DisplayID: (surface: any DesktopSurface, frame: CGRect)]()

    public init(factory: any DesktopSurfaceFactory) { self.factory = factory }

    public func reconcile(_ screens: [DesktopScreen]) -> [DesktopSurfaceFailure] {
        var failures = [DesktopSurfaceFailure]()
        let next = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0) })
        for (id, value) in surfaces where next[id] == nil { value.surface.close(); surfaces.removeValue(forKey: id) }
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

    public func apply(snapshot: RuntimeSnapshot, mediaByID: [UUID: MediaItem]) {
        let sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.displayID, $0) })
        for (displayID, value) in surfaces {
            guard let session = sessions[displayID], let media = mediaByID[session.mediaID] else {
                value.surface.setPresentation(nil, fallbackURL: nil)
                continue
            }
            value.surface.setPresentation(
                PlaybackPresentation(resourceID: session.resourceID),
                fallbackURL: media.coverURL
            )
        }
    }

}

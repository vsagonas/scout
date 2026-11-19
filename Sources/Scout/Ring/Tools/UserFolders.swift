import AppKit

// Where Scout saves what the user makes: screenshots (Pictures), screen recordings (Movies), voice memos (Music).
//
// The full edition uses the standard folders. The sandboxed App Store edition has the "assets" entitlements for
// Pictures, Movies and Music, which open the user's REAL folders, but the standard-directory APIs hand a sandboxed app
// the folders inside its own container. So there the real home is asked from the user database (not from HOME) and,
// if the real folder cannot be written for any reason, the container is the fallback (and "Show in Finder" still works).

enum UserFolders {
    /// The user's real home folder (inside the sandbox `NSHomeDirectory()` is the container).
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// A standard folder of the user (`.picturesDirectory`, `.moviesDirectory`, `.musicDirectory`).
    static func standard(_ directory: FileManager.SearchPathDirectory) -> URL {
        #if APPSTORE
        let name: String
        switch directory {
        case .picturesDirectory: name = "Pictures"
        case .moviesDirectory: name = "Movies"
        case .musicDirectory: name = "Music"
        case .desktopDirectory: name = "Desktop"
        case .downloadsDirectory: name = "Downloads"
        default: name = "Documents"
        }
        return realHome.appendingPathComponent(name, isDirectory: true)
        #else
        return FileManager.default.urls(for: directory, in: .userDomainMask)[0]
        #endif
    }

    /// `<standard folder>/<name>`, created on first use. If that cannot be written (sandbox, missing entitlement), a folder of
    /// the same name inside Scout's own support folder is used instead.
    static func saveFolder(_ directory: FileManager.SearchPathDirectory, named name: String) -> URL {
        let wanted = standard(directory).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: true)
        if FileManager.default.isWritableFile(atPath: wanted.path) { return wanted }
        return AppPaths.folder(name)
    }
}

import Foundation
import LaunchcheckCore

/// The files Launchwatch keeps: one for the sites, their state, the events and the settings,
/// one of pulse samples per site, and the latest audit report per site.
public final class Store: @unchecked Sendable {
    public let directory: URL
    private let fm = FileManager.default

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Launchwatch", isDirectory: true)
    }

    public init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
    }

    private var libraryFile: URL { directory.appendingPathComponent("library.json") }
    private func samplesFile(_ id: UUID) -> URL { directory.appendingPathComponent("samples/\(id.uuidString).json") }
    private func reportFile(_ id: UUID) -> URL { directory.appendingPathComponent("reports/\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func read<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) {
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(value) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public func loadLibrary() -> Library {
        read(Library.self, from: libraryFile) ?? Library()
    }

    public func save(_ library: Library) {
        write(library, to: libraryFile)
    }

    public func samples(for id: UUID) -> [Sample] {
        read([Sample].self, from: samplesFile(id)) ?? []
    }

    public func save(_ samples: [Sample], for id: UUID) {
        write(samples, to: samplesFile(id))
    }

    public func report(for id: UUID) -> Report? {
        read(Report.self, from: reportFile(id))
    }

    public func save(_ report: Report, for id: UUID) {
        write(report, to: reportFile(id))
    }

    /// Removes everything kept about a site.
    public func forget(_ id: UUID) {
        try? fm.removeItem(at: samplesFile(id))
        try? fm.removeItem(at: reportFile(id))
    }
}

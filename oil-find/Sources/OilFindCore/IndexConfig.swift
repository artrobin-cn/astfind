import Foundation
import COilFind

public struct IndexConfig {
    public var rootPath: String
    public var excludedPaths: [String] { didSet { rebuildExcludedBytes() } }
    public var excludedNames: Set<String> { didSet { excludedNameBytes = excludedNames.map { Array($0.utf8) } } }
    public var limitedMode: Bool
    public var userExcludedPaths: [String] { didSet { rebuildExcludedBytes() } }
    public var excludedExtensions: Set<String> { didSet { excludedExtensions = Set(Self.normalizeExtensions(excludedExtensions.sorted().joined(separator: " "))); rebuildExtensionKeys() } }
    private var excludedExtensionKeys: Set<UInt64> = []
    private struct ExtensionPattern { let parts: [[[UInt32]]] }
    private var excludedExtensionPatterns: [ExtensionPattern] = []
    public var hasExcludedExtensions: Bool { !excludedExtensions.isEmpty }
    public var indexDependencyDirs: Bool
    public var indexPackageContents: Bool
    public var indexUserLibrary: Bool
    public var indexSystemDirs: Bool
    static let dependencyNames = Set("node_modules site-packages .venv venv Pods DerivedData .git .svn .hg bower_components __pycache__ .gradle .cargo .rustup .npm .pnpm-store .yarn .cache .next .nuxt .build .swiftpm .tox .mypy_cache .pytest_cache .terraform".split(separator: " ").map(String.init))
    private static let dependencyBytes = dependencyNames.map { Array($0.utf8) }
    private let userLibraryBytes = Array((NSHomeDirectory() + "/Library").utf8)
    private static let systemBytes = Array("/System".utf8)
    private static let applicationsBytes = Array("/System/Applications".utf8)
    private static let systemRoots = ["/Library", "/usr", "/bin", "/sbin", "/private", "/opt"].map { Array($0.utf8) }
    var effectiveExcludedNames: Set<String> { indexDependencyDirs ? excludedNames : excludedNames.union(Self.dependencyNames) }
    private var excludedNameBytes: [[UInt8]]
    private var excludedPathBytes: [[UInt8]]
    private var userExcludedPathsBytes: [[UInt8]]
    private let restrictedBytes = ["Containers", "Group Containers", "Daemon Containers", "Mobile Documents", "CloudStorage"].map { Array((NSHomeDirectory() + "/Library/" + $0).utf8) }
    public init(rootPath: String = "/", excludedPaths: [String] = [], excludedNames: Set<String> = [], limitedMode: Bool = false, userExcludedPaths: [String] = [], indexDependencyDirs: Bool = false, indexPackageContents: Bool = false, indexUserLibrary: Bool = false, indexSystemDirs: Bool = false, excludedExtensions: Set<String> = []) {
        // Normalize components without Foundation's /private/var symlink rewriting.
        let absolute = rootPath.hasPrefix("/") ? rootPath : FileManager.default.currentDirectoryPath + "/" + rootPath
        var components: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        self.rootPath = "/" + components.joined(separator: "/")
        self.excludedExtensions = Set(Self.normalizeExtensions(excludedExtensions.sorted().joined(separator: " ")))
        self.excludedPaths = excludedPaths
        self.excludedNames = excludedNames
        self.limitedMode = limitedMode
        self.userExcludedPaths = userExcludedPaths
        self.indexDependencyDirs = indexDependencyDirs; self.indexPackageContents = indexPackageContents
        self.indexUserLibrary = indexUserLibrary; self.indexSystemDirs = indexSystemDirs
        self.excludedNameBytes = excludedNames.map { Array($0.utf8) }
        self.excludedPathBytes = excludedPaths.map { Array($0.utf8) }
        self.userExcludedPathsBytes = userExcludedPaths.map { Array($0.utf8) }
        rebuildExtensionKeys()
    }
    public static func standard(limited: Bool = false) -> IndexConfig {
        let home = NSHomeDirectory()
        var paths = ["/System/Volumes", "/Volumes", "/dev", "/cores", "/.vol", "/private/var/folders", "/private/var/db", "/private/var/vm", "/private/var/run", "/Library/Caches", "\(home)/Library/Caches", "\(home)/.Trash"]
        if limited { paths += ["Library/Containers", "Library/Group Containers", "Library/Daemon Containers", "Library/Mobile Documents", "Library/CloudStorage"].map { "\(home)/\($0)" } }
        return IndexConfig(excludedPaths: paths, excludedNames: Set(".Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems .Trashes .MobileBackups".split(separator: " ").map(String.init)), limitedMode: limited)
    }
    public var fingerprint: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        var parts = [rootPath, limitedMode ? "1" : "0", indexDependencyDirs ? "1" : "0", indexPackageContents ? "1" : "0", indexUserLibrary ? "1" : "0", indexSystemDirs ? "1" : "0"] + excludedPaths.sorted() + ["|"] + excludedNames.sorted() + ["|"] + userExcludedPaths.sorted()
        // Keep existing catalogs valid when no file types are excluded.
        parts += (excludedExtensions.isEmpty ? [] : ["extensions"] + excludedExtensions.sorted())
        for part in parts { for b in part.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }; h = (h ^ 0xff) &* 0x100000001b3 }
        return h
    }
    public var scopeFingerprint: UInt64 {
        var scope = self; scope.excludedExtensions = []
        return scope.fingerprint
    }
    // Catalog identity and relative exclusions remain stable after a volume rename.
    public func fingerprint(volumeUUID: String) -> UInt64 {
        var relative = self
        func canonical(_ path: String) -> String {
            if path == rootPath { return "/" }
            if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count)) }
            return path
        }
        relative.rootPath = "/volume/" + volumeUUID
        relative.excludedPaths = excludedPaths.map(canonical)
        relative.userExcludedPaths = userExcludedPaths.map(canonical)
        return relative.fingerprint
    }
    internal func filtersFiles(inDirectory path: UnsafeBufferPointer<UInt8>) -> Bool {
        (!indexSystemDirs && path.elementsEqual(Self.systemBytes))
            || (!indexUserLibrary && path.elementsEqual(userLibraryBytes))
    }
    public func isExcluded(path: UnsafeBufferPointer<UInt8>, isDirectory: Bool = true) -> Bool {
        exclusionReason(path: path, isDirectory: isDirectory) != nil || isBuiltInExcluded(path: path, isDirectory: isDirectory)
    }
    public func exclusionReason(path: UnsafeBufferPointer<UInt8>, isDirectory: Bool = true) -> CoverageReason? {
        for bytes in userExcludedPathsBytes where starts(path, with: bytes) { return .userExcluded }
        if limitedMode {
            for bytes in restrictedBytes where starts(path, with: bytes) { return .noAccess }
        }
        if !indexSystemDirs {
            for root in Self.systemRoots where starts(path, with: root) { return .system }
            if starts(path, with: Self.systemBytes), path.count > 8, !starts(path, with: Self.applicationsBytes) { return .system }
        }
        if !indexUserLibrary && starts(path, with: userLibraryBytes) && path.count > userLibraryBytes.count {
            let start = userLibraryBytes.count + 1
            var end = start
            while end < path.count && path[end] != 47 { end += 1 }
            let child = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: start), count: end - start)
            if !child.elementsEqual("Mobile Documents".utf8) && !child.elementsEqual("CloudStorage".utf8) { return .library }
        }
        var start = 0
        while start < path.count {
            if path[start] == 47 { start += 1; continue }
            var end = start
            while end < path.count && path[end] != 47 { end += 1 }
            let component = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: start), count: end - start)
            if (end < path.count || isDirectory) && !indexDependencyDirs && Self.dependencyBytes.contains(where: { component.elementsEqual($0) }) { return .dependency }
            if !indexPackageContents && end < path.count && Classifier.isPackageExtension(component) { return .packages }
            start = end
        }
        if !isDirectory && hasExcludedExtensions {
            let start = (path.lastIndex(of: 47) ?? -1) + 1
            let name = UnsafeBufferPointer(start: path.baseAddress?.advanced(by: start), count: path.count - start)
            if excludesFile(name: name) { return .fileType }
        }
        return nil
    }
    public static func normalizeExtensions(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" }).compactMap {
            let value = $0.drop(while: { $0 == "." }).lowercased().precomposedStringWithCanonicalMapping
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
    private mutating func rebuildExtensionKeys() {
        excludedExtensionKeys = []; excludedExtensionPatterns = []
        for ext in excludedExtensions {
            // Uppercase variants also cover Unicode expansions such as sharp S.
            for text in [ext, ext.uppercased().precomposedStringWithCanonicalMapping] {
                let bytes = Array(("." + text).utf8)
                let key = bytes.withUnsafeBufferPointer { Classifier.extensionKey($0) }
                if key != 0 { excludedExtensionKeys.insert(key) }
            }
            let parts = ext.map { character -> [[UInt32]] in
                let text = String(character)
                let forms = [text, text.uppercased(), text.lowercased()].flatMap {
                    [$0.precomposedStringWithCanonicalMapping, $0.decomposedStringWithCanonicalMapping]
                }
                var seen = Set<[UInt32]>()
                return forms.compactMap { form in
                    let folded = form.unicodeScalars.flatMap { scalar -> [UInt32] in
                        scalar.value == 0x130 ? [0x69, 0x307] : [Self.lowercaseScalar(scalar.value)]
                    }
                    return seen.insert(folded).inserted ? folded : nil
                }
            }
            excludedExtensionPatterns.append(ExtensionPattern(parts: parts))
        }
    }
    public func excludesFile(name: UnsafeBufferPointer<UInt8>) -> Bool {
        guard hasExcludedExtensions else { return false }
        let key = Classifier.extensionKey(name)
        if key != 0 { return excludedExtensionKeys.contains(key) }
        guard let dot = name.lastIndex(of: 46), dot + 1 < name.count else { return false }
        for pattern in excludedExtensionPatterns {
            var offset = dot + 1, matches = true
            for variants in pattern.parts {
                var matchedEnd: Int?
                for variant in variants {
                    if let end = Self.matchScalars(variant, in: name, from: offset) { matchedEnd = end; break }
                }
                guard let end = matchedEnd else { matches = false; break }
                offset = end
            }
            if matches && offset == name.count { return true }
        }
        return false
    }
    private static func matchScalars(_ expected: [UInt32], in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var offset = start, position = 0
        while position < expected.count {
            guard offset < bytes.count, let scalar = nextScalar(bytes, offset: &offset),
                  lowercaseScalar(scalar) == expected[position] else { return nil }
            position += 1
            if scalar == 0x130 {
                guard position < expected.count, expected[position] == 0x307 else { return nil }
                position += 1
            }
        }
        return offset
    }
    private static func lowercaseScalar(_ scalar: UInt32) -> UInt32 {
        if scalar < 128 { return scalar >= 65 && scalar <= 90 ? scalar + 32 : scalar }
        // Case data comes from the standard library: libc's locale tables differ between macOS
        // versions and miss pairs such as capital sharp S. A one-scalar mapping stays inline.
        guard let value = Unicode.Scalar(scalar),
              let lower = value.properties.lowercaseMapping.unicodeScalars.first?.value else { return scalar }
        return lower == 0x3c2 ? 0x3c3 : lower
    }
    private static func nextScalar(_ bytes: UnsafeBufferPointer<UInt8>, offset: inout Int) -> UInt32? {
        let first = bytes[offset]; offset += 1
        if first < 128 { return UInt32(first) }
        let remaining: Int, mask: UInt8
        switch first {
        case 0xc2...0xdf: remaining = 1; mask = 0x1f
        case 0xe0...0xef: remaining = 2; mask = 0x0f
        case 0xf0...0xf4: remaining = 3; mask = 0x07
        default: return nil
        }
        guard offset + remaining <= bytes.count else { return nil }
        var value = UInt32(first & mask)
        for _ in 0..<remaining {
            let next = bytes[offset]; offset += 1
            guard next & 0xc0 == 0x80 else { return nil }
            value = (value << 6) | UInt32(next & 0x3f)
        }
        return value
    }
    private func isBuiltInExcluded(path: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> Bool {
        for bytes in excludedPathBytes where starts(path, with: bytes) { return true }
        var start = 0
        while start < path.count {
            if path[start] == 47 { start += 1; continue }
            var end = start
            while end < path.count && path[end] != 47 { end += 1 }
            let component = UnsafeBufferPointer(start: path.baseAddress!.advanced(by: start), count: end - start)
            if (end < path.count || isDirectory) && excludedNameBytes.contains(where: { component.elementsEqual($0) }) { return true }
            start = end
        }
        return false
    }
    private func starts(_ path: UnsafeBufferPointer<UInt8>, with prefix: [UInt8]) -> Bool {
        (prefix == [47] && path.first == 47) || path.count >= prefix.count && path.prefix(prefix.count).elementsEqual(prefix)
            && (path.count == prefix.count || path[prefix.count] == 47)
    }
    private mutating func rebuildExcludedBytes() {
        excludedPathBytes = excludedPaths.map { Array($0.utf8) }
        userExcludedPathsBytes = userExcludedPaths.map { Array($0.utf8) }
    }
}

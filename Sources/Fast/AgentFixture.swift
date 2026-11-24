import Foundation
import CryptoKit

/// A native acceptance fixture is explicit, confined and never a consent grant.
enum AgentFixture {
    struct Artifact: Codable { let path: String; let sha256: String }
    struct Manifest: Codable {
        let schema: Int
        let world: String
        let home: String
        let executables: [String: Artifact]
        let metadata: [Artifact]
    }
    static var requested: Bool { ProcessInfo.processInfo.environment["YAB_AGENT_FIXTURE_MANIFEST"] != nil }
    static func discovery() -> Shell.Found? {
        let own = ProcessInfo.processInfo.environment
        guard Store.testing, own["YAB_TEST_CONTROL"] == "1", let world = Store.world,
              let outText = own["YAB_FARM_OUT"], let manifestText = own["YAB_AGENT_FIXTURE_MANIFEST"] else { return nil }
        let out = URL(fileURLWithPath: outText).standardizedFileURL.resolvingSymlinksInPath()
        func confined(_ path: String) -> URL? {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path == url.resolvingSymlinksInPath().path, url.path.hasPrefix(out.path + "/") else { return nil }
            return url
        }
        guard let manifestURL = confined(manifestText), let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.schema == 1, manifest.world == world,
              let home = confined(manifest.home), FileManager.default.fileExists(atPath: home.path),
              own["HOME"].map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == home.path,
              home.path != FileManager.default.homeDirectoryForCurrentUser.path else { return nil }
        func validated(_ artifact: Artifact) -> URL? {
            guard let file = confined(artifact.path), file.path.hasPrefix(home.path + "/"),
                  let data = try? Data(contentsOf: file), data.count < 1_048_576,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else { return nil }
            return file
        }
        var binaries: [String: String] = [:]
        for (cli, artifact) in manifest.executables {
            guard cli == "claude", let file = validated(artifact), FileManager.default.isExecutableFile(atPath: file.path) else { return nil }
            binaries[cli] = file.path
        }
        guard manifest.metadata.count == 1 else { return nil }
        for artifact in manifest.metadata {
            guard let file = validated(artifact), file.lastPathComponent == "claude-identity.json",
                  let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["oauthAccount"], let account = object["oauthAccount"] as? [String: String],
                  Set(account.keys).isSubset(of: ["emailAddress", "accountUuid"]) else { return nil }
        }
        let tmp = home.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let env = ["HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                   "TMPDIR": tmp.path, "CLAUDE_CONFIG_DIR": home.path, "CODEX_HOME": home.path + "/.codex",
                   "YAB_CONSENT_FIXTURE_LOG": home.path + "/cli.jsonl", "YAB_CONSENT_FIXTURE_IDENTITY": manifest.metadata[0].path]
        return Shell.Found(claude: binaries["claude"], codex: binaries["codex"], cursor: binaries["cursor"], gemini: binaries["gemini"], opencode: binaries["opencode"], env: env)
    }
}

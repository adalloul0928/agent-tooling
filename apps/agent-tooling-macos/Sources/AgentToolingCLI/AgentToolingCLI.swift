import AgentToolingCore
import Darwin
import Foundation

@main
struct AgentToolingCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeError("agent-tooling: \(error.localizedDescription)\n")
            Darwin.exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let remaining = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            printHelp()
        case "scan":
            try await scan(remaining)
        case "doctor":
            try await doctor(remaining)
        case "search":
            try search(remaining)
        case "request":
            try request(remaining)
        case "plan":
            try plan(remaining)
        case "apply":
            try await apply(remaining)
        case "export-diagnostics":
            try exportDiagnostics(remaining)
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func scan(_ arguments: [String]) async throws {
        let options = try CLIOptions(arguments: arguments, valueOptions: ["--home"])
        try options.requireNoPositionals()
        let homeURL = options.fileURL(for: "--home") ?? FileManager.default.homeDirectoryForCurrentUser
        let observations = await ClientAdapterRegistry().scanAll(homeURL: homeURL, runner: ProcessCommandRunner())
        try writeJSON(observations)
    }

    private static func doctor(_ arguments: [String]) async throws {
        let options = try CLIOptions(arguments: arguments, valueOptions: ["--home"], flagOptions: ["--json"])
        try options.requireNoPositionals()
        let homeURL = options.fileURL(for: "--home") ?? FileManager.default.homeDirectoryForCurrentUser
        let observations = await ClientAdapterRegistry().scanAll(homeURL: homeURL, runner: ProcessCommandRunner())
        let unavailable = observations.filter { !$0.isCommandAvailable }.map(\.surface)
        try writeJSON(
            DoctorReport(
                schemaVersion: IntegrationResponseLimits.schemaVersion,
                isHealthy: unavailable.isEmpty,
                unavailableTargets: unavailable,
                observations: observations
            ))
        if !unavailable.isEmpty { Darwin.exit(2) }
    }

    private static func search(_ arguments: [String]) throws {
        let options = try CLIOptions(
            arguments: arguments,
            valueOptions: ["--query", "--workspace", "--limit"],
            flagOptions: ["--json"]
        )
        try options.requireNoPositionals()
        let query = (options.value(for: "--query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= IntegrationResponseLimits.searchQueryMaximumCharacters,
            !IntegrationTextSanitizer.containsUnsupportedControlCharacter(query)
        else {
            throw CLIError.invalidValue("--query")
        }
        let limit: Int
        if let rawLimit = options.value(for: "--limit") {
            guard let parsedLimit = Int(rawLimit), (1...IntegrationResponseLimits.searchMaximumLimit).contains(parsedLimit) else {
                throw CLIError.invalidValue("--limit")
            }
            limit = parsedLimit
        } else {
            limit = IntegrationResponseLimits.searchDefaultLimit
        }
        let store = try WorkspaceStore(rootURL: options.fileURL(for: "--workspace"))
        let snapshot = try store.loadWorkspaceSnapshot() ?? WorkspaceSnapshot()
        try writeJSON(IntegrationSearchIndex.response(for: snapshot, query: query, limit: limit))
    }

    private static func request(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw CLIError.missingPositional("request type") }
        let remaining = Array(arguments.dropFirst())
        switch subcommand {
        case "create-skill":
            try createSkillRequest(remaining)
        default:
            throw CLIError.unknownRequest(subcommand)
        }
    }

    private static func createSkillRequest(_ arguments: [String]) throws {
        let options = try CLIOptions(
            arguments: arguments,
            valueOptions: ["--provider", "--scope", "--targets", "--project", "--name", "--workspace"],
            flagOptions: ["--instruction-stdin", "--json"]
        )
        try options.requireNoPositionals()
        guard options.value(for: "--provider") == "codex" else {
            throw CLIError.invalidProvider
        }
        guard options.contains("--instruction-stdin") else {
            throw CLIError.missingOption("--instruction-stdin")
        }
        let instruction =
            try BoundedInputReader.readUTF8(
                from: .standardInput,
                maximumBytes: CodexSkillDraftRequest.maximumInstructionBytes
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty,
            instruction.count <= CodexSkillDraftRequest.maximumInstructionCharacters,
            !IntegrationTextSanitizer.containsUnsupportedControlCharacter(instruction, allowsLineBreaks: true)
        else { throw CLIError.invalidInstruction }

        let scope: ToolingScope
        switch options.value(for: "--scope") {
        case "global", "user": scope = .user
        case "project": scope = .project
        default: throw CLIError.invalidValue("--scope")
        }

        guard let rawTargets = options.value(for: "--targets") else { throw CLIError.missingOption("--targets LIST") }
        guard let targets = IntegrationTextSanitizer.parseTargets(rawTargets) else { throw CLIError.invalidValue("--targets") }
        let proposedName: String?
        if let name = options.value(for: "--name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proposedName = try WorkspaceLibrary.normalizedIdentifier(name)
        } else {
            proposedName = nil
        }

        var projectRoot: String?
        if scope == .project {
            guard let rawProject = options.value(for: "--project") else {
                throw CLIError.missingOption("--project PATH")
            }
            let projectURL = URL(fileURLWithPath: rawProject, isDirectory: true).standardizedFileURL
            let values = try projectURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard projectURL.path(percentEncoded: false).hasPrefix("/"),
                projectURL.path(percentEncoded: false) != "/",
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { throw CLIError.invalidValue("--project") }
            projectRoot = projectURL.path(percentEncoded: false)
        } else if options.value(for: "--project") != nil {
            throw CLIError.invalidValue("--project")
        }

        let draftRequest = CodexSkillDraftRequest(
            instruction: instruction,
            proposedName: proposedName,
            scope: scope,
            projectRoot: projectRoot,
            targets: targets
        )
        let store = try WorkspaceStore(rootURL: options.fileURL(for: "--workspace"))
        try store.saveCodexSkillDraftRequest(draftRequest)
        try writeJSON(
            IntegrationRequestResponse(
                schemaVersion: IntegrationResponseLimits.schemaVersion,
                request: .init(id: draftRequest.id, state: "pending-review")
            ))
    }

    private static func plan(_ arguments: [String]) throws {
        let options = try CLIOptions(arguments: arguments, valueOptions: [])
        let planURL = try options.requireOnePositional(label: "plan file")
        let plan = try readPlan(at: URL(fileURLWithPath: planURL))
        try writeJSON(OperationPlanApproval.review(plan), prettyPrinted: true)
    }

    private static func apply(_ arguments: [String]) async throws {
        let options = try CLIOptions(
            arguments: arguments,
            valueOptions: ["--confirm", "--digest", "--workspace", "--home"]
        )
        let planPath = try options.requireOnePositional(label: "plan file")
        guard let confirmation = options.value(for: "--confirm"), let planID = UUID(uuidString: confirmation) else {
            throw CLIError.missingOption("--confirm <plan UUID>")
        }
        guard let digest = options.value(for: "--digest") else {
            throw CLIError.missingOption("--digest <reviewed SHA-256>")
        }
        let plan = try readPlan(at: URL(fileURLWithPath: planPath))
        try OperationPlanApproval.verify(plan, confirmedPlanID: planID, confirmedDigest: digest)
        let workspaceURL = options.fileURL(for: "--workspace")
        let homeURL = options.fileURL(for: "--home") ?? FileManager.default.homeDirectoryForCurrentUser
        let store = try WorkspaceStore(rootURL: workspaceURL)
        try store.saveEntity(plan, id: plan.id.uuidString, domain: .plans)
        let engine = OperationEngine(store: store, homeURL: homeURL)
        let receipt = await engine.execute(plan)
        try writeJSON(receipt, prettyPrinted: true)
        if receipt.state == .attention { Darwin.exit(3) }
    }

    private static func exportDiagnostics(_ arguments: [String]) throws {
        let options = try CLIOptions(arguments: arguments, valueOptions: ["--workspace", "--home", "--app-version"])
        let destinationPath = try options.requireOnePositional(label: "destination file")
        let workspaceURL = options.fileURL(for: "--workspace")
        let homeURL = options.fileURL(for: "--home") ?? FileManager.default.homeDirectoryForCurrentUser
        let store = try WorkspaceStore(rootURL: workspaceURL)
        let snapshot = try store.loadWorkspaceSnapshot() ?? WorkspaceSnapshot()
        let exporter = DiagnosticBundleExporter(homeURL: homeURL)
        let manifest = exporter.manifest(
            snapshot: snapshot,
            appVersion: options.value(for: "--app-version") ?? "development"
        )
        let destination = URL(fileURLWithPath: destinationPath)
        try exporter.export(manifest, to: destination)
        print(destination.standardizedFileURL.path(percentEncoded: false))
    }

    private static func readPlan(at url: URL) throws -> OperationPlan {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size >= 0,
            size <= 1_048_576
        else {
            throw CLIError.invalidPlanFile
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == size else { throw CLIError.invalidPlanFile }
        return try AgentToolingCoding.decoder().decode(OperationPlan.self, from: data)
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, prettyPrinted: Bool = false) throws {
        var data = try AgentToolingCoding.encoder(prettyPrinted: prettyPrinted).encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }

    private static func printHelp() {
        print(
            """
            Usage: agent-tooling <command> [options]

              scan [--home PATH]
              doctor [--home PATH]
              search [--query TEXT] [--limit 1...100] [--workspace PATH] [--json]
              request create-skill --provider codex --scope global|project --targets LIST --instruction-stdin [--project PATH]
              plan PLAN.json
              apply PLAN.json --confirm UUID --digest SHA256 [--workspace PATH] [--home PATH]
              export-diagnostics OUTPUT.json [--workspace PATH] [--home PATH] [--app-version VERSION]

            scan and doctor are read-only. apply accepts only a reviewed, digest-bound OperationPlan and executes it
            through the same policy-enforcing engine used by the macOS app.
            """)
    }
}

private struct CLIOptions {
    private var positionals: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(arguments: [String], valueOptions: Set<String>, flagOptions: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if flagOptions.contains(argument) {
                    guard !flags.contains(argument) else { throw CLIError.duplicateOption(argument) }
                    flags.insert(argument)
                    index += 1
                    continue
                }
                guard valueOptions.contains(argument), index + 1 < arguments.count else {
                    throw CLIError.unknownOrIncompleteOption(argument)
                }
                guard values[argument] == nil else { throw CLIError.duplicateOption(argument) }
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                positionals.append(argument)
                index += 1
            }
        }
    }

    func value(for option: String) -> String? { values[option] }
    func contains(_ option: String) -> Bool { flags.contains(option) }

    func fileURL(for option: String) -> URL? {
        value(for: option).map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    func requireNoPositionals() throws {
        guard positionals.isEmpty else { throw CLIError.unexpectedArguments }
    }

    func requireOnePositional(label: String) throws -> String {
        guard positionals.count == 1, let value = positionals.first else {
            throw CLIError.missingPositional(label)
        }
        return value
    }
}

private enum CLIError: LocalizedError {
    case unknownCommand(String)
    case unknownOrIncompleteOption(String)
    case duplicateOption(String)
    case missingOption(String)
    case missingPositional(String)
    case unexpectedArguments
    case invalidPlanFile
    case invalidValue(String)
    case invalidProvider
    case invalidInstruction
    case unknownRequest(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command): "Unknown command '\(command)'. Run agent-tooling help."
        case .unknownOrIncompleteOption(let option): "Unknown option or missing value for '\(option)'."
        case .duplicateOption(let option): "Option '\(option)' was provided more than once."
        case .missingOption(let option): "Required option missing: \(option)."
        case .missingPositional(let label): "Provide exactly one \(label)."
        case .unexpectedArguments: "This command does not accept positional arguments."
        case .invalidPlanFile: "The plan must be a regular, non-symlink JSON file no larger than 1 MB."
        case .invalidValue(let option): "The value for '\(option)' is invalid."
        case .invalidProvider: "Only the authenticated local Codex provider is supported for skill creation."
        case .invalidInstruction: "Provide a non-empty UTF-8 instruction no larger than 64 KB."
        case .unknownRequest(let request): "Unknown request type '\(request)'."
        }
    }
}

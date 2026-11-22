import StatsCore
@testable import StatsAdapters
import Foundation

@main enum NativeTestDriver {
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1) }
    }
    static func run() throws {
        var args = CommandLine.arguments
        var provider = Product.provider
        if let index = args.firstIndex(of:"--provider"), index + 1 < args.count {
            provider = args[index + 1]; args.removeSubrange(index...index + 1)
        }
        guard ["codex","kimi"].contains(provider) else {
            throw NSError(domain:"NativeTestDriver",code:1,userInfo:[NSLocalizedDescriptionKey:"Unknown provider: " + provider])
        }
        if args.count > 2, args[1] == "--restore-bridge" {
            try Lifecycle.restoreBridge(support:URL(fileURLWithPath:args[2])); return
        }
        if args.count > 2, args[1] == "--bridge" {
            let bridge = try KimiBridge(config:URL(fileURLWithPath:args[2]),changed:{})
            withExtendedLifetime(bridge) { dispatchMain() }
        }
        if args.count > 2, args[1] == "--watch" {
            let file = URL(fileURLWithPath:args[2])
            let log = IncrementalLog { () -> SessionMetrics in
                if provider == "codex" { return CodexMetrics() }
                return KimiMetrics()
            }
            while let line = readLine() {
                let command = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? JSONObject ?? [:]
                try emit(log.read(file,now:number(command["now"]) ?? 10000))
            }
            return
        }
        if args.count > 2, args[1] == "--scan" {
            let root = URL(fileURLWithPath:args[2]), selected = args.count > 3 ? args[3] : nil
            try emit(SessionReader(root:root,provider:StatsProvider(rawValue:provider)!).scan(selected:selected,now:10000).legacyJSON)
            return
        }
        if args.count > 2, args[1] == "--watch-catalog" {
            let root = URL(fileURLWithPath:args[2])
            let reader = SessionReader(root:root,provider:StatsProvider(rawValue:provider)!)
            while let line = readLine() {
                let command = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? JSONObject ?? [:]
                try emit(reader.scan(selected:command["selected"] as? String,now:number(command["now"]) ?? 10000).legacyJSON)
            }
            return
        }
        if args.count > 4, args[1] == "--scan-cache-parity" {
            // The reference scan never consults the cache. Each stored run builds a
            // fresh store from disk, so the second run must resume a serialized state
            // instead of re-reading the log from the start. "reset" starts from no
            // cache; "keep" resumes whatever a previous invocation left behind.
            let root = URL(fileURLWithPath:args[2]), cacheFile = URL(fileURLWithPath:args[3])
            if args[4] == "reset" { try? FileManager.default.removeItem(at:cacheFile) }
            let reference: JSONObject = SessionReader(root:root,provider:StatsProvider(rawValue:provider)!).scan(selected:nil,now:10000).legacyJSON
            var runs = [JSONObject](), restored = [Int](), parsed = [UInt64]()
            for _ in 0..<2 {
                let store = ParseCacheStore(path:cacheFile)
                let reader = SessionReader(root:root,provider:StatsProvider(rawValue:provider)!,cache:store)
                runs.append(reader.scan(selected:nil,now:10000).legacyJSON)
                restored.append(reader.restoredLogs)
                parsed.append(reader.parsedBytes)
                store.flush()
            }
            try emit(["cold":reference,"runs":runs,"restored":restored,"parsed":parsed]); return
        }
        let input = try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as? JSONObject ?? [:]
        if input["mode"] as? String == "metrics-timeline" {
            let metrics: SessionMetrics = input["provider"] as? String == "codex" ? CodexMetrics() : KimiMetrics()
            var snapshots = [JSONObject]()
            for action in input["actions"] as? [JSONObject] ?? [] {
                for record in action["records"] as? [JSONObject] ?? [] { metrics.accept(record) }
                if let issues = number(action["issues"]) { metrics.issues = Int(issues) }
                snapshots.append(metrics.snapshot(now: number(action["now"]) ?? 10000))
            }
            try emit(["snapshots": snapshots]); return
        }
        if input["mode"] as? String == "hook-record" {
            let support=URL(fileURLWithPath:input["support"] as? String ?? "")
            try emit(try Lifecycle.recordHook(input["payload"] as? JSONObject ?? [:],support:support));return
        }
        if input["mode"] as? String == "installed-kimi-root" {
            let home=URL(fileURLWithPath:input["home"] as? String ?? "")
            let support=URL(fileURLWithPath:input["support"] as? String ?? "")
            let launch=URL(fileURLWithPath:input["launch"] as? String ?? "")
            try emit(["root":Lifecycle.installedKimiRoot(home:home,support:support,launch:launch).path]);return
        }
        if input["mode"] as? String == "selection" {
            let state = KimiSelection(); var result = [JSONObject]()
            for action in input["actions"] as? [JSONObject] ?? [] {
                let now = number(action["now"]) ?? 0
                if action["disable"] as? Bool == true { state.disable() }
                let status = (action["data"] as? JSONObject).map { state.accept($0,now:now) } ?? 200
                result.append(["status":status,"selection":state.snapshot(now:now)])
            }
            try emit(["results":result]); return
        }
        let metrics: SessionMetrics
        switch input["provider"] as? String ?? provider {
        case "codex": metrics = CodexMetrics()
        default: metrics = KimiMetrics()
        }
        for record in input["records"] as? [JSONObject] ?? [] { metrics.accept(record) }
        try emit(metrics.snapshot(now:number(input["now"]) ?? 10000))
    }
    static func emit(_ value: JSONObject) throws {
        let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]); FileHandle.standardOutput.write(data+Data([10]))
    }
}

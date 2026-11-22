import StatsCore
import Foundation

// Kimi writes one record per spawned subagent or background process into the
// spawning agent's tasks/ directory. An agent-type record names the child
// directory it created, so it is the only local source for a subagent's task
// name, profile and model; state.json's agents map declares no name at all.
struct KimiTaskRecord {
    let taskId: String, kind: String, owner: String, agentId: String?
    let description: String?, status: String?, subagentType: String?, model: String?, thinkingEffort: String?
    let startedAt: Double
    var isRunning: Bool { status == "running" }
}

final class KimiSessionReader: ProviderSessionReading {
    let logs: SessionLogStore
    private var root: URL { logs.root }
    private let aggregation = SessionAggregation()
    private var groups: ProjectCatalog?
    private var groupsFingerprint: String?
    // Host task metadata is reused until its size or modification date changes.
    private var kimiTaskCache = [String: (size: Int, modified: Double, record: KimiTaskRecord?)]()
    init(root: URL, cache: ParseCacheStore? = nil) {
        logs = SessionLogStore(root: root, provider: .kimi, cache: cache) { _ in KimiMetrics() }
    }
    func scan(selected: String?, now: Double) -> StatsSnapshot {
        let groups = projectGroups()
        var agents = [JSONObject](), ledgers = [String: [JSONObject]](), livePaths = Set<String>()
        var ledgerVersions = [String: UsageLedgerVersion]()
        var kimiExtras = [String: JSONObject](), liveTaskFiles = Set<String>()
        for workspace in directories(root.appendingPathComponent("sessions")) {
            for directory in directories(workspace) {
                let stateFile=directory.appendingPathComponent("state.json"),stateInfo=try? stateFile.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
                let state=stateInfo?.isSymbolicLink == false && (stateInfo?.fileSize ?? Int.max)<=2*1024*1024 ? (try? Data(contentsOf:stateFile)).flatMap {try? JSONSerialization.jsonObject(with:$0) as? JSONObject} ?? [:]:[:]
                guard state["archived"] as? Bool != true else{continue}
                let sessionID=directory.lastPathComponent, taskKey=usageHash(workspace.lastPathComponent+"/"+sessionID)
                let project=usageProject(cwd:state["cwd"] ?? state["workDir"],workspace:workspace.lastPathComponent)
                let declared=jsonObject(state["agents"])
                let agentDirectories=directories(directory.appendingPathComponent("agents"))
                var agentIDs=Set(agentDirectories.map {$0.lastPathComponent})
                agentIDs.formUnion(declared.keys)
                agentIDs.insert("main")
                if FileManager.default.fileExists(atPath:directory.appendingPathComponent("wire.jsonl").path){agentIDs.insert("main")}
                let tasks=kimiTaskRecords(agentDirectories:agentDirectories,live:&liveTaskFiles)
                for agentID in agentIDs.sorted() where !agentID.contains("/") && agentID != "." && agentID != ".." {
                    var file=directory.appendingPathComponent("agents/\(agentID)/wire.jsonl")
                    if agentID == "main",!FileManager.default.fileExists(atPath:file.path){file=directory.appendingPathComponent("wire.jsonl")}
                    guard !FileManager.default.fileExists(atPath:file.path) || logs.safeLog(file) else{continue};livePaths.insert(file.path)
                    let loaded=try? logs.load(file,now:now,agentID:agentID),journal=loaded == nil ? nil:logs.journal(at: file)
                    var row=loaded ?? [:];let key=taskKey+":"+agentID
                    if loaded != nil { ledgerVersions[key] = logs.version(at: file) }
                    let declaredAgent=jsonObject(declared[agentID]),labels=jsonObject(declaredAgent["labels"]),owned=tasks.byOwner[agentID] ?? []
                    let parent=structuralText(declaredAgent["parentAgentId"]),task=tasks.identities[agentID]
                    // state.json normally declares no name for a subagent; the task
                    // record the parent wrote is the source for its human task name
                    // and profile. A declared name is retained, and a missing record
                    // falls back to the bounded swarm brief — never to label text.
                    let nickname=kimiLabel(declaredAgent["name"]) ?? kimiLabel(task?.description)
                        ?? kimiLabel(task?.subagentType) ?? kimiLabel(labels["swarmItem"])
                    let agentType=kimiLabel(task?.subagentType)
                    row.merge(["id":agentID == "main" ? sessionID:"__agent__:"+key,"key":key,"taskKey":taskKey,"sessionID":sessionID,"agentID":agentID,"nickname":nullable(nickname),"title":agentID == "main" ? SessionTitle.resolved(state["title"],id:sessionID):agentID,"group":groups.group(for:workspace.lastPathComponent),"project":project,"workspace":workspace.lastPathComponent,"provider":"kimi","role":agentID == "main" ? "main":"subagent","parentID":parent != agentID && parent.map(agentIDs.contains) == true ? parent as Any:jsonNull,"relationship":agentID == "main" ? "root":parent != agentID && parent.map(agentIDs.contains) == true ? "recorded":"unknown","agentType":nullable(agentType),"agentStatus":nullable(kimiLabel(task?.status,limit:32)),"agentEffort":nullable(kimiLabel(task?.thinkingEffort,limit:32)),"backgroundRunning":Double(owned.filter(\.isRunning).count),"backgroundTotal":Double(owned.count),"loaded":true,"accountingMode":journal?.mode ?? "missing","partial":loaded == nil || journal?.partial == true || (number(loaded?["malformedLines"]) ?? 0)>0]) {_,new in new}
                    // Only fill a model the wire log did not report; the log stays authoritative.
                    if SessionTitle.nonempty(row["model"]) == nil,let model=SessionTitle.nonempty(task?.model){row["model"]=model}
                    ledgers[key]=journal?.values ?? [];agents.append(row)
                }
                let running=tasks.processes.filter(\.isRunning).sorted {$0.startedAt > $1.startedAt}
                kimiExtras[sessionID]=["backgroundRunning":Double(running.count),"backgroundTotal":Double(tasks.processes.count),
                    "backgroundItems":running.prefix(6).map {kimiTaskSummary($0)}]
            }
        }
        logs.finishScan(livePaths: livePaths)
        kimiTaskCache = kimiTaskCache.filter { liveTaskFiles.contains($0.key) }
        var result = aggregation.aggregate(agents: agents, ledgers: ledgers, versions: ledgerVersions) { task, members in
            task["id"] = task["sessionID"]
            // A waiting count is only reported when the main agent's own log carries
            // it; a missing log must not turn into "nothing is waiting".
            let main=members.first {$0["role"] as? String == "main"},children=members.filter {$0["role"] as? String != "main"}
            for counter in ["pendingApprovals","pendingQuestions"] {
                task[counter]=main.flatMap {nonnegative($0[counter])}.map {$0+children.compactMap {nonnegative($0[counter])}.reduce(0,+)} ?? jsonNull
            }
            task["permissionMode"]=main?["permissionMode"] ?? jsonNull
            let extra=kimiExtras[identifier(task["sessionID"])]
            task["backgroundRunning"]=extra?["backgroundRunning"] ?? 0
            task["backgroundTotal"]=extra?["backgroundTotal"] ?? 0
            task["backgroundItems"]=extra?["backgroundItems"] ?? []
        }
        let counts=Dictionary(grouping:result.sessions,by:{identifier($0["sessionID"])}).mapValues(\.count)
        for i in result.sessions.indices where (counts[identifier(result.sessions[i]["sessionID"])] ?? 0)>1 {
            result.sessions[i]["id"]="__task__:"+identifier(result.sessions[i]["taskKey"])
            result.sessions[i]["title"]=identifier(result.sessions[i]["title"])+" · "+identifier(jsonObject(result.sessions[i]["group"])["title"])
        }
        return result.snapshot(provider: .kimi, now: now, groups: groups)
    }
    private func projectGroups() -> ProjectCatalog {
        let fingerprint = ProjectCatalog.fingerprint(root: root, provider: "kimi")
        if let groups, groupsFingerprint == fingerprint { return groups }
        let loaded = ProjectCatalog.kimi(root: root)
        groups = loaded; groupsFingerprint = fingerprint
        return loaded
    }
    private func directories(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { let values=try? $0.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);return values?.isDirectory == true && values?.isSymbolicLink != true }
    }
    // Task records are read from the host's own per-agent directories. Every file is
    // size- and symlink-checked, and a malformed record is skipped instead of
    // guessing an identity from its file name. A record whose size and modification
    // date are unchanged is reused, so a scan does not re-parse every host task.
    private func kimiTaskRecords(agentDirectories: [URL], live: inout Set<String>) -> (identities:[String:KimiTaskRecord], byOwner:[String:[KimiTaskRecord]], processes:[KimiTaskRecord]) {
        var identities=[String:KimiTaskRecord](), byOwner=[String:[KimiTaskRecord]](), processes=[KimiTaskRecord]()
        for agent in agentDirectories.prefix(256) {
            let owner=agent.lastPathComponent
            let files=((try? FileManager.default.contentsOfDirectory(at:agent.appendingPathComponent("tasks"),includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey],options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension == "json"}
            for file in files.prefix(1024) {
                let info=try? file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
                guard info?.isSymbolicLink != true,(info?.fileSize ?? Int.max) <= 128*1024 else{continue}
                live.insert(file.path)
                let size=info?.fileSize ?? -1, modified=info?.contentModificationDate?.timeIntervalSince1970 ?? -1
                let record: KimiTaskRecord?
                if let cached=kimiTaskCache[file.path],cached.size == size,cached.modified == modified { record=cached.record }
                else { record=kimiTaskRecord(file,owner:owner);kimiTaskCache[file.path]=(size,modified,record) }
                guard let record else{continue}
                byOwner[owner,default:[]].append(record)
                guard record.kind == "agent" else{processes.append(record);continue}
                // A resumed subagent can own several records; the newest names it.
                if let id=record.agentId,identities[id]==nil || (identities[id]?.startedAt ?? 0) <= record.startedAt{identities[id]=record}
            }
        }
        return (identities,byOwner,processes)
    }
    private func kimiTaskRecord(_ file: URL, owner: String)->KimiTaskRecord? {
        guard let data=try? Data(contentsOf:file),let object=(try? JSONSerialization.jsonObject(with:data)) as? JSONObject,
              let kind=object["kind"] as? String,["agent","process"].contains(kind),
              let taskId=structuralText(object["taskId"]),taskId.count <= 100 else{return nil}
        return KimiTaskRecord(taskId:taskId,kind:kind,owner:owner,agentId:structuralText(object["agentId"]),
            description:SessionTitle.nonempty(object["description"]),status:structuralText(object["status"]),
            subagentType:structuralText(object["subagentType"]),model:structuralText(object["model"]),
            thinkingEffort:structuralText(object["thinkingEffort"]),startedAt:nonnegative(object["startedAt"]) ?? 0)
    }
    private func kimiTaskSummary(_ record: KimiTaskRecord)->JSONObject {
        ["id":record.taskId,"owner":record.owner,"kind":record.kind,"status":record.status ?? "unknown",
         "description":record.description ?? record.taskId,"startedAt":record.startedAt]
    }
    // A swarm item is a whole task brief, not a name, and the one-line fallback for a
    // missing task record must never copy kilobytes of prompt text into every scan.
    private func kimiLabel(_ value: Any?, limit: Int = 60)->String? {
        guard let text=SessionTitle.nonempty(value) else{return nil}
        var label=text
        for separator in ["。","；",";"] {
            if let range=label.range(of:separator),label.distance(from:label.startIndex,to:range.lowerBound) <= limit {
                label=String(label[..<range.lowerBound]);break
            }
        }
        if label.count>limit{label=String(label.prefix(limit))}
        guard !label.isEmpty else{return nil}
        return label == text ? label:label+"…"
    }
}

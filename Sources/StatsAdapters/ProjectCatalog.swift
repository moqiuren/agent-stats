import StatsCore
import Foundation
import SQLite3

// Navigation groups reflect saved, named host projects. Filesystem paths and
// accounting buckets are deliberately not evidence of project membership.
struct ProjectCatalog {
    static let ungroupedID = StatsGroup.ungroupedID
    static var ungrouped: JSONObject { StatsGroup.ungrouped.json }
    var projects = [JSONObject]()
    var membership = [String:String]()
    func group(for session: String) -> JSONObject {
        guard let id=membership[session],let project=projects.first(where:{$0["id"] as? String == id}) else{return Self.ungrouped}
        return project
    }
    var groups: [JSONObject] { projects + [Self.ungrouped] }
    static func project(id: Any?, name: Any?) -> JSONObject? {
        guard let id=id as? String,!id.isEmpty,id != ungroupedID,
              let title=SessionTitle.nonempty(name) else{return nil}
        return ["id":id,"title":title]
    }
    static func readJSON(_ file: URL) -> JSONObject {
        guard let info=try? file.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]),
              info.isSymbolicLink == false,(info.fileSize ?? Int.max)<=16*1024*1024,
              let bytes=try? Data(contentsOf:file),let value=(try? JSONSerialization.jsonObject(with:bytes)) as? JSONObject else{return [:]}
        return value
    }
    // Identity of the files a catalog is derived from: names plus size and mtime. Both
    // providers rewrite them, so an unchanged fingerprint means the previous catalog is
    // still current. Reading it again would re-open the host database and re-parse its
    // desktop state on every scan, which also contends with a running host.
    static func fingerprint(root: URL, provider: String) -> String {
        let names: [String]
        if provider == "codex" {
            names = ((try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? [])
                .filter{$0.range(of:"^state_[0-9]+\\.sqlite$",options:.regularExpression) != nil}
                .sorted{$0.compare($1,options:.numeric) == .orderedDescending}
                + [".codex-global-state.json"]
        } else {
            names = ["projects.json", "workspaces.json"]
        }
        return names.map { name -> String in
            let file = root.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { return name+":absent" }
            return "\(name):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }.joined(separator:"|")
    }
    static func codex(root: URL) -> Self {
        let files=((try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? [])
            .filter{$0.range(of:"^state_[0-9]+\\.sqlite$",options:.regularExpression) != nil}
            .sorted{$0.compare($1,options:.numeric) == .orderedDescending}
        if let file=files.first {
            var db:OpaquePointer?
            if sqlite3_open_v2(root.appendingPathComponent(file).path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,nil)==SQLITE_OK {
                defer{sqlite3_close(db)}
                // A running host can hold the database briefly; a short timeout makes
                // named projects disappear until the next scan.
                sqlite3_busy_timeout(db,1000)
                var statement:OpaquePointer?
                if sqlite3_prepare_v2(db,"SELECT id,name FROM projects ORDER BY position,id",-1,&statement,nil)==SQLITE_OK {
                    var catalog=Self(),status=sqlite3_step(statement)
                    while status==SQLITE_ROW {
                        if let id=sqlite3_column_text(statement,0),let name=sqlite3_column_text(statement,1),
                           let project=project(id:String(cString:id),name:String(cString:name)){catalog.projects.append(project)}
                        status=sqlite3_step(statement)
                    }
                    sqlite3_finalize(statement);statement=nil
                    // A present authoritative table, including an empty one, never
                    // resurrects deleted projects from legacy desktop state.
                    guard status==SQLITE_DONE else{return Self()}
                    if sqlite3_prepare_v2(db,"SELECT id,project_id FROM threads WHERE project_id IS NOT NULL",-1,&statement,nil)==SQLITE_OK {
                        while sqlite3_step(statement)==SQLITE_ROW {
                            if let id=sqlite3_column_text(statement,0),let project=sqlite3_column_text(statement,1){catalog.membership[String(cString:id)]=String(cString:project)}
                        }
                    }
                    sqlite3_finalize(statement)
                    catalog.mergeSections(db:db)
                    catalog.mergePendingCodexMembership(root:root)
                    return catalog
                }
                sqlite3_finalize(statement)
            } else {sqlite3_close(db)}
        }
        let state=readJSON(root.appendingPathComponent(".codex-global-state.json"))
        var catalog=Self()
        let projects=state["local-projects"] as? [String:JSONObject] ?? [:]
        catalog.projects=projects.compactMap{project(id:$0.key,name:$0.value["name"])}.sorted{identifier($0["title"])<identifier($1["title"])}
        let projectless=Set(state["projectless-thread-ids"] as? [String] ?? [])
        for (id,value) in state["thread-project-assignments"] as? [String:JSONObject] ?? [:] where !projectless.contains(id) {
            if let project=value["projectId"] as? String {catalog.membership[id]=project}
        }
        return catalog
    }
    // Host sections (Pinned and user-named groups) are the explicit grouping the
    // current desktop writes instead of threads.project_id. They join the
    // navigation list and only claim threads no project assignment already owns.
    private mutating func mergeSections(db: OpaquePointer?) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db,"SELECT id,name FROM thread_sections ORDER BY name,id",-1,&statement,nil)==SQLITE_OK {
            while sqlite3_step(statement)==SQLITE_ROW {
                if let id=sqlite3_column_text(statement,0),let name=sqlite3_column_text(statement,1),
                   let section=Self.project(id:String(cString:id),name:String(cString:name)){projects.append(section)}
            }
        }
        sqlite3_finalize(statement);statement=nil
        if sqlite3_prepare_v2(db,"SELECT id,thread_section_id FROM threads WHERE thread_section_id IS NOT NULL",-1,&statement,nil)==SQLITE_OK {
            while sqlite3_step(statement)==SQLITE_ROW {
                if let id=sqlite3_column_text(statement,0),let section=sqlite3_column_text(statement,1) {
                    let tid=String(cString:id),sid=String(cString:section)
                    if membership[tid]==nil,projects.contains(where:{$0["id"] as? String==sid}){membership[tid]=sid}
                }
            }
        }
        sqlite3_finalize(statement)
    }
    private mutating func mergePendingCodexMembership(root:URL) {
        let state=Self.readJSON(root.appendingPathComponent(".codex-global-state.json"))
        let host="local:"+root.path
        let migration=jsonObject(jsonObject(state["app-server-projects-migration-by-host"])[host])
        // Desktop may have migrated project names before thread membership. Only
        // explicitly pending assignments can supplement the new authoritative DB.
        guard migration["projectsMigrated"] as? Bool == true,
              migration["threadAssignmentsMigrated"] as? Bool == false else{return}
        let pending=Set(migration["pendingThreadAssignmentIds"] as? [String] ?? [])
        let projectless=Set(state["projectless-thread-ids"] as? [String] ?? [])
        let mapping=jsonObject(jsonObject(state["app-server-project-id-by-legacy-project-id-by-host"])[host])
        let hosts=state["thread-project-membership-host-ids"] as? [String:String] ?? [:]
        let known=Set(projects.compactMap{$0["id"] as? String})
        for (id,assignment) in state["thread-project-assignments"] as? [String:JSONObject] ?? [:] {
            guard pending.contains(id),!projectless.contains(id),membership[id]==nil,
                  hosts[id]==nil || hosts[id]=="local",assignment["projectKind"] as? String == "local",
                  let legacyID=assignment["projectId"] as? String,
                  let currentID=mapping[legacyID] as? String,known.contains(currentID) else{continue}
            membership[id]=currentID
        }
    }
    static func kimi(root: URL) -> Self {
        func build(from value: JSONObject, entriesKey: String, deletedKey: String) -> Self {
            let removed = Set(value[deletedKey] as? [String] ?? [])
            var catalog = Self()
            for (id, entry) in value[entriesKey] as? [String: JSONObject] ?? [:] where !removed.contains(id) {
                if let project = project(id: id, name: entry["name"]) {
                    catalog.projects.append(project)
                    catalog.membership[id] = id
                }
            }
            catalog.projects.sort { identifier($0["title"]) < identifier($1["title"]) }
            return catalog
        }
        let projectsFile = root.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: projectsFile.path) {
            let value = readJSON(projectsFile)
            if value["projects"] is [String: JSONObject] {
                return build(from: value, entriesKey: "projects", deletedKey: "deleted_project_ids")
            }
        }
        return build(from: readJSON(root.appendingPathComponent("workspaces.json")),
                     entriesKey: "workspaces", deletedKey: "deleted_workspace_ids")
    }
}

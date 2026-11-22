import StatsCore
import Foundation

// JSON stays inside the existing accounting engine in this stage. Its output is
// converted once into StatsSnapshot before crossing the collection boundary.
struct AggregatedSessions {
    var sessions: [JSONObject]
    let agents: [JSONObject]
    let projects: [JSONObject]

    func snapshot(provider: StatsProvider, now: Double, groups: ProjectCatalog) -> StatsSnapshot {
        StatsSnapshot(provider: provider, collectedAt: now,
                      sessions: sessions.map(SessionSnapshot.init),
                      agents: agents.map(AgentSnapshot.init),
                      projects: projects.map(ProjectSnapshot.init),
                      groups: groups.groups.map(SessionGroupSnapshot.init),
                      coverageNote: UsageAccounting.boundary)
    }
}

final class SessionAggregation {
    private let accounting = UsageResolutionCache()
    func aggregate(agents source: [JSONObject], ledgers: [String: [JSONObject]],
                   versions ledgerVersions: [String: UsageLedgerVersion],
                   decorateSession: (inout JSONObject, [JSONObject]) -> Void = { _, _ in }) -> AggregatedSessions {
        var agents = source
        let resolved=accounting.resolve(agents,ledgers:ledgers,versions:ledgerVersions)
        for i in agents.indices {
            let key=identifier(agents[i]["key"])
            if agents[i]["accountingMode"] as? String == "requests" {UsageAccounting.apply(resolved.totals[key] ?? [:],to:&agents[i])}
            else if agents[i]["accountingMode"] as? String == "missing" {for key in UsageAccounting.counters {agents[i][key]=jsonNull}}
            if let input=nonnegative(agents[i]["input"]),let read=nonnegative(agents[i]["cacheRead"]),let write=nonnegative(agents[i]["cacheWrite"]),input+read+write>0{
                agents[i]["cacheHit"]=read*100/(input+read+write)
            }else{agents[i]["cacheHit"]=jsonNull}
            agents[i]["sharedHistoryTokens"]=(resolved.rawTokens[key] ?? 0)-(number(resolved.totals[key]?["totalTokens"]) ?? 0)
        }
        var tasks=[JSONObject]()
        for (taskKey,members) in Dictionary(grouping:agents,by:{identifier($0["taskKey"])}) {
            var task=members.first {identifier($0["key"]) == taskKey || $0["role"] as? String == "main"} ?? members[0]
            task["ownTokens"]=task["totalTokens"] ?? jsonNull
            let shared=resolved.sharedByTask[taskKey] ?? []
            let localShared=shared.filter {($0["taskKeys"] as? [String])?.count == 1}
            task.merge(UsageAccounting.aggregate(members,extra:localShared)) {_,new in new}
            task["agents"]=members;task["sharedHistoryTokens"]=sum(shared,"totalTokens")
            if shared.count>localShared.count {task["coverageNote"]=identifier(task["coverageNote"])+" 跨任务共享历史仅计入项目合计，未猜测归属到本任务。"}
            decorateSession(&task, members)
            task["updatedAt"]=members.compactMap {number($0["updatedAt"])}.max() ?? 0
            if task["relationship"] as? String == "unknown" {task["title"]="父任务未知 · "+identifier(task["title"])}
            tasks.append(task)
        }
        tasks.sort {(number($0["updatedAt"]) ?? 0)>(number($1["updatedAt"]) ?? 0)}
        return AggregatedSessions(sessions: tasks, agents: agents,
                                  projects: UsageAccounting.projects(agents, shared: resolved.shared))
    }
}

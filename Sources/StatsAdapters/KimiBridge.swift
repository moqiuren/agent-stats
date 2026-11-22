import Foundation
import Network
import StatsCore

package final class KimiSelection {
  private var current: JSONObject?, disabled = false
  package func snapshot(now: Double) -> JSONObject {
    if let current, !disabled, now - (number(current["updatedAt"]) ?? 0) < 8000 {
      return [
        "status": "connected", "known": current["known"] ?? false,
        "sessionId": current["sessionId"] ?? jsonNull, "updatedAt": current["updatedAt"] ?? now,
        "focused": current["focused"] ?? false, "visible": current["visible"] ?? false,
      ]
    }
    return ["status": disabled ? "disabled" : "waiting", "known": false, "sessionId": jsonNull]
  }
  package func disable() {
    disabled = true
    current = nil
  }
  package func accept(_ data: JSONObject, now: Double) -> Int {
    if disabled { return 410 }
    let allowed: Set<String> = ["clientId", "known", "sessionId", "focused", "visible"]
    func isBool(_ key: String) -> Bool {
      guard let n = data[key] as? NSNumber else { return false }
      return String(cString: n.objCType) == "c"
    }
    let id = data["sessionId"]
    guard Set(data.keys).isSubset(of: allowed), let client = data["clientId"] as? String,
      client.count <= 100,
      ["known", "focused", "visible"].allSatisfy(isBool),
      id is NSNull
        || ((id as? String)?.range(
          of: "^session_[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil)
    else { return 400 }
    if current == nil || data["focused"] as? Bool == true
      || client == current?["clientId"] as? String
      || now - (number(current?["updatedAt"]) ?? 0) > 8000
    {
      current = data
      current?["updatedAt"] = now
    }
    return 204
  }
}

package final class KimiBridge {
  private let queue: DispatchQueue
  private let clock: StatsClock
  private let scheduler: StatsScheduling
  private let uiScheduler: StatsScheduling
  private var retryTask: StatsCancellation?
  private var timeouts = [ObjectIdentifier: StatsCancellation]()
  private var listener: NWListener?, connections = [ObjectIdentifier: NWConnection](),
    state = KimiSelection(), error: String?
  private var stopped = false, retryCount = 0
  private let key: [UInt8]
  private let port: NWEndpoint.Port
  private let changed: () -> Void
  package init(
    config: URL, clock: StatsClock = SystemStatsClock(), scheduler: StatsScheduling? = nil,
    uiScheduler: StatsScheduling = DispatchStatsScheduler(queue: .main),
    changed: @escaping () -> Void
  ) throws {
    let queue = DispatchQueue(label: "kimi.stats.bridge")
    self.queue = queue
    self.clock = clock
    self.uiScheduler = uiScheduler
    self.scheduler = scheduler ?? DispatchStatsScheduler(queue: queue)
    let object =
      try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? JSONObject ?? [:]
    guard let rawPort = number(object["port"]), rawPort.rounded() == rawPort, rawPort > 0,
      rawPort <= 65535,
      let port = NWEndpoint.Port(rawValue: UInt16(rawPort)), let secret = object["key"] as? String,
      !secret.isEmpty
    else {
      throw NSError(domain: "KimiBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "桥接配置无效"])
    }
    key = Array(secret.utf8)
    self.changed = changed
    self.port = port
    queue.async { self.listen() }
  }
  private func listen() {
    guard !stopped else { return }
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
    do {
      let listener = try NWListener(using: params)
      self.listener = listener
      listener.stateUpdateHandler = { [weak self, weak listener] value in
        guard let self, let listener, self.listener === listener else { return }
        if case .failed(let error) = value { self.retry(error) }
        if case .ready = value {
          self.error = nil
          self.retryCount = 0
          self.uiScheduler.execute { self.changed() }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in self?.connect(connection) }
      listener.start(queue: queue)
    } catch { retry(error) }
  }
  private func retry(_ error: Error) {
    guard !stopped else { return }
    self.error = error.localizedDescription
    listener?.cancel()
    listener = nil
    FileHandle.standardError.write(
      Data(("Bridge listener unavailable; retrying: " + error.localizedDescription + "\n").utf8))
    uiScheduler.execute { [weak self] in self?.changed() }
    retryCount += 1
    let delay = min(15.0, pow(2.0, Double(min(retryCount - 1, 4))))
    retryTask?.cancel()
    retryTask = scheduler.schedule(after: delay, repeating: nil, tolerance: 0) { [weak self] in
      self?.listen()
    }
  }
  package func snapshot() -> JSONObject {
    queue.sync {
      if let error {
        return ["status": "error", "known": false, "sessionId": jsonNull, "error": error]
      }
      return state.snapshot(now: clock.milliseconds)
    }
  }
  package func stop() {
    queue.async {
      self.stopped = true
      self.listener?.cancel()
      self.connections.values.forEach { $0.cancel() }
      self.connections.removeAll()
      self.retryTask?.cancel()
      self.timeouts.values.forEach { $0.cancel() }
      self.timeouts.removeAll()
    }
  }
  private func connect(_ connection: NWConnection) {
    guard connections.count < 16 else {
      connection.cancel()
      return
    }
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] value in
      if case .cancelled = value {
        self?.connections[id] = nil
        self?.timeouts.removeValue(forKey: id)?.cancel()
      }
      if case .failed = value {
        connection?.cancel()
        self?.connections[id] = nil
        self?.timeouts.removeValue(forKey: id)?.cancel()
      }
    }
    connection.start(queue: queue)
    receive(connection, buffer: Data())
    timeouts[id] = scheduler.schedule(after: 5, repeating: nil, tolerance: 0) { [weak self] in
      if self?.connections[id] != nil { connection.cancel() }
    }
  }
  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      guard error == nil else {
        connection.cancel()
        return
      }
      if buffer.count > 9216 {
        self.respond(connection, status: 413)
        return
      }
      guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        if buffer.count > 8192 || complete {
          self.respond(connection, status: 400)
        } else {
          self.receive(connection, buffer: buffer)
        }
        return
      }
      guard let text = String(data: buffer[..<split.lowerBound], encoding: .utf8) else {
        self.respond(connection, status: 400)
        return
      }
      let lines = text.components(separatedBy: "\r\n")
      let request = lines[0].split(separator: " ")
      guard request.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(request[2])) else {
        self.respond(connection, status: 400)
        return
      }
      var headers = [String: String]()
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else {
          self.respond(connection, status: 400)
          return
        }
        let name = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard headers[name] == nil else {
          self.respond(connection, status: 400)
          return
        }
        headers[name] = value
      }
      guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"),
        length >= 0
      else {
        self.respond(connection, status: 400)
        return
      }
      if length > 1024 {
        self.respond(connection, status: 413)
        return
      }
      let body = buffer[split.upperBound...]
      if body.count < length {
        if complete {
          self.respond(connection, status: 400)
        } else {
          self.receive(connection, buffer: buffer)
        }
        return
      }
      self.handle(
        connection, method: String(request[0]), path: String(request[1]), headers: headers,
        body: Data(body.prefix(length)))
    }
  }
  private func handle(
    _ connection: NWConnection, method: String, path: String, headers: [String: String], body: Data
  ) {
    let origin = headers["origin"]
    guard origin == nil || origin == "app://renderer" else {
      respond(connection, status: 403)
      return
    }
    var responseHeaders = ["Cache-Control": "no-store"]
    if let origin {
      responseHeaders["Access-Control-Allow-Origin"] = origin
      responseHeaders["Vary"] = "Origin"
    }
    if method == "OPTIONS" {
      guard origin == "app://renderer" else {
        respond(connection, status: 403)
        return
      }
      responseHeaders.merge([
        "Access-Control-Allow-Methods": "POST",
        "Access-Control-Allow-Headers": "content-type,x-agent-stats-key",
        "Access-Control-Allow-Private-Network": "true",
      ]) { _, new in new }
      respond(connection, status: 204, headers: responseHeaders)
      return
    }
    guard method == "POST", ["/kimi-selection", "/state", "/disable"].contains(path) else {
      respond(connection, status: 404, headers: responseHeaders)
      return
    }
    let candidate = Array((headers["x-agent-stats-key"] ?? "").utf8)
    guard candidate.count == key.count else {
      respond(connection, status: 401, headers: responseHeaders)
      return
    }
    let mismatch = zip(candidate, key).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
    guard mismatch == 0 else {
      respond(connection, status: 401, headers: responseHeaders)
      return
    }
    let now = clock.milliseconds
    if path == "/state" {
      responseHeaders["Content-Type"] = "application/json"
      respond(
        connection, status: 200, headers: responseHeaders,
        body: (try? JSONSerialization.data(withJSONObject: state.snapshot(now: now))) ?? Data())
      return
    }
    if path == "/disable" {
      state.disable()
      uiScheduler.execute { self.changed() }
      respond(connection, status: 200, headers: responseHeaders)
      return
    }
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? JSONObject else {
      respond(connection, status: 400, headers: responseHeaders)
      return
    }
    let status = state.accept(object, now: now)
    if status == 204 { uiScheduler.execute { self.changed() } }
    respond(connection, status: status, headers: responseHeaders)
  }
  private func respond(
    _ connection: NWConnection, status: Int, headers: [String: String] = [:], body: Data = Data()
  ) {
    var text =
      "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode:status))\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
    for (key, value) in headers { text += "\(key): \(value)\r\n" }
    text += "\r\n"
    connection.send(
      content: Data(text.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}

// The compatibility renderer keeps sending heartbeats while another provider is
// selected. Its listener belongs to the unified app, not a replaceable collector.
package final class KimiBridgeRuntime: PageSelectionBridging {
  private let config: URL
  private let clock: StatsClock
  private let lock = NSLock()
  private var bridge: KimiBridge?, error: String?, started = false
  package init(
    config: URL = Product.support.appendingPathComponent("kimi-bridge/connection.json"),
    clock: StatsClock = SystemStatsClock()
  ) {
    self.config = config
    self.clock = clock
  }
  // A missing configuration is retried on later snapshots: installing or
  // restoring the bridge after launch must not need an app restart. A broken
  // configuration is terminal for this process and never retried.
  package func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !started else { return }
    guard FileManager.default.fileExists(atPath: config.path) else { return }
    started = true
    do { bridge = try KimiBridge(config: config, clock: clock, changed: {}) } catch {
      self.error = error.localizedDescription
    }
  }
  package func snapshot() -> PageSessionSelection {
    start()
    lock.lock()
    defer { lock.unlock() }
    if let error {
      return PageSessionSelection([
        "status": "error", "known": false, "sessionId": jsonNull, "error": error,
      ])
    }
    return PageSessionSelection(
      bridge?.snapshot() ?? ["status": "not_installed", "known": false, "sessionId": jsonNull])
  }
  package func stop() {
    lock.lock()
    defer { lock.unlock() }
    bridge?.stop()
  }
}

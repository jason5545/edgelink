#!/usr/bin/env node
import crypto from "node:crypto";
import dgram from "node:dgram";
import net from "node:net";

const DEFAULT_CONTROL_PORT = 17104;
const DEFAULT_PUBLIC_HOST = "172.238.24.219";
const DEFAULT_WORKER_BASE_URL = "https://edgelink-worker.black-hill-f944.workers.dev";
const DEFAULT_PORT_BASE = 18000;
const DEFAULT_SLOT_COUNT = 20;
const PORTS_PER_SESSION = 8;
const SESSION_TTL_MS = 2 * 60 * 1000;

const config = {
  controlPort: intEnv("EDGELINK_CALL_RELAY_CONTROL_PORT", DEFAULT_CONTROL_PORT),
  publicHost: process.env.EDGELINK_CALL_RELAY_PUBLIC_HOST || DEFAULT_PUBLIC_HOST,
  workerBaseUrl: (process.env.EDGELINK_WORKER_BASE_URL || DEFAULT_WORKER_BASE_URL).replace(/\/$/, ""),
  portBase: intEnv("EDGELINK_CALL_RELAY_PORT_BASE", DEFAULT_PORT_BASE),
  slotCount: intEnv("EDGELINK_CALL_RELAY_SLOT_COUNT", DEFAULT_SLOT_COUNT)
};

const activeSessions = new Map();
const occupiedSlots = new Set();

const controlServer = net.createServer((socket) => {
  socket.setKeepAlive(true, 15_000);
  new ControlConnection(socket).start();
});

controlServer.listen(config.controlPort, "0.0.0.0", () => {
  log("info", "call_relayd.control_ready", {
    port: config.controlPort,
    publicHost: config.publicHost,
    portBase: config.portBase,
    slotCount: config.slotCount
  });
});

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

function shutdown() {
  log("info", "call_relayd.shutdown", {});
  controlServer.close();
  for (const session of activeSessions.values()) {
    session.close("shutdown");
  }
  setTimeout(() => process.exit(0), 250).unref();
}

class ControlConnection {
  constructor(socket) {
    this.socket = socket;
    this.buffer = "";
    this.session = null;
    this.role = "owner";
    this.remote = `${socket.remoteAddress}:${socket.remotePort}`;
  }

  start() {
    log("info", "control.connected", { remote: this.remote });
    this.socket.on("data", (data) => this.receive(data));
    this.socket.on("close", () => this.close("control_closed"));
    this.socket.on("error", (error) => {
      log("warn", "control.error", { remote: this.remote, error: error.message });
      this.close("control_error");
    });
  }

  receive(data) {
    this.buffer += data.toString("utf8");
    while (true) {
      const index = this.buffer.indexOf("\n");
      if (index < 0) {
        break;
      }
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (line.length > 0) {
        void this.handleLine(line);
      }
    }
  }

  async handleLine(line) {
    let envelope;
    try {
      envelope = JSON.parse(line);
    } catch {
      this.send("error", { error: "invalid_json" });
      return;
    }

    switch (envelope.t) {
      case "hello":
        await this.handleHello(envelope.b);
        break;
      case "source.rtp":
        this.session?.sendSourceRTP(envelope.b);
        break;
      case "bridge.rtp":
        this.session?.receiveBridgeRTP(envelope.b, this);
        break;
      case "bridge.status":
        log("info", "bridge.status", { remote: this.remote, sessionId: this.session?.sessionId, ...safeLogBody(envelope.b) });
        break;
      case "session.close":
        this.close("client_close");
        break;
      default:
        this.send("error", { error: "unsupported_message", type: envelope.t });
    }
  }

  async handleHello(body) {
    if (this.session) {
      this.send("error", { error: "session_already_started" });
      return;
    }
    const role = body?.role === "android.bridge" || typeof body?.sessionId === "string" ? "android.bridge" : "owner";
    const auth = await verifyRelayAuth(body).catch((error) => ({ ok: false, error: error.message }));
    if (!auth.ok) {
      log("warn", "control.auth_failed", { remote: this.remote, error: auth.error });
      this.send("error", { error: "auth_failed", detail: auth.error });
      this.socket.end();
      return;
    }

    if (role === "android.bridge") {
      this.handleBridgeHello(body);
      return;
    }

    const slot = allocateSlot();
    if (slot == null) {
      this.send("error", { error: "no_free_slots" });
      this.socket.end();
      return;
    }

    const session = new RelaySession({
      slot,
      deviceId: body.deviceId,
      control: this,
      publicHost: config.publicHost,
      portBase: config.portBase + slot * PORTS_PER_SESSION
    });
    this.session = session;
    this.role = "owner";
    activeSessions.set(session.sessionId, session);

    try {
      await session.start();
      this.send("session.ready", session.publicDescriptor());
    } catch (error) {
      log("error", "session.start_failed", { slot, error: error.message });
      session.close("start_failed");
      this.send("error", { error: "session_start_failed", detail: error.message });
      this.socket.end();
    }
  }

  handleBridgeHello(body) {
    const sessionId = typeof body?.sessionId === "string" ? body.sessionId : "";
    const session = activeSessions.get(sessionId);
    if (!session || session.closed) {
      this.send("error", { error: "session_not_found", sessionId });
      this.socket.end();
      return;
    }
    this.session = session;
    this.role = "android.bridge";
    session.attachBridge(this, body);
  }

  send(type, body) {
    if (this.socket.destroyed) {
      return;
    }
    this.socket.write(JSON.stringify({ t: type, b: body }) + "\n");
  }

  close(reason) {
    if (this.session) {
      if (this.role === "android.bridge") {
        this.session.detachBridge(this, reason);
      } else {
        this.session.close(reason);
      }
      this.session = null;
    }
  }
}

class RelaySession {
  constructor({ slot, deviceId, control, publicHost, portBase }) {
    this.slot = slot;
    this.deviceId = deviceId;
    this.control = control;
    this.publicHost = publicHost;
    this.sessionId = crypto.randomUUID();
    this.rtspPort = portBase;
    this.sinkRtpPort = portBase + 1;
    this.sinkRtcpPort = portBase + 2;
    this.sourceRtpPort = portBase + 3;
    this.sourceRtcpPort = portBase + 4;
    this.rtspServer = null;
    this.udpSockets = new Map();
    this.rtspConnections = new Set();
    this.bridgeControls = new Set();
    this.sourceDestination = null;
    this.sinkRtpPacketCount = 0;
    this.sourceRtpPacketCount = 0;
    this.bridgeSinkRtpPacketCount = 0;
    this.bridgeSourceRtpPacketCount = 0;
    this.closed = false;
    this.expiresAt = Date.now() + SESSION_TTL_MS;
    this.ttlTimer = setTimeout(() => this.close("ttl_expired"), SESSION_TTL_MS).unref();
  }

  async start() {
    this.rtspServer = net.createServer((socket) => {
      socket.setKeepAlive(true, 15_000);
      const connection = new RTSPConnection(this, socket);
      this.rtspConnections.add(connection);
      connection.start();
    });
    await listenTCP(this.rtspServer, this.rtspPort);
    await Promise.all([
      this.bindUDP(this.rtspPort),
      this.bindUDP(this.sinkRtpPort),
      this.bindUDP(this.sinkRtcpPort),
      this.bindUDP(this.sourceRtpPort),
      this.bindUDP(this.sourceRtcpPort)
    ]);
    log("info", "session.ready", this.publicDescriptor());
  }

  publicDescriptor() {
    return {
      sessionId: this.sessionId,
      relayHost: this.publicHost,
      relayPort: this.rtspPort,
      relayControlPort: config.controlPort,
      sinkRtpPort: this.sinkRtpPort,
      sourceRtpPort: this.sourceRtpPort,
      expiresAt: Math.floor(this.expiresAt / 1000)
    };
  }

  attachBridge(control, body) {
    this.bridgeControls.add(control);
    log("info", "bridge.attached", {
      sessionId: this.sessionId,
      remote: control.remote,
      deviceId: body?.deviceId,
      localRtspHost: body?.localRtspHost,
      localRtspPort: body?.localRtspPort
    });
    control.send("bridge.ready", this.publicDescriptor());
  }

  detachBridge(control, reason) {
    if (!this.bridgeControls.delete(control)) {
      return;
    }
    log("info", "bridge.detached", { sessionId: this.sessionId, remote: control.remote, reason });
  }

  bindUDP(port) {
    return new Promise((resolve, reject) => {
      const socket = dgram.createSocket("udp4");
      socket.on("message", (message, rinfo) => this.handleUDP(port, message, rinfo));
      socket.on("error", (error) => {
        log("warn", "udp.error", { sessionId: this.sessionId, port, error: error.message });
      });
      socket.bind(port, "0.0.0.0", () => {
        this.udpSockets.set(port, socket);
        resolve();
      });
      socket.once("error", reject);
    });
  }

  handleUDP(port, message, rinfo) {
    const from = `${rinfo.address}:${rinfo.port}`;
    if (port === this.sinkRtpPort) {
      this.sinkRtpPacketCount += 1;
      if (this.sinkRtpPacketCount === 1 || this.sinkRtpPacketCount % 100 === 0) {
        log("info", "session.sink_rtp_in", {
          sessionId: this.sessionId,
          count: this.sinkRtpPacketCount,
          from,
          bytes: message.length
        });
      }
      this.control.send("rtp.in", {
        port,
        from,
        bytes: message.length,
        data: message.toString("base64")
      });
      return;
    }
    if (port === this.sinkRtcpPort || port === this.sourceRtcpPort || port === this.rtspPort) {
      this.control.send("udp.in", {
        port,
        from,
        bytes: message.length,
        data: message.toString("base64")
      });
    }
  }

  updateSourceDestination(host, port, reason) {
    this.sourceDestination = { host, port };
    this.control.send("source.destination", { host, port, reason });
    log("info", "session.source_destination", { sessionId: this.sessionId, host, port, reason });
  }

  sendSourceRTP(body) {
    if (!this.sourceDestination || typeof body?.data !== "string") {
      this.sendSourceRTPToBridge(body);
      return;
    }
    const packet = Buffer.from(body.data, "base64");
    const socket = this.udpSockets.get(this.sourceRtpPort);
    if (!socket) {
      return;
    }
    this.sourceRtpPacketCount += 1;
    if (this.sourceRtpPacketCount === 1 || this.sourceRtpPacketCount % 100 === 0) {
      log("info", "session.source_rtp_out", {
        sessionId: this.sessionId,
        count: this.sourceRtpPacketCount,
        host: this.sourceDestination.host,
        port: this.sourceDestination.port,
        bytes: packet.length
      });
    }
    socket.send(packet, this.sourceDestination.port, this.sourceDestination.host, (error) => {
      if (error) {
        log("warn", "session.source_rtp_send_failed", {
          sessionId: this.sessionId,
          error: error.message
        });
      }
    });
    this.sendSourceRTPToBridge(body);
  }

  sendSourceRTPToBridge(body) {
    if (this.bridgeControls.size === 0 || typeof body?.data !== "string") {
      return;
    }
    const bytes = typeof body.bytes === "number" ? body.bytes : Buffer.byteLength(body.data, "base64");
    this.bridgeSourceRtpPacketCount += 1;
    if (this.bridgeSourceRtpPacketCount === 1 || this.bridgeSourceRtpPacketCount % 100 === 0) {
      log("info", "session.source_rtp_bridge_out", {
        sessionId: this.sessionId,
        count: this.bridgeSourceRtpPacketCount,
        bridgeCount: this.bridgeControls.size,
        bytes
      });
    }
    for (const bridge of this.bridgeControls) {
      bridge.send("source.rtp.in", { bytes, data: body.data });
    }
  }

  receiveBridgeRTP(body, control) {
    if (!body || typeof body.data !== "string") {
      return;
    }
    const bytes = typeof body.bytes === "number" ? body.bytes : Buffer.byteLength(body.data, "base64");
    this.bridgeSinkRtpPacketCount += 1;
    if (this.bridgeSinkRtpPacketCount === 1 || this.bridgeSinkRtpPacketCount % 100 === 0) {
      log("info", "session.bridge_sink_rtp_in", {
        sessionId: this.sessionId,
        count: this.bridgeSinkRtpPacketCount,
        remote: control.remote,
        bytes
      });
    }
    this.control.send("rtp.in", {
      port: this.sinkRtpPort,
      from: `android.bridge/${control.remote}`,
      bytes,
      data: body.data
    });
  }

  close(reason) {
    if (this.closed) {
      return;
    }
    this.closed = true;
    clearTimeout(this.ttlTimer);
    activeSessions.delete(this.sessionId);
    occupiedSlots.delete(this.slot);
    for (const connection of this.rtspConnections) {
      connection.close(reason);
    }
    this.rtspConnections.clear();
    for (const bridge of this.bridgeControls) {
      bridge.session = null;
      bridge.send("session.closed", { sessionId: this.sessionId, reason });
      bridge.socket.end();
    }
    this.bridgeControls.clear();
    this.rtspServer?.close();
    this.rtspServer = null;
    for (const socket of this.udpSockets.values()) {
      socket.close();
    }
    this.udpSockets.clear();
    log("info", "session.closed", { sessionId: this.sessionId, reason });
  }
}

class RTSPConnection {
  constructor(session, socket) {
    this.session = session;
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.nextCSeq = 1;
    this.pendingRequests = new Map();
    this.sentOptions = false;
    this.sentSourceGETParameter = false;
    this.sentSourceSETParameter = false;
    this.sentSourceSETUP = false;
    this.sentSourcePLAY = false;
    this.sentSinkSETUP = false;
    this.sentPLAY = false;
    this.sessionHeader = null;
    this.presentationURL = null;
    this.remote = `${socket.remoteAddress}:${socket.remotePort}`;
  }

  start() {
    log("info", "rtsp.connected", { sessionId: this.session.sessionId, remote: this.remote });
    this.socket.on("data", (data) => this.receive(data));
    this.socket.on("close", () => this.close("rtsp_closed"));
    this.socket.on("error", (error) => {
      log("warn", "rtsp.error", { sessionId: this.session.sessionId, remote: this.remote, error: error.message });
      this.close("rtsp_error");
    });
    this.sendOptionsIfNeeded("ready");
  }

  receive(data) {
    this.buffer = Buffer.concat([this.buffer, data]);
    while (true) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) {
        return;
      }
      const headerText = this.buffer.slice(0, headerEnd).toString("latin1");
      const contentLength = Number(rtspHeader("Content-Length", headerText) || "0");
      const messageEnd = headerEnd + 4 + Math.max(contentLength, 0);
      if (this.buffer.length < messageEnd) {
        return;
      }
      const message = this.buffer.slice(0, messageEnd).toString("latin1");
      this.buffer = this.buffer.slice(messageEnd);
      this.handleMessage(message);
    }
  }

  handleMessage(message) {
    const [headerText, bodyText = ""] = splitRTSP(message);
    const firstLine = headerText.split("\r\n")[0] || "";
    const cseq = rtspHeader("CSeq", headerText) || "?";
    this.session.control.send("rtsp.log", {
      dir: "in",
      firstLine,
      cseq,
      bytes: Buffer.byteLength(message, "latin1")
    });

    if (firstLine.toUpperCase().startsWith("RTSP/")) {
      this.handleResponse(firstLine, headerText, bodyText, cseq);
      return;
    }

    const method = rtspRequestMethod(firstLine);
    if (!method || cseq === "?") {
      return;
    }
    this.handleRequest(method, firstLine, headerText, bodyText, cseq);
  }

  handleRequest(method, firstLine, headerText, bodyText, cseq) {
    switch (method) {
      case "OPTIONS":
        this.sendResponse(cseq, firstLine, [
          ["Public", "org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER"],
          ["fastRTSPVersion", "0"]
        ]);
        this.sendOptionsIfNeeded("peer_options");
        this.sendSourceGETParameterIfNeeded("peer_options");
        break;
      case "GET_PARAMETER":
        this.sendResponse(cseq, firstLine, [["Content-Type", "text/parameters"]], this.wfdParameterResponseBody(bodyText));
        break;
      case "SET_PARAMETER":
        this.recordPresentationURL(bodyText);
        this.sendResponse(cseq, firstLine);
        if (/wfd_trigger_method:\s*SETUP/i.test(bodyText)) {
          this.sendSinkSETUPIfNeeded("trigger_setup");
        }
        if (/wfd_trigger_method:\s*TEARDOWN/i.test(bodyText)) {
          this.session.control.send("teardown", { reason: "trigger_teardown" });
        }
        break;
      case "SETUP":
        this.recordSourceRTPDestination(headerText, "request_setup");
        this.sessionHeader ||= `${Math.abs(hashString(this.session.sessionId + this.remote))}`;
        this.sendResponse(cseq, firstLine, [
          ["Session", this.sessionHeader],
          ["Transport", this.setupResponseTransport(headerText)]
        ]);
        break;
      case "PLAY":
        this.sendResponse(cseq, firstLine);
        this.session.control.send("source.start", { reason: "play_request" });
        break;
      case "PAUSE":
      case "TEARDOWN":
        this.sendResponse(cseq, firstLine);
        this.session.control.send("source.stop", { reason: `${method.toLowerCase()}_request` });
        break;
      default:
        this.sendResponse(cseq, firstLine);
    }
  }

  handleResponse(firstLine, headerText, bodyText, cseq) {
    const pendingRequest = this.pendingRequests.get(cseq);
    this.pendingRequests.delete(cseq);
    const requestMethod = pendingRequest?.method;
    const requestLabel = pendingRequest?.label || requestMethod || "unknown";
    const statusCode = rtspStatusCode(firstLine);
    const success = statusCode == null || statusCode < 300;
    const session = rtspHeader("Session", headerText)?.split(";")[0]?.trim();
    if (session) {
      this.sessionHeader = session;
    }

    if (!success) {
      log("warn", "rtsp.response_non_success", {
        sessionId: this.session.sessionId,
        cseq,
        requestMethod,
        requestLabel,
        statusCode,
        firstLine
      });
    }

    switch (requestMethod) {
      case "GET_PARAMETER":
        if (!success) {
          break;
        }
        this.recordSourceRTPDestinationFromWFD(bodyText, "get_parameter_response");
        this.sendSourceSETParameterIfNeeded("get_parameter_response");
        break;
      case "SET_PARAMETER":
        if (!success) {
          break;
        }
        this.sendSinkSETUPIfNeeded("set_parameter_response");
        this.sendSourceSETUPIfNeeded("set_parameter_response");
        break;
      case "SETUP":
        if (requestLabel.startsWith("sink_setup_")) {
          if (success) {
            this.sendPLAYIfNeeded("setup_response");
          }
          break;
        }
        if (requestLabel.startsWith("source_setup_")) {
          this.sendSourcePLAYIfNeeded("setup_response");
        }
        break;
      case "PLAY":
        if (requestLabel.startsWith("source_play_")) {
          this.session.control.send("source.start", { reason: success ? "play_response" : "play_response_non_success" });
        }
        break;
      default:
        break;
    }
  }

  sendOptionsIfNeeded(reason) {
    if (this.sentOptions) {
      return;
    }
    this.sentOptions = true;
    this.sendRequest("OPTIONS", "*", [
      ["Require", "org.wfa.wfd1.0"],
      ["lib_version", "edgelink_call_relayd"],
      ["fastRTSPVersion", "0"]
    ], null, `options_${reason}`);
  }

  sendSourceGETParameterIfNeeded(reason) {
    if (this.sentSourceGETParameter) {
      return;
    }
    this.sentSourceGETParameter = true;
    const body = [
      "wfd_audio_codecs\r",
      "wfd_client_rtp_ports\r",
      "wfd_content_protection\r",
      "wfd_content_SP_protection\r",
      "wfd_mirror_control_enable\r"
    ].join("\n");
    this.sendRequest(
      "GET_PARAMETER",
      "rtsp://localhost/wfd1.0",
      [["Content-Type", "text/parameters"]],
      body,
      `get_parameter_${reason}`
    );
  }

  sendSourceSETParameterIfNeeded(reason) {
    if (this.sentSourceSETParameter) {
      return;
    }
    this.sentSourceSETParameter = true;
    const body = [
      `wfd_presentation_URL: ${this.sourcePresentationURL()} none\r`,
      "wfd_platform_type: 2\r",
      "wfd_trigger_method: SETUP\r"
    ].join("\n");
    this.sendRequest(
      "SET_PARAMETER",
      "rtsp://localhost/wfd1.0",
      [["Content-Type", "text/parameters"]],
      body,
      `set_parameter_${reason}`
    );
  }

  sendSourceSETUPIfNeeded(reason) {
    if (this.sentSourceSETUP || !this.session.sourceDestination) {
      return;
    }
    this.sentSourceSETUP = true;
    const rtpPort = this.session.sourceDestination.port;
    this.sendRequest(
      "SETUP",
      this.sourcePresentationURL(),
      [["Transport", `RTP/AVP/UDP;unicast;client_port=${rtpPort}-${rtpPort + 1}`]],
      null,
      `source_setup_${reason}`
    );
  }

  sendSourcePLAYIfNeeded(reason) {
    if (this.sentSourcePLAY) {
      return;
    }
    this.sentSourcePLAY = true;
    const headers = [];
    if (this.sessionHeader) {
      headers.push(["Session", this.sessionHeader]);
    }
    this.sendRequest("PLAY", this.sourcePresentationURL(), headers, null, `source_play_${reason}`);
  }

  sendSinkSETUPIfNeeded(reason) {
    if (this.sentSinkSETUP) {
      return;
    }
    this.sentSinkSETUP = true;
    const uri = this.presentationURL || "rtsp://localhost/wfd1.0/streamid=0";
    this.sendRequest(
      "SETUP",
      uri,
      [["Transport", `RTP/AVP/UDP;unicast;client_port=${this.session.sinkRtpPort}-${this.session.sinkRtcpPort}`]],
      null,
      `sink_setup_${reason}`
    );
  }

  sendPLAYIfNeeded(reason) {
    if (this.sentPLAY) {
      return;
    }
    this.sentPLAY = true;
    const headers = [];
    if (this.sessionHeader) {
      headers.push(["Session", this.sessionHeader]);
    }
    this.sendRequest("PLAY", this.presentationURL || this.sourcePresentationURL(), headers, null, `play_${reason}`);
  }

  sendResponse(cseq, requestFirstLine, headers = [], body = null) {
    this.sendRTSP(buildRTSPMessage("RTSP/1.0 200 OK", [
      ["Date", new Date().toUTCString()],
      ["User-Agent", "EdgeLinkCallRelayD"],
      ["CSeq", cseq],
      ...headers
    ], body), `response_${requestFirstLine}`);
  }

  sendRequest(method, uri, headers = [], body = null, label = method.toLowerCase()) {
    const cseq = `${this.nextCSeq++}`;
    this.pendingRequests.set(cseq, { method, label });
    this.sendRTSP(buildRTSPMessage(`${method} ${uri} RTSP/1.0`, [
      ["Date", new Date().toUTCString()],
      ["Server", "EdgeLinkCallRelayD"],
      ["CSeq", cseq],
      ...headers
    ], body), label);
  }

  sendRTSP(message, label) {
    if (this.socket.destroyed) {
      return;
    }
    const firstLine = message.split("\r\n", 1)[0] || label;
    this.session.control.send("rtsp.log", {
      dir: "out",
      firstLine,
      bytes: Buffer.byteLength(message, "utf8")
    });
    this.socket.write(message);
  }

  wfdParameterResponseBody(requestBody) {
    const requestedNames = new Set(
      requestBody
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => line.split(":")[0])
    );
    const parameters = [
      ["wfd_video_formats", "none"],
      ["wfd_video_bitrate", "none"],
      ["wfd_video_enctype", "none"],
      ["wfd_video_gamuttype", "none"],
      ["wfd_current_video_info", "none"],
      ["wfd_audio_codecs", "AAC 00000001 00"],
      ["audio_sample_time_ms", "20"],
      ["wfd_client_rtp_ports", `RTP/AVP/UDP;unicast ${this.session.sinkRtpPort} 0 mode=play`],
      ["wfd_content_protection", "none"],
      ["wfd_content_SP_protection", "0 0 0 0 0 0 0 0"],
      ["wfd_mirror_control_enable", "enable"],
      ["wfd_support_secure_win", "enable"],
      ["wfd_standby_resume_capability", "supported"],
      ["wfd_mpt_enable", "none"],
      ["wfd_tcp_enable", "none"],
      ["wfd_tcp_multi_session_enable", "none"],
      ["wfd_image_enable_v2", "none"],
      ["wfd_slice_codec", "none"],
      ["wfd_delay_test_enable", "enable"],
      ["wfd_connector_type", "07"]
    ];
    return parameters
      .filter(([name]) => requestedNames.size === 0 || requestedNames.has(name) || (name === "wfd_audio_codecs" && requestedNames.has("wfd_audio_codecs_v2")))
      .map(([name, value]) => `${name}: ${value}`)
      .join("\r\n") + "\r\n";
  }

  recordPresentationURL(bodyText) {
    const line = bodyText.split(/\r?\n/).find((value) => value.trim().toLowerCase().startsWith("wfd_presentation_url:"));
    if (!line) {
      return;
    }
    const value = line.split(/:\s*/, 2)[1]?.trim().split(/\s+/)[0];
    if (value) {
      this.presentationURL = value;
      log("info", "rtsp.presentation_url", { sessionId: this.session.sessionId, url: value });
    }
  }

  recordSourceRTPDestination(headerText, reason) {
    const transport = rtspHeader("Transport", headerText);
    const clientPort = transport && rtspTransportValue("client_port", transport);
    const rtpPort = clientPort && firstRTPPort(clientPort);
    if (!rtpPort) {
      return;
    }
    this.session.updateSourceDestination(this.socket.remoteAddress, rtpPort, reason);
  }

  recordSourceRTPDestinationFromWFD(bodyText, reason) {
    const line = bodyText.split(/\r?\n/).find((value) => value.trim().toLowerCase().startsWith("wfd_client_rtp_ports:"));
    const value = line?.split(":", 2)[1];
    const rtpPort = value && firstRTPPortToken(value);
    if (!rtpPort) {
      return;
    }
    this.session.updateSourceDestination(this.socket.remoteAddress, rtpPort, reason);
  }

  setupResponseTransport(headerText) {
    const transport = rtspHeader("Transport", headerText) || "RTP/AVP/UDP;unicast";
    const clientPort = rtspTransportValue("client_port", transport);
    if (clientPort) {
      return `RTP/AVP/UDP;unicast;client_port=${clientPort};server_port=${this.session.sourceRtpPort}-${this.session.sourceRtcpPort}`;
    }
    return `RTP/AVP/UDP;unicast;server_port=${this.session.sourceRtpPort}-${this.session.sourceRtcpPort}`;
  }

  sourcePresentationURL() {
    return `rtsp://${this.session.publicHost}:${this.session.rtspPort}/wfd1.0/streamid=0`;
  }

  close(reason) {
    this.session.rtspConnections.delete(this);
    if (!this.socket.destroyed) {
      this.socket.destroy();
    }
    log("info", "rtsp.closed", { sessionId: this.session.sessionId, remote: this.remote, reason });
  }
}

async function verifyRelayAuth(body) {
  if (!body || typeof body.deviceId !== "string" || typeof body.ts !== "number" || typeof body.sig !== "string") {
    return { ok: false, error: "invalid_body" };
  }
  if (Math.abs(Math.floor(Date.now() / 1000) - body.ts) > 5 * 60) {
    return { ok: false, error: "expired" };
  }

  const response = await fetch(`${config.workerBaseUrl}/v1/device/${encodeURIComponent(body.deviceId)}`);
  if (!response.ok) {
    return { ok: false, error: `device_fetch_${response.status}` };
  }
  const payload = await response.json();
  const pubkey = Buffer.from(payload.device?.pubkey || "", "base64");
  const sig = Buffer.from(body.sig, "base64");
  if (pubkey.length !== 32 || sig.length !== 64) {
    return { ok: false, error: "invalid_key_or_sig" };
  }
  const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), pubkey]);
  const key = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
  const message = Buffer.from(`EdgeLink relay auth v1\n${body.deviceId}\n${body.ts}`, "utf8");
  const ok = crypto.verify(null, message, key, sig);
  return { ok, error: ok ? undefined : "bad_signature" };
}

function allocateSlot() {
  for (let slot = 0; slot < config.slotCount; slot += 1) {
    if (!occupiedSlots.has(slot)) {
      occupiedSlots.add(slot);
      return slot;
    }
  }
  return null;
}

function listenTCP(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "0.0.0.0", () => {
      server.off("error", reject);
      resolve();
    });
  });
}

function splitRTSP(message) {
  const marker = "\r\n\r\n";
  const index = message.indexOf(marker);
  if (index < 0) {
    return [message, ""];
  }
  return [message.slice(0, index), message.slice(index + marker.length)];
}

function buildRTSPMessage(firstLine, headers, body) {
  const finalHeaders = [...headers];
  if (body != null) {
    finalHeaders.push(["Content-Length", String(Buffer.byteLength(body, "utf8"))]);
  }
  return [firstLine, ...finalHeaders.map(([name, value]) => `${name}: ${value}`)].join("\r\n") + "\r\n\r\n" + (body ?? "");
}

function rtspRequestMethod(firstLine) {
  if (!firstLine.toUpperCase().endsWith(" RTSP/1.0")) {
    return null;
  }
  return firstLine.split(" ")[0]?.toUpperCase() || null;
}

function rtspStatusCode(firstLine) {
  const match = /^RTSP\/\d(?:\.\d)?\s+(\d{3})(?:\s|$)/i.exec(firstLine.trim());
  if (!match) {
    return null;
  }
  const status = Number(match[1]);
  return Number.isInteger(status) ? status : null;
}

function rtspHeader(name, headerText) {
  const prefix = `${name.toLowerCase()}:`;
  for (const line of headerText.split("\r\n")) {
    const trimmed = line.trim();
    if (trimmed.toLowerCase().startsWith(prefix)) {
      return trimmed.slice(prefix.length).trim();
    }
  }
  return null;
}

function rtspTransportValue(name, transport) {
  const prefix = `${name.toLowerCase()}=`;
  for (const component of transport.split(";")) {
    const trimmed = component.trim();
    if (trimmed.toLowerCase().startsWith(prefix)) {
      return trimmed.slice(prefix.length);
    }
  }
  return null;
}

function firstRTPPort(value) {
  const first = String(value).split("-")[0]?.trim();
  const port = Number(first);
  return Number.isInteger(port) && port > 0 && port <= 65_535 ? port : null;
}

function firstRTPPortToken(value) {
  for (const token of String(value).replace(/;/g, " ").split(/\s+/)) {
    const port = firstRTPPort(token);
    if (port) {
      return port;
    }
  }
  return null;
}

function hashString(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0;
  }
  return hash;
}

function intEnv(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

function safeLogBody(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return {};
  }
  const output = {};
  for (const [key, value] of Object.entries(body)) {
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      output[key] = key.toLowerCase().includes("data") || key.toLowerCase().includes("sig") ? `<${String(value).length}>` : value;
    }
  }
  return output;
}

function log(level, event, fields) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    event,
    ...fields
  });
  if (level === "error") {
    console.error(line);
  } else {
    console.log(line);
  }
}

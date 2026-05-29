import Foundation

public enum JSONRPCCodecError: Error, Equatable {
    case invalidMessage(String)
}

public struct JSONRPCCodec: Sendable {
    public init() {}

    public func encodeRequest(_ request: JSONRPCOutboundRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": request.id.foundationValue,
            "method": request.method,
            "params": request.params.foundationValue
        ], options: [.withoutEscapingSlashes])
    }

    public func encodeNotification(_ notification: JSONRPCNotification) throws -> Data {
        var object: [String: Any] = [
            "method": notification.method
        ]
        if notification.params != .object([:]) {
            object["params"] = notification.params.foundationValue
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    public func encodeResponse(_ response: JSONRPCOutboundResponse) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": response.id.foundationValue,
            "result": response.result.foundationValue
        ], options: [.withoutEscapingSlashes])
    }

    public func decode(_ data: Data) throws -> JSONRPCInboundMessage {
        let rawMessage = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JSONRPCCodecError.invalidMessage(rawMessage)
        }
        guard let object = jsonObject as? [String: Any] else {
            throw JSONRPCCodecError.invalidMessage(rawMessage)
        }

        if let method = object["method"] as? String {
            let params = JSONValue(any: object["params"] ?? NSNull())
            if let id = JSONRPCID(any: object["id"] ?? NSNull()) {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        guard let id = JSONRPCID(any: object["id"] ?? NSNull()) else {
            throw JSONRPCCodecError.invalidMessage(rawMessage)
        }

        if let error = object["error"] as? [String: Any] {
            return .error(
                id: id,
                code: error["code"] as? Int ?? -32000,
                message: error["message"] as? String ?? "Unknown JSON-RPC error"
            )
        }

        return .response(id: id, result: JSONValue(any: object["result"] ?? NSNull()))
    }
}

public struct JSONRPCFramer: Sendable {
    private let codec: JSONRPCCodec
    private var buffer = Data()

    public init(codec: JSONRPCCodec = JSONRPCCodec()) {
        self.codec = codec
    }

    public mutating func receive(_ data: Data) throws -> [JSONRPCInboundMessage] {
        buffer.append(data)
        var messages: [JSONRPCInboundMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            messages.append(try codec.decode(Data(line)))
        }
        return messages
    }
}

public struct AppServerStartupCommand: Equatable, Sendable {
    public var codexPath: String

    public init(codexPath: String) {
        self.codexPath = codexPath
    }

    public var shellCommand: String {
        AppServerShellCommand(codexPath: codexPath).appServerCommand
    }
}

public struct AppServerShellCommand: Equatable, Sendable {
    public var codexPath: String

    public init(codexPath: String) {
        self.codexPath = codexPath
    }

    public var versionCommand: String {
        command("\(codexPath) --version")
    }

    public var proxyHelpCommand: String {
        command("\(codexPath) app-server proxy --help")
    }

    public var appServerHelpCommand: String {
        command("\(codexPath) app-server --help")
    }

    public var daemonStartCommand: String {
        command(daemonStartBody)
    }

    public var proxyCommand: String {
        command(proxyBody)
    }

    public var appServerCommand: String {
        command(sharedAppServerBridgeBody)
    }

    private func command(_ body: String) -> String {
        "\(Self.pathExport); \(body)"
    }

    private var sharedAppServerBridgeBody: String {
        let bridgeScript = Self.singleQuoted(Self.webSocketBridgeNodeScript.replacingOccurrences(of: "\n", with: " "))
        return #"SOCKET="${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock"; if [ -S "$SOCKET" ] && command -v node >/dev/null 2>&1; then node -e \#(bridgeScript) "$SOCKET"; STATUS=$?; [ "$STATUS" -eq 0 ] && exit 0; fi; exec \#(codexPath) app-server --listen stdio://"#
    }

    private var daemonStartBody: String {
        "\(codexPath) app-server daemon start"
    }

    private var proxyBody: String {
        "\(codexPath) app-server proxy"
    }

    private static let pathExport = #"export PATH="$HOME/.codex/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH""#

    private static func singleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let webSocketBridgeNodeScript = #"""
const net=require("net");
const crypto=require("crypto");
const socketPath=process.argv[1];
const socket=net.createConnection(socketPath);
let headerBuffer=Buffer.alloc(0);
let frameBuffer=Buffer.alloc(0);
let ready=false;
let outboundQueue=[];
let stdinBuffer="";
let fragmentOpcode=null;
let fragments=[];
function frame(opcode,payload){
  payload=Buffer.isBuffer(payload)?payload:Buffer.from(payload);
  let header;
  if(payload.length<126){
    header=Buffer.from([0x80|opcode,0x80|payload.length]);
  }else if(payload.length<65536){
    header=Buffer.alloc(4);
    header[0]=0x80|opcode;
    header[1]=0x80|126;
    header.writeUInt16BE(payload.length,2);
  }else{
    header=Buffer.alloc(10);
    header[0]=0x80|opcode;
    header[1]=0x80|127;
    header.writeBigUInt64BE(BigInt(payload.length),2);
  }
  const mask=crypto.randomBytes(4);
  const masked=Buffer.alloc(payload.length);
  for(let i=0;i<payload.length;i++) masked[i]=payload[i]^mask[i%4];
  return Buffer.concat([header,mask,masked]);
}
function sendText(line){
  if(!ready){
    outboundQueue.push(line);
    return;
  }
  socket.write(frame(1,Buffer.from(line)));
}
function flushQueue(){
  for(const line of outboundQueue) socket.write(frame(1,Buffer.from(line)));
  outboundQueue=[];
}
function handleFrame(fin,opcode,payload){
  if(opcode===1){
    if(fin){
      process.stdout.write(payload.toString()+"\n");
    }else{
      fragmentOpcode=1;
      fragments=[payload];
    }
    return;
  }
  if(opcode===0&&fragmentOpcode===1){
    fragments.push(payload);
    if(fin){
      process.stdout.write(Buffer.concat(fragments).toString()+"\n");
      fragmentOpcode=null;
      fragments=[];
    }
    return;
  }
  if(opcode===8){
    socket.end();
    return;
  }
  if(opcode===9){
    socket.write(frame(10,payload));
  }
}
function parseFrames(){
  let offset=0;
  while(offset+2<=frameBuffer.length){
    const b0=frameBuffer[offset];
    const b1=frameBuffer[offset+1];
    const fin=(b0&0x80)!==0;
    const opcode=b0&0x0f;
    let length=b1&0x7f;
    let position=offset+2;
    if(length===126){
      if(position+2>frameBuffer.length) break;
      length=frameBuffer.readUInt16BE(position);
      position+=2;
    }else if(length===127){
      if(position+8>frameBuffer.length) break;
      const wideLength=frameBuffer.readBigUInt64BE(position);
      if(wideLength>BigInt(Number.MAX_SAFE_INTEGER)){
        socket.destroy();
        return;
      }
      length=Number(wideLength);
      position+=8;
    }
    const masked=(b1&0x80)!==0;
    let mask;
    if(masked){
      if(position+4>frameBuffer.length) break;
      mask=frameBuffer.subarray(position,position+4);
      position+=4;
    }
    if(position+length>frameBuffer.length) break;
    const payload=Buffer.from(frameBuffer.subarray(position,position+length));
    if(masked){
      for(let i=0;i<payload.length;i++) payload[i]^=mask[i%4];
    }
    handleFrame(fin,opcode,payload);
    offset=position+length;
  }
  frameBuffer=frameBuffer.subarray(offset);
}
socket.on("connect",()=>{
  const key=crypto.randomBytes(16).toString("base64");
  const request=[
    "GET / HTTP/1.1",
    "Host: localhost",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: "+key,
    "Sec-WebSocket-Version: 13",
    "",
    ""
  ].join("\r\n");
  socket.write(request);
});
socket.on("data",chunk=>{
  if(!ready){
    headerBuffer=Buffer.concat([headerBuffer,chunk]);
    const headerEnd=headerBuffer.indexOf("\r\n\r\n");
    if(headerEnd===-1) return;
    const header=headerBuffer.subarray(0,headerEnd).toString();
    if(!/^HTTP\/1\.1 101\b/.test(header)){
      socket.destroy();
      process.exitCode=1;
      return;
    }
    ready=true;
    frameBuffer=Buffer.concat([frameBuffer,headerBuffer.subarray(headerEnd+4)]);
    headerBuffer=Buffer.alloc(0);
    flushQueue();
  }else{
    frameBuffer=Buffer.concat([frameBuffer,chunk]);
  }
  parseFrames();
});
socket.on("error",()=>{ process.exitCode=1; });
socket.on("close",()=>process.exit());
process.stdin.setEncoding("utf8");
process.stdin.on("data",chunk=>{
  stdinBuffer+=chunk;
  let newlineIndex;
  while((newlineIndex=stdinBuffer.indexOf("\n"))!==-1){
    let line=stdinBuffer.slice(0,newlineIndex);
    stdinBuffer=stdinBuffer.slice(newlineIndex+1);
    if(line.endsWith("\r")) line=line.slice(0,-1);
    if(line.length>0) sendText(line);
  }
});
process.stdin.on("end",()=>socket.end());
"""#
}

extension JSONRPCID {
    init?(any: Any) {
        switch any {
        case let value as Int:
            self = .number(value)
        case let value as NSNumber:
            self = .number(value.intValue)
        case let value as String:
            self = .string(value)
        default:
            return nil
        }
    }

    var foundationValue: Any {
        switch self {
        case let .number(value):
            return value
        case let .string(value):
            return value
        }
    }
}

extension JSONValue {
    init(any: Any) {
        switch any {
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        default:
            self = .null
        }
    }

    var foundationValue: Any {
        switch self {
        case let .object(value):
            return value.mapValues(\.foundationValue)
        case let .array(value):
            return value.map(\.foundationValue)
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        }
    }
}

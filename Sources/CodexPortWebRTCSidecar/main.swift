import CodexPortWebRTC
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--stdio-jsonl"] else {
    FileHandle.standardError.write(Data("Usage: codexport-webrtc-sidecar [--stdio-jsonl]\n".utf8))
    Foundation.exit(64)
}

let runner = WebRTCSidecarRunner(io: FileHandleWebRTCSidecarInputOutput())
await runner.run()

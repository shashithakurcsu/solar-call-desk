import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

@main struct InspectVoiceOutput {
    @MainActor static func bind(_ node: AVAudioIONode, to id: UInt32) throws {
        guard let unit = node.audioUnit else { throw VoiceBridgeError.route("No unit") }
        var value = id
        try AudioDeviceCatalog.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &value, 4))
    }
    @MainActor static func current(_ node: AVAudioIONode) throws -> UInt32 {
        guard let unit = node.audioUnit else { throw VoiceBridgeError.route("No unit") }
        var value: UInt32 = 0; var size: UInt32 = 4
        try AudioDeviceCatalog.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &value, &size))
        return value
    }
    @MainActor static func dump(_ stage: String, _ engine: AVAudioEngine) throws {
        let output = engine.outputNode
        print("\(stage): device=\(try current(output)) hardware=\(DiagnosticFormatPolicy.describe(output.outputFormat(forBus: 0))) client=\(DiagnosticFormatPolicy.describe(output.inputFormat(forBus: 0))) running=\(engine.isRunning)")
    }
    @MainActor static func verifyProduction(_ devices: [AudioDevice]) throws {
        guard let inputDevice = devices.first(where: { $0.uid == "BlackHole2ch_UID" && $0.isVirtual && $0.inputChannels == 2 && $0.outputChannels == 2 }),
              let outputDevice = devices.first(where: { $0.uid == "BlackHole16ch_UID" && $0.isVirtual && $0.inputChannels == 16 && $0.outputChannels == 16 }) else { throw VoiceBridgeError.route("Expected exact primary devices") }
        for device in [inputDevice, outputDevice] {
            guard try AudioDeviceCatalog.scalar(device.id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else { throw VoiceBridgeError.route("Selected bus busy") }
        }
        let input = AVAudioEngine(); let output = AVAudioEngine()
        let resolve: (AudioEngineEndpoint) -> AVAudioIONode = { endpoint in
            switch endpoint {
            case .inputEngineInput: input.inputNode
            case .inputEngineOutput: input.outputNode
            case .outputEngineInput: output.inputNode
            case .outputEngineOutput: output.outputNode
            }
        }
        let plan = AudioEngineBindingPlan.make(mode: .externalBridge, inputID: inputDevice.id, outputID: outputDevice.id)
        let initialNodes = plan.map { ($0, resolve($0.endpoint)) }
        for (target, node) in initialNodes {
            let id = try current(node)
            let name = (try? AudioDeviceCatalog.string(id, kAudioObjectPropertyName)) ?? "unavailable"
            let uid = (try? AudioDeviceCatalog.string(id, kAudioDevicePropertyDeviceUID)) ?? "unavailable"
            print("INITIAL \(target.endpoint): device=\(id) name=\(name) UID=\(uid)")
        }
        try AudioEngineBindingPlan.configure(plan, resolve: resolve) { node, id in try bind(node, to: id) }
        let sourceHardware = input.inputNode.inputFormat(forBus: 0)
        let sinkHardware = output.outputNode.outputFormat(forBus: 0)
        let source = try AudioClientFormat.make(hardware: sourceHardware)
        let sink = try AudioClientFormat.make(hardware: sinkHardware)
        let speech = try AudioClientFormat.make(hardware: sinkHardware, sampleRate: 24_000)
        let isolatedSink = AVAudioMixerNode(); input.attach(isolatedSink)
        input.connect(input.inputNode, to: isolatedSink, format: source)
        let player = AVAudioPlayerNode(); output.attach(player)
        output.connect(player, to: output.mainMixerNode, format: speech)
        output.connect(output.mainMixerNode, to: output.outputNode, format: sink)
        let expected = AudioRouteIntegrity.Engines(inputHardware: sourceHardware, inputClient: source,
            outputHardware: sinkHardware, outputClient: sink, inputRunning: false, outputRunning: false)
        if CommandLine.arguments.contains("--prepare-stopped") {
            output.prepare(); input.prepare()
            guard !input.isRunning, !output.isRunning else { throw VoiceBridgeError.route("Unexpected running engine") }
            print("Prepared graph resources only; engines remain stopped.")
        }
        let stages = CommandLine.arguments.contains("--hold-20") ? ["after graph"] + (1...20).map { "after \($0)s queued updates" } : ["after graph", "after queued updates"]
        for (index, stage) in stages.enumerated() {
            if index > 0 { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
            let nodes = plan.map { ($0, resolve($0.endpoint)) }
            var observed: [AudioEngineEndpoint: UInt32] = [:]
            for (target, node) in nodes { observed[target.endpoint] = try current(node) }
            try AudioEngineBindingPlan.validate(plan, observed: observed, context: stage)
            let actual = AudioRouteIntegrity.Engines(inputHardware: input.inputNode.inputFormat(forBus: 0),
                inputClient: input.inputNode.outputFormat(forBus: 0), outputHardware: output.outputNode.outputFormat(forBus: 0),
                outputClient: output.outputNode.inputFormat(forBus: 0), inputRunning: input.isRunning, outputRunning: output.isRunning)
            try actual.validate(expected: expected, requireRunning: false, context: stage)
            guard !input.isRunning, !output.isRunning, actual.inputHardware.channelCount == 2, actual.outputHardware.channelCount == 16 else { throw VoiceBridgeError.route("Unexpected graph state") }
            if index == 0 || index == stages.count - 1 {
                print("PRODUCTION \(stage): all four endpoint IDs verified; capture=\(inputDevice.id)/2ch output=\(outputDevice.id)/16ch speech=24k/16ch; both engines stopped")
            }
        }
    }
    @MainActor static func main() throws {
        let defaults = try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            try AudioDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), $0)
        }
        let devices = try AudioDeviceCatalog.devices()
        if CommandLine.arguments.contains("--verify-production") {
            try verifyProduction(devices)
            let after = try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
                try AudioDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), $0)
            }
            guard after == defaults else { throw VoiceBridgeError.route("Unexpected default drift") }
            print("Defaults unchanged \(after); prepare=\(CommandLine.arguments.contains("--prepare-stopped")); no start/tap/play/schedule/permission/API call was made.")
            return
        }
        guard let selected = devices.first(where: { $0.uid == "BlackHole16ch_UID" && $0.isVirtual && $0.inputChannels == 16 && $0.outputChannels == 16 }) else { throw VoiceBridgeError.route("Expected primary 16ch") }
        guard try AudioDeviceCatalog.scalar(selected.id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else { throw VoiceBridgeError.route("Selected bus busy") }
        for pinBoth in [false, true] {
            print("CASE \(pinBoth ? "both endpoints" : "output endpoint only") HAL=\(selected.id) \(selected.inputChannels)/\(selected.outputChannels)")
            let engine = AVAudioEngine()
            let output = engine.outputNode
            if pinBoth {
                let input = engine.inputNode
                try bind(input, to: selected.id)
            }
            try bind(output, to: selected.id)
            let originalOutputUnit = output.audioUnit
            try dump("after binding", engine)
            let hardware = output.outputFormat(forBus: 0)
            let client = try AudioClientFormat.make(hardware: hardware)
            let speech = try AudioClientFormat.make(hardware: hardware, sampleRate: 24_000)
            let player = AVAudioPlayerNode(); engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: speech)
            engine.connect(engine.mainMixerNode, to: output, format: client)
            try dump("after graph", engine)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            try dump("after queued updates", engine)
            let unused = engine.inputNode
            print("IO shares unit=\(unused.audioUnit == output.audioUnit); output unit unchanged=\(originalOutputUnit == output.audioUnit)")
            print("unused input current=\(try current(unused)) hardware=\(DiagnosticFormatPolicy.describe(unused.inputFormat(forBus: 0)))")
            try dump("after unused input lookup", engine)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            try dump("after final queued updates", engine)
        }
        let after = try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            try AudioDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), $0)
        }
        guard after == defaults else { throw VoiceBridgeError.route("Unexpected default drift") }
        print("Defaults unchanged \(after); no prepare/start/tap/play/schedule/permission/API call was made.")
    }
}

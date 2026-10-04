// Inert diagnostic graph inspection. No start/prepare/tap/playback/permission calls.
// Client graph formats are configured only after all I/O nodes bind to exact primary virtual UIDs.
// Compile with Sources/VoiceBridge/*.swift and -parse-as-library using the CLT toolchain.
import AVFoundation
import AudioToolbox
import CoreAudio

@main struct InspectDiagnosticFormats {
    @MainActor static func main() throws {
        let defaults = try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            try AudioDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), $0)
        }
        for device in try AudioDeviceCatalog.devices() where ["BlackHole2ch_UID", "BlackHole16ch_UID"].contains(device.uid) {
            guard device.isVirtual else { fatalError("Expected virtual primary") }
            print("DEVICE \(device.name) UID=\(device.uid) id=\(device.id) hardware=\(device.inputChannels)/\(device.outputChannels)")
            let input = AVAudioEngine(); let output = AVAudioEngine()
            for (label, node) in [("capture input", input.inputNode as AVAudioIONode), ("capture output", input.outputNode),
                                  ("playback input", output.inputNode), ("playback output", output.outputNode)] {
                guard let unit = node.audioUnit else { fatalError("Missing audio unit") }
                var id = device.id
                try AudioDeviceCatalog.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<UInt32>.size)))
                var size = UInt32(MemoryLayout<UInt32>.size); var current: UInt32 = 0
                try AudioDeviceCatalog.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &current, &size))
                guard current == device.id else { fatalError("Binding failed") }
                print("\(label): input=\(node.inputFormat(forBus: 0)) output=\(node.outputFormat(forBus: 0))")
                for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
                    for element: UInt32 in [0, 1] {
                        var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &asbd, &size)
                        print("  AU scope=\(scope) bus=\(element) status=\(status) rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)")
                    }
                }
            }
            print("CHECK source=\(input.inputNode.outputFormat(forBus: 0)) sink=\(output.outputNode.inputFormat(forBus: 0))")
            let plan = try DiagnosticFormatPolicy.plan(device: device, hardwareSource: input.inputNode.inputFormat(forBus: 0),
                hardwareSink: output.outputNode.outputFormat(forBus: 0), clientSource: input.inputNode.outputFormat(forBus: 0),
                clientSink: output.outputNode.inputFormat(forBus: 0))
            // An isolated sink applies the same output-bus format that a non-nil tap format
            // applies in the app. It has no output connection and never renders or captures.
            let isolatedSink = AVAudioMixerNode(); input.attach(isolatedSink)
            input.connect(input.inputNode, to: isolatedSink, format: plan.source)
            let player = AVAudioPlayerNode(); output.attach(player)
            output.connect(player, to: output.mainMixerNode, format: plan.sink)
            output.connect(output.mainMixerNode, to: output.outputNode, format: plan.sink)
            try DiagnosticFormatPolicy.validateConfigured(device: device, plan: plan,
                hardwareSource: input.inputNode.inputFormat(forBus: 0), hardwareSink: output.outputNode.outputFormat(forBus: 0),
                clientSource: input.inputNode.outputFormat(forBus: 0), clientSink: output.outputNode.inputFormat(forBus: 0))
            print("CONFIGURED source=\(input.inputNode.outputFormat(forBus: 0)) sink=\(output.outputNode.inputFormat(forBus: 0)); engines running=\(input.isRunning)/\(output.isRunning)")
        }
        let after = try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            try AudioDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), $0)
        }
        guard after == defaults else { fatalError("System defaults changed during inspection") }
        print("UNCHANGED default input/output device IDs: \(after)")
    }
}

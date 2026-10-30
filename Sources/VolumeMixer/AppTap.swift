import CoreAudio
import AudioToolbox
import Foundation

/// Gain shared with the real-time audio thread.
final class GainBox: @unchecked Sendable {
    var target: Float
    var current: Float
    init(_ gain: Float) { target = gain; current = gain }
}

enum TapError: Error {
    case status(String, OSStatus)
}

/// Silences an app's original output with a Core Audio process tap (macOS 14.2+)
/// and plays the captured audio back to the output device at a chosen gain.
/// A tap only exists while an app's volume is below 100%, so untouched apps cost nothing.
final class AppTap {
    let processes: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let gainBox: GainBox
    private let queue = DispatchQueue(label: "VolumeMixer.tap", qos: .userInteractive)

    var gain: Float {
        get { gainBox.target }
        set { gainBox.target = newValue }
    }

    init(processes: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processes = processes
        self.outputUID = outputUID
        self.gainBox = GainBox(gain)

        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "VolumeMixer"

        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { throw TapError.status("CreateProcessTap", err) }

        let tapUID = tapID.getString(kAudioTapPropertyUID) ?? description.uuid.uuidString
        let format = tapID.get(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let tapChannels = max(Int(format.mChannelsPerFrame), 1)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer Tap",
            kAudioAggregateDeviceUIDKey: "VolumeMixer-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { throw TapError.status("CreateAggregateDevice", err) }

        let box = gainBox
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, tapChannels: tapChannels, gain: box)
        }
        guard err == noErr else { throw TapError.status("CreateIOProc", err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw TapError.status("DeviceStart", err) }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }

    /// Real-time render: copy the tap's channels (the last `tapChannels` input channels,
    /// after any input channels of the output device itself) to every output channel,
    /// ramping the gain across the buffer to avoid clicks.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapChannels: Int,
                               gain: GainBox) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var inTotal = 0
        for buf in inList { inTotal += Int(buf.mNumberChannels) }
        let tapCount = min(tapChannels, inTotal)
        let tapBase = inTotal - tapCount

        let start = gain.current
        let target = gain.target
        defer { gain.current = target }

        var outChannel = 0
        for outBuf in outList {
            let outCh = Int(outBuf.mNumberChannels)
            guard outCh > 0, let outData = outBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outFrames = Int(outBuf.mDataByteSize) / (MemoryLayout<Float>.size * outCh)

            for c in 0..<outCh {
                defer { outChannel += 1 }
                guard tapCount > 0 else {
                    for f in 0..<outFrames { outData[f * outCh + c] = 0 }
                    continue
                }
                // Locate the source buffer/channel for this output channel.
                var src = tapBase + (outChannel % tapCount)
                var bufIndex = 0
                while bufIndex < inList.count, src >= Int(inList[bufIndex].mNumberChannels) {
                    src -= Int(inList[bufIndex].mNumberChannels)
                    bufIndex += 1
                }
                guard bufIndex < inList.count,
                      let inData = inList[bufIndex].mData?.assumingMemoryBound(to: Float.self) else {
                    for f in 0..<outFrames { outData[f * outCh + c] = 0 }
                    continue
                }
                let inCh = Int(inList[bufIndex].mNumberChannels)
                let inFrames = Int(inList[bufIndex].mDataByteSize) / (MemoryLayout<Float>.size * inCh)
                let n = min(outFrames, inFrames)

                var g = start
                let step = n > 0 ? (target - start) / Float(n) : 0
                for f in 0..<n {
                    outData[f * outCh + c] = inData[f * inCh + src] * g
                    g += step
                }
                for f in n..<outFrames { outData[f * outCh + c] = 0 }
            }
        }
    }
}

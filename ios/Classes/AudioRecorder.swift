import AVFoundation
import Accelerate

public class AudioRecorder: NSObject, AVAudioRecorderDelegate {

    // MARK: - Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var path: String?
    private var useLegacyNormalization: Bool = false
    private var audioUrl: URL?
    private var recordedDuration: CMTime = .zero
    private var currentDbValue: Float = -160.0
    private var isUsingEngine: Bool = false

    // MARK: - Start Recording
    func startRecording(_ result: @escaping FlutterResult, _ recordingSettings: RecordingSettings) {
        useLegacyNormalization = recordingSettings.useLegacy ?? false

        var settings: [String: Any] = [
            AVFormatIDKey: getEncoder(recordingSettings.encoder ?? 0),
            AVSampleRateKey: recordingSettings.sampleRate ?? 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        if let bitRate = recordingSettings.bitRate {
            settings[AVEncoderBitRateKey] = bitRate
        }

        if (recordingSettings.encoder ?? 0) == Constants.kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = recordingSettings.linearPCMBitDepth
            settings[AVLinearPCMIsBigEndianKey] = recordingSettings.linearPCMIsBigEndian
            settings[AVLinearPCMIsFloatKey] = recordingSettings.linearPCMIsFloat
        }

        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        if recordingSettings.path == nil {
            let documentDirectory = getDocumentDirectory(result)
            let date = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = Constants.fileNameFormat
            let fileName = formatter.string(from: date) + ".m4a"
            self.path = "\(documentDirectory)/\(fileName)"
        } else {
            self.path = recordingSettings.path
        }

        do {
            if recordingSettings.overrideAudioSession {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: options)
                try AVAudioSession.sharedInstance().setActive(true)
            }

            // ✅ Use AVAudioEngine when available
            if #available(iOS 10.0, *) {
                try startEngineRecording()
                isUsingEngine = true
                result(true)
                return
            }

            // 🎙️ Fallback: AVAudioRecorder
            audioUrl = URL(fileURLWithPath: self.path!)
            audioRecorder = try AVAudioRecorder(url: audioUrl!, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            result(true)

        } catch {
            result(FlutterError(code: Constants.audioWaveforms,
                                message: "Failed to start recording",
                                details: error.localizedDescription))
        }
    }

    // MARK: - AVAudioEngine setup
    private func startEngineRecording() throws {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: nil)
        }

        inputNode = engine.inputNode
        let format = inputNode!.inputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1024

        inputNode!.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            var rms: Float = 0.0
            vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

            var db = 20 * log10(rms)
            if !db.isFinite { db = -160.0 }

            let minDb: Float = -160.0
            let maxDb: Float = 0.0

            let linear = pow(10.0, db / 20.0)
            let minLinear = pow(10.0, minDb / 20.0)
            let maxLinear = pow(10.0, maxDb / 20.0)

            let normalized = (linear - minLinear) / (maxLinear - minLinear)
            self.currentDbValue = normalized
        }

        engine.prepare()
        try engine.start()
    }

    // MARK: - Stop Recording
    public func stopRecording(_ result: @escaping FlutterResult) {
        if isUsingEngine {
            inputNode?.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine?.reset()
            isUsingEngine = false
            sendResult(result, duration: 0)
            return
        }

        audioRecorder?.stop()
        guard let url = audioUrl else {
            sendResult(result, duration: 0)
            return
        }

        let asset = AVURLAsset(url: url)
        if #available(iOS 15.0, *) {
            Task {
                do {
                    recordedDuration = try await asset.load(.duration)
                    sendResult(result, duration: Int(recordedDuration.seconds * 1000))
                } catch {
                    sendResult(result, duration: 0)
                }
            }
        } else {
            recordedDuration = asset.duration
            sendResult(result, duration: Int(recordedDuration.seconds * 1000))
        }

        audioRecorder = nil
    }

    // MARK: - Pause & Resume
    public func pauseRecording(_ result: @escaping FlutterResult) {
        if isUsingEngine {
            audioEngine?.pause()
            result(true)
        } else {
            audioRecorder?.pause()
            result(true)
        }
    }

    public func resumeRecording(_ result: @escaping FlutterResult) {
        if isUsingEngine {
            do {
                try audioEngine?.start()
                result(true)
            } catch {
                result(FlutterError(code: Constants.audioWaveforms,
                                    message: "Failed to resume audio engine",
                                    details: error.localizedDescription))
            }
        } else {
            audioRecorder?.record()
            result(true)
        }
    }

    // MARK: - Get Decibel
    public func getDecibel(_ result: @escaping FlutterResult) {
        if isUsingEngine {
            result(currentDbValue)
        } else {
            audioRecorder?.updateMeters()
            if useLegacyNormalization {
                let amp = audioRecorder?.averagePower(forChannel: 0) ?? 0.0
                result(amp)
            } else {
                let amp = audioRecorder?.peakPower(forChannel: 0) ?? 0.0
                let linear = pow(10, amp / 20)
                result(linear)
            }
        }
    }

    // MARK: - Permission Check
    public func checkHasPermission(_ result: @escaping FlutterResult) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    result(allowed)
                }
            }
        case .denied:
            result(false)
        case .granted:
            result(true)
        @unknown default:
            result(false)
        }
    }

    // MARK: - Encoder
    public func getEncoder(_ enCoder: Int) -> Int {
        switch enCoder {
        case Constants.kAudioFormatMPEG4AAC:
            return Int(kAudioFormatMPEG4AAC)
        case Constants.kAudioFormatMPEGLayer1:
            return Int(kAudioFormatMPEGLayer1)
        case Constants.kAudioFormatMPEGLayer2:
            return Int(kAudioFormatMPEGLayer2)
        case Constants.kAudioFormatMPEGLayer3:
            return Int(kAudioFormatMPEGLayer3)
        case Constants.kAudioFormatMPEG4AAC_ELD:
            return Int(kAudioFormatMPEG4AAC_ELD)
        case Constants.kAudioFormatMPEG4AAC_HE:
            return Int(kAudioFormatMPEG4AAC_HE)
        case Constants.kAudioFormatOpus:
            return Int(kAudioFormatOpus)
        case Constants.kAudioFormatAMR:
            return Int(kAudioFormatAMR)
        case Constants.kAudioFormatAMR_WB:
            return Int(kAudioFormatAMR_WB)
        case Constants.kAudioFormatLinearPCM:
            return Int(kAudioFormatLinearPCM)
        case Constants.kAudioFormatAppleLossless:
            return Int(kAudioFormatAppleLossless)
        case Constants.kAudioFormatMPEG4AAC_HE_V2:
            return Int(kAudioFormatMPEG4AAC_HE_V2)
        default:
            return Int(kAudioFormatMPEG4AAC)
        }
    }

    // MARK: - Helpers
    private func sendResult(_ result: @escaping FlutterResult, duration: Int) {
        var params = [String: Any?]()
        params[Constants.resultFilePath] = path
        params[Constants.resultDuration] = duration
        result(params)
    }

    private func getDocumentDirectory(_ result: @escaping FlutterResult) -> String {
        let directory = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let ifExists = FileManager.default.fileExists(atPath: directory)
        if directory.isEmpty {
            result(FlutterError(code: Constants.audioWaveforms,
                                message: "The document directory path is empty",
                                details: nil))
        } else if !ifExists {
            result(FlutterError(code: Constants.audioWaveforms,
                                message: "The document directory doesn't exist",
                                details: nil))
        }
        return directory
    }
}

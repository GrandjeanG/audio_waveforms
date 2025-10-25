import AVFoundation
import Accelerate

public class AudioRecorder: NSObject, AVAudioRecorderDelegate {

    // MARK: - Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var inputNode: AVAudioInputNode?
    private var path: String?
    private var useLegacyNormalization: Bool = false
    private var audioUrl: URL?
    private var recordedDuration: CMTime = .zero
    private var currentDbValue: Float = -160.0
    private var isUsingEngine: Bool = false

    // ⚡ PERFORMANCE OPTIMIZATION: prepare audio session and engine once at init
    override public init() {
        super.init()
        prepareAudioSession()
        prepareAudioEngine()
    }

    // MARK: - Preload audio session and engine
    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to pre-activate AVAudioSession:", error)
        }
    }

    private func prepareAudioEngine() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        // Force internal allocation of the input node format
        _ = engine.inputNode.inputFormat(forBus: 0)
        engine.prepare()

        // ⚡ Pre-warm the microphone once so it starts faster later
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            do {
                try engine.start()
                engine.pause()
            } catch {
                print("Failed to pre-start audio engine:", error)
            }
        }
    }

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
            // Avoid re-activating audio session if already active
            let session = AVAudioSession.sharedInstance()
            if recordingSettings.overrideAudioSession && !session.isOtherAudioPlaying {
                try session.setCategory(.playAndRecord, options: options)
                try session.setActive(true)
            }

            // Use AVAudioEngine on modern iOS
            if #available(iOS 10.0, *) {
                try startEngineRecording()
                isUsingEngine = true
                result(true)
                return
            }

            // Fallback to AVAudioRecorder (for older devices)
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

    // MARK: - AVAudioEngine recording
    private func startEngineRecording() throws {
        // Reuse engine if already prepared
        if audioEngine == nil {
            audioEngine = AVAudioEngine()
        }
        guard let engine = audioEngine else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: nil)
        }

        inputNode = engine.inputNode
        let format = inputNode!.inputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1024

        // Create output file
        let fileUrl = URL(fileURLWithPath: self.path!)
        outputFile = try AVAudioFile(forWriting: fileUrl, settings: format.settings)

        inputNode!.removeTap(onBus: 0)
        inputNode!.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.floatChannelData?[0] else { return }

            // Write the audio buffer to file
            do {
                try self.outputFile?.write(from: buffer)
            } catch {
                print("Error writing audio buffer:", error)
            }

            // Compute RMS → dB → linear normalized value
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

        // Do not re-prepare if already running
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: - Stop Recording
    public func stopRecording(_ result: @escaping FlutterResult) {
        if isUsingEngine {
            inputNode?.removeTap(onBus: 0)
            // Pause instead of stop so engine stays ready for next use
            audioEngine?.pause()
            if #available(iOS 18.0, *) {
                if let file = outputFile {
                    do {
                        try file.close() // Close the file on iOS 18 or later
                        outputFile = nil // Reset the reference
                    } catch {
                        print("Error closing audio file:", error)
                    }
                }
            } else {
                // For earlier iOS versions, set the reference to nil
                outputFile = nil
            }
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

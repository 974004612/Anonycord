//
//  MediaRecorder.swift
//  Anonycord
//
//  Created by Constantin Clerc on 7/8/24.
//

import AVFoundation
import Photos
import UIKit
import MediaPlayer

class MediaRecorder: ObservableObject {
    private var recordingSession: AVAudioSession!
    private var audioRecorder: AVAudioRecorder!
    private var videoOutput: AVCaptureMovieFileOutput!
    private var captureSession: AVCaptureSession!
    
    private let videoRecordingDelegate = VideoRecordingDelegate()
    
    // 锁屏检测
    private var lockScreenObserver: NSObjectProtocol?
    
    init() {
        setupLockScreenDetection()
    }
    
    deinit {
        if let observer = lockScreenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupLockScreenDetection() {
        lockScreenObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillResignActive()
        }
    }
    
    private func handleAppWillResignActive() {
        // 应用即将进入后台，可能是锁屏
        if isRecordingVideo() {
            stopVideoRecording()
            // 延迟保存和退出，确保录制完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.saveCurrentVideoAndExit()
            }
        }
    }
    
    private func isRecordingVideo() -> Bool {
        return videoOutput?.isRecording ?? false
    }
    
    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { _ in }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }
        PHPhotoLibrary.requestAuthorization { _ in }
    }
    
    func setupCaptureSession() {
        captureSession = AVCaptureSession()
        
        // 使用4K预设，后续将以activeFormat强制帧率
        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            captureSession.sessionPreset = .hd4K3840x2160
        } else {
            captureSession.sessionPreset = .high
            print("[Anonycord] 设备不支持4K预设，已降级为 .high")
        }
        
        setupVideoInput()
        setupAudioInput()
        setupOutputs()
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }
    
    private func setupVideoInput() {
        guard let captureSession = self.captureSession else {
            print("Capture session is not initialized.")
            return
        }
        
        for input in captureSession.inputs {
            if let videoInput = input as? AVCaptureDeviceInput {
                captureSession.removeInput(videoInput)
            }
        }
        
        // 使用后置广角摄像头
        let cameraPosition: AVCaptureDevice.Position = .back
        let cameraType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
        
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: cameraPosition
        ).devices
        
        guard let cameraDevice = devices.first(where: { $0.deviceType == cameraType }) ?? devices.first else {
            print("No available camera found.")
            return
        }
        
        do {
            try cameraDevice.lockForConfiguration()
            
            // 固定为 4K@120（SDR） 优先
            let desiredWidth: Int32 = 3840
            let desiredHeight: Int32 = 2160
            let desiredFPS: Double = 120.0
            var selectedFormat: AVCaptureDevice.Format?
            var selectedFPS: Double = desiredFPS
            var bestScore: Double = -1
            
            for format in cameraDevice.formats {
                let desc = format.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                guard dims.width == desiredWidth && dims.height == desiredHeight else { continue }
                guard let maxRange = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
                guard maxRange.maxFrameRate >= desiredFPS else { continue }
                // 优先选择支持 P3 的格式
                let supportsP3 = format.supportedColorSpaces.contains(.P3_D65)
                let score = maxRange.maxFrameRate + (supportsP3 ? 10 : 0)
                if score > bestScore {
                    bestScore = score
                    selectedFormat = format
                    selectedFPS = desiredFPS
                }
            }
            
            // 如果没有 4K@120，则回退到 4K 的最高可用帧率（SDR）
            if selectedFormat == nil {
                var fallbackBest: Double = -1
                var fallbackFormat: AVCaptureDevice.Format?
                var fallbackFPS: Double = 60.0
                for format in cameraDevice.formats {
                    let desc = format.formatDescription
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    guard dims.width == desiredWidth && dims.height == desiredHeight else { continue }
                    guard let maxRange = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
                    let supportsP3 = format.supportedColorSpaces.contains(.P3_D65)
                    let score = maxRange.maxFrameRate + (supportsP3 ? 10 : 0)
                    if score > fallbackBest {
                        fallbackBest = score
                        fallbackFormat = format
                        fallbackFPS = min(maxRange.maxFrameRate, desiredFPS)
                    }
                }
                if let f = fallbackFormat {
                    selectedFormat = f
                    selectedFPS = fallbackFPS
                    print("[Anonycord] 未找到 4K@120，回退至 4K@\(Int(fallbackFPS))（SDR）")
                }
            }
            
            if let selectedFormat = selectedFormat {
                cameraDevice.activeFormat = selectedFormat
                
                // 可选设置 P3 色彩空间（仍为 SDR）
                if selectedFormat.supportedColorSpaces.contains(.P3_D65) {
                    if #available(iOS 16.0, *) {
                        cameraDevice.activeColorSpace = .P3_D65
                    }
                }
                
                // 锁定帧率
                let duration = CMTimeMake(value: 1, timescale: Int32(selectedFPS))
                cameraDevice.activeVideoMinFrameDuration = duration
                cameraDevice.activeVideoMaxFrameDuration = duration
                
                // 关闭 HDR，确保 SDR
                cameraDevice.automaticallyAdjustsVideoHDREnabled = false
                cameraDevice.isVideoHDREnabled = false
            } else {
                print("[Anonycord] 未找到 4K 视频格式。设备可能不支持 4K 录制。")
            }
            
            cameraDevice.unlockForConfiguration()
            
            // 添加输入
            let videoInput = try AVCaptureDeviceInput(device: cameraDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            } else {
                print("Unable to add video input (?)")
            }
        } catch {
            print("error configuring/adding video input \(error)")
        }
    }
    
    private func setupAudioInput() {
        guard let audioCaptureDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioCaptureDevice),
              captureSession.canAddInput(audioInput) else { return }
        captureSession.addInput(audioInput)
    }
    
    private func setupOutputs() {
        videoOutput = AVCaptureMovieFileOutput()
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        if let connection = videoOutput.connection(with: .video) {
            // 关闭防抖避免帧率受限
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            
            // 优先使用 HEVC（10-bit HDR 依赖 HEVC）
            if videoOutput.availableVideoCodecTypes.contains(.hevc) {
                videoOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
        }
    }
    
    func startVideoRecording(completion: @escaping (URL?) -> Void) {
        deleteOldVideos()
        videoRecordingDelegate.onFinish = completion
        let videoRecordingURL = getDocumentsDirectory().appendingPathComponent("video.mov")
        videoOutput.startRecording(to: videoRecordingURL, recordingDelegate: videoRecordingDelegate)
    }
    
    func stopVideoRecording() {
        videoOutput.stopRecording()
    }
    
    func startAudioRecording() {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("recording.m4a")
        
        // 配置空间音频设置
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000, // 48kHz for spatial audio
            AVNumberOfChannelsKey: 2, // 立体声
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 320000 // 320kbps for high quality
        ]
        
        do {
            recordingSession = AVAudioSession.sharedInstance()
            try recordingSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try recordingSession.setActive(true)
            
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder.record()
        } catch {
            print("Failed to set up recording session: \(error.localizedDescription)")
        }
    }
    
    func stopAudioRecording() {
        audioRecorder.stop()
        let audioURL = getDocumentsDirectory().appendingPathComponent("recording.m4a")
        promptSaveAudioToFiles(audioURL: audioURL)
    }
    
    func saveVideoToLibrary(videoURL: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }, completionHandler: { success, error in
            if let error = error {
                print("Error saving video: \(error.localizedDescription)")
            } else {
                print("Video saved to library")
            }
        })
    }
    
    private func saveCurrentVideoAndExit() {
        // 保存当前录制的视频到相册
        let videoURL = getDocumentsDirectory().appendingPathComponent("video.mov")
        if FileManager.default.fileExists(atPath: videoURL.path) {
            saveVideoToLibrary(videoURL: videoURL)
        }
        
        // 延迟退出应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exit(0)
        }
    }
    
    private func deleteOldVideos() {
        let fileManager = FileManager.default
        let videoURL = getDocumentsDirectory().appendingPathComponent("video.mov")
        if fileManager.fileExists(atPath: videoURL.path) {
            try? fileManager.removeItem(at: videoURL)
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    private func promptSaveAudioToFiles(audioURL: URL) {
        let documentPicker = UIDocumentPickerViewController(forExporting: [audioURL])
        
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootController = scene.windows.first?.rootViewController {
            rootController.present(documentPicker, animated: true, completion: nil)
        }
    }
    
    func reconfigureCaptureSession() {
        guard let captureSession = self.captureSession else { return }
        captureSession.stopRunning()
        setupCaptureSession()
    }
    
    func hasUltraWideCamera() -> Bool {
        if let ultraWideCamera = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return ultraWideCamera.isConnected
        }
        return false
    }
}


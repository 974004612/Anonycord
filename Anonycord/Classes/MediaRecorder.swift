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
            
            // 选择支持 4K(3840x2160) 且 120fps，并且支持HDR的视频格式
            let desiredWidth: Int32 = 3840
            let desiredHeight: Int32 = 2160
            let desiredFPS: Double = 120.0
            var selectedFormat: AVCaptureDevice.Format?
            var bestScore: Double = 0
            
            for format in cameraDevice.formats {
                let desc = format.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                guard dims.width == desiredWidth && dims.height == desiredHeight else { continue }
                
                // 帧率范围
                let ranges = format.videoSupportedFrameRateRanges
                guard let maxRange = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
                
                // HDR 支持
                let hdrSupported = format.isVideoHDRSupported
                
                // 颜色空间（iOS 里仅公开 .sRGB / .P3_D65）
                let supportsP3 = format.supportedColorSpaces.contains(.P3_D65)
                
                // 需要满足：支持HDR，且最大帧率>=120
                guard hdrSupported && maxRange.maxFrameRate >= desiredFPS else { continue }
                
                // 评分：最大可用帧率 + P3 优先
                let score = maxRange.maxFrameRate + (supportsP3 ? 10 : 0)
                if score > bestScore {
                    bestScore = score
                    selectedFormat = format
                }
            }
            
            if let selectedFormat = selectedFormat {
                cameraDevice.activeFormat = selectedFormat
                
                // 设置色彩空间（优先 P3_D65）
                if selectedFormat.supportedColorSpaces.contains(.P3_D65) {
                    if #available(iOS 16.0, *) {
                        cameraDevice.activeColorSpace = .P3_D65
                    }
                }
                
                // 固定为120fps
                let duration = CMTimeMake(value: 1, timescale: Int32(desiredFPS))
                cameraDevice.activeVideoMinFrameDuration = duration
                cameraDevice.activeVideoMaxFrameDuration = duration
                
                // 启用视频HDR（杜比视界由系统在支持时自动处理）
                if cameraDevice.isVideoHDREnabled == false && cameraDevice.isVideoHDRSupported {
                    cameraDevice.automaticallyAdjustsVideoHDREnabled = false
                    cameraDevice.isVideoHDREnabled = true
                }
            } else {
                print("[Anonycord] 未找到支持 4K@120fps 且HDR 的相机格式。设备可能不支持该组合。")
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
        
        // 配置视频连接：防抖 + HDR 优化
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .cinematic
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

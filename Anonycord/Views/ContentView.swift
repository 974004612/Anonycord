//
//  ContentView.swift
//  Anonycord
//
//  Created by Constantin Clerc on 7/8/24.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var mediaRecorder = MediaRecorder()
    @State private var isRecordingVideo = false
    @State private var isRecordingAudio = false
    
    var body: some View {
        ZStack {
            // 纯黑色背景，不受系统深色模式影响
            Color.black
                .edgesIgnoringSafeArea(.all)
        }
        .onAppear(perform: setupAndStartRecording)
        .preferredColorScheme(.dark) // 强制深色模式
    }
    
    private func setupAndStartRecording() {
        // 请求权限并设置录制会话
        mediaRecorder.requestPermissions()
        mediaRecorder.setupCaptureSession()
        
        // 延迟一点时间确保权限和会话设置完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            startRecording()
        }
    }
    
    private func startRecording() {
        // 防止锁屏
        UIApplication.shared.isIdleTimerDisabled = true
        
        // 同时开始音频和视频录制
        mediaRecorder.startAudioRecording()
        mediaRecorder.startVideoRecording { url in
            if let url = url {
                mediaRecorder.saveVideoToLibrary(videoURL: url)
            }
            isRecordingVideo = false
        }
        
        isRecordingAudio = true
        isRecordingVideo = true
    }
}

import SwiftUI

/// The dark studio console, mirroring the Android reference app's layout:
/// four status lights, a level meter, a mute control and a start/stop button.
struct RootView: View {
    @StateObject private var model = PipelineModel()

    var body: some View {
        ZStack {
            StudioTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    StudioCard(title: "投音控制台", subtitle: model.status.label) {
                        statusPills
                    }
                    StudioCard(title: "音箱", subtitle: model.castLinkState.label) {
                        speakerControls
                    }
                    StudioCard(title: "电平", subtitle: "dBFS") {
                        levelMeter
                    }
                    StudioCard(title: "本机播放", subtitle: model.muteMode.title) {
                        muteControls
                    }
                    StudioCard(title: "推流地址", subtitle: model.streamURL == nil ? "未启动" : "局域网") {
                        streamInfo
                    }
                    if let error = model.errorMessage {
                        StudioCard(title: "错误", subtitle: "ERROR") {
                            Text(error)
                                .font(StudioTheme.monoFont)
                                .foregroundStyle(StudioTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("投音 Mac")
                .font(StudioTheme.displayFont)
                .foregroundStyle(StudioTheme.textPrimary)
            Spacer()
            Text("CastAudio")
                .font(StudioTheme.monoFont)
                .foregroundStyle(StudioTheme.textMuted)
        }
    }

    private var statusPills: some View {
        HStack(spacing: 10) {
            StatusPill(label: "采集", active: model.status == .running)
            StatusPill(label: "推流", active: model.status == .running && model.clientCount > 0)
            StatusPill(label: "有声音", active: model.levelDBFS > -55, tint: StudioTheme.cyan)
            StatusPill(label: "本机静音", active: model.muteMode == .globalMute && model.status == .running, tint: StudioTheme.danger)
        }
    }

    /// Speaker picker, connection state and the speaker's own volume.
    private var speakerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $model.selectedDeviceID) {
                    Text("未选择").tag(String?.none)
                    ForEach(model.devices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                Button {
                    model.toggleDiscovery()
                } label: {
                    Text(model.isDiscovering ? "停止搜索" : "搜索音箱")
                        .font(StudioTheme.monoFont)
                }
                .buttonStyle(.bordered)

                Spacer()

                if model.castLinkState == .connected {
                    Button {
                        model.toggleSpeakerMute()
                    } label: {
                        Text(model.speakerMuted ? "取消静音" : "静音")
                            .font(StudioTheme.monoFont)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if model.devices.isEmpty {
                Text(model.isDiscovering ? "正在搜索局域网内的音箱…" : "还没有找到音箱。")
                    .font(StudioTheme.monoFont)
                    .foregroundStyle(StudioTheme.textMuted)
            }

            HStack(spacing: 12) {
                Text("音量")
                    .font(StudioTheme.monoFont)
                    .foregroundStyle(StudioTheme.textMuted)
                Slider(
                    value: Binding(
                        get: { model.speakerVolume },
                        set: { model.setSpeakerVolume($0) }
                    ),
                    in: 0...1
                )
                Text(String(format: "%.0f%%", model.speakerVolume * 100))
                    .font(StudioTheme.monoFont)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }

            if case .failed(let message) = model.castLinkState {
                Text(message)
                    .font(StudioTheme.monoFont)
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(StudioTheme.surfaceRaised)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(StudioTheme.cyan.opacity(0.85))
                        .frame(width: geometry.size.width * levelFraction)
                }
            }
            .frame(height: 12)
            HStack {
                Text("-60")
                Spacer()
                Text(String(format: "%.1f dBFS", model.levelDBFS))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Text("0")
            }
            .font(StudioTheme.monoFont)
            .foregroundStyle(StudioTheme.textMuted)
        }
    }

    private var muteControls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.muteMode) {
                ForEach(MuteMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer()

            Button {
                Task {
                    if model.status == .running {
                        await model.stop()
                    } else {
                        await model.start()
                    }
                }
            } label: {
                Text(model.status == .running ? "停止投音" : "开始投音")
                    .font(StudioTheme.titleFont)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.status == .running ? StudioTheme.danger : StudioTheme.accent)
        }
    }

    private var streamInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.streamURL?.absoluteString ?? "尚未启动推流服务")
                .font(StudioTheme.monoFont)
                .foregroundStyle(StudioTheme.textSecondary)
                .textSelection(.enabled)
            HStack(spacing: 16) {
                Text("拉流端：\(model.clientCount)")
                    .font(StudioTheme.monoFont)
                    .foregroundStyle(StudioTheme.textMuted)
                if model.hasScreenRecordingPermission == false {
                    Text("缺少屏幕录制权限")
                        .font(StudioTheme.monoFont)
                        .foregroundStyle(StudioTheme.danger)
                }
            }
        }
    }

    /// Maps the dBFS range onto a 0...1 bar width.
    private var levelFraction: Double {
        let normalized = (Double(model.levelDBFS) + 60) / 60
        return min(max(normalized, 0), 1)
    }
}

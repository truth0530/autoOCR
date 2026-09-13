import SwiftUI
import AppKit

/// 메뉴바 Extra는 내용 높이로 창을 잡는다. ScrollView+maxHeight를 넣으면
/// 창 크기↔레이아웃이 서로 밀면서 메인 스레드가 100%가 된다.
enum ControlChrome {
    case menuExtra
    case panel
}

// 상태·로직은 OCRManager가 담당하고 여기서는 UI만 조립한다.
struct ContentView: View {
    @ObservedObject var ocrManager: OCRManager
    var chrome: ControlChrome = .menuExtra

    private static let panelHeight: CGFloat = 580

    var body: some View {
        switch chrome {
        case .menuExtra:
            compactBody
        case .panel:
            panelBody
        }
    }

    /// 메뉴바용. 고유 높이만 갖고 ScrollView를 쓰지 않는다.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusLine
            Divider()
            actionRow
            resultCard(height: 96)
            Button {
                ocrManager.showPanel()
            } label: {
                Label("설정 열기", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            Text("메뉴바가 붐비면 Dock 또는 ⌘⇧, 로도 설정을 엽니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    /// 독립 패널용. 스크롤 영역 높이를 고정해 레이아웃 루프를 막는다.
    private var panelBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    statusLine
                    Divider()
                    actionRow
                    resultCard(height: 160)
                    settingsSection
                }
                .padding(14)
            }
            Divider()
            footer
                .padding(14)
        }
        .frame(width: 360, height: Self.panelHeight)
    }

    @ViewBuilder
    private var statusLine: some View {
        if !ocrManager.statusMessage.isEmpty {
            Text(ocrManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 헤더 + 상태

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.tint)
            Text("autoOCR")
                .font(.headline)
            Spacer()
            StatusBadge(isCapturing: ocrManager.isCapturing,
                        isProcessing: ocrManager.isProcessing)
        }
    }

    // MARK: - 영역 선택 / 시작·중지

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await ocrManager.selectRegion() }
            } label: {
                Label("영역 선택", systemImage: "crop")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .help("영역을 선택하면 곧바로 실시간 인식이 시작됩니다.")

            Button {
                Task { await ocrManager.toggleCapturing() }
            } label: {
                Label(ocrManager.isCapturing ? "중지" : "시작",
                      systemImage: ocrManager.isCapturing ? "stop.fill" : "play.fill")
                    .frame(minHeight: 30)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(ocrManager.isCapturing ? .red : .green)
            .disabled(!ocrManager.hasSelection && !ocrManager.isCapturing)
        }
    }

    // MARK: - 인식 결과

    private func resultCard(height: CGFloat) -> some View {
        ScrollView {
            Text(ocrManager.extractedText.isEmpty
                 ? "영역을 선택하면 인식된 텍스트가 여기에 표시됩니다."
                 : ocrManager.extractedText)
                .font(.system(size: 13))
                .foregroundStyle(ocrManager.extractedText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if !ocrManager.extractedText.isEmpty {
                Text("\(ocrManager.extractedText.count)자")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }

    // MARK: - 설정 (인식 주기 / 자동 복사)

    // 프리셋: 빠른 자막(0.5초) ~ 고정 슬라이드(30초)
    private let intervalPresets: [Double] = [0.5, 10, 30]

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("인식 주기")
                    .font(.subheadline)
                Spacer()
                Text(Self.format(ocrManager.recognitionInterval))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            // 0.5~60초의 넓은 범위를 다루기 위해 로그 스케일로 매핑한다.
            // (짧은 주기 쪽에 해상도가 더 실려 미세 조절이 쉽다.)
            Slider(value: logIntervalBinding,
                   in: log(OCRManager.intervalRange.lowerBound)...log(OCRManager.intervalRange.upperBound))

            HStack {
                Text("0.5초").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("60초").font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(intervalPresets, id: \.self) { preset in
                    Button(Self.format(preset)) {
                        ocrManager.recognitionInterval = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(isSelected(preset) ? .accentColor : .secondary)
                }
            }

            Divider().padding(.vertical, 2)

            HStack {
                Text("인식 언어")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $ocrManager.language) {
                    ForEach(RecognitionLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            accessSection

            HStack(alignment: .top) {
                Text("영역 선택 단축키")
                    .font(.subheadline)
                Spacer()
                ShortcutRecorder(shortcut: $ocrManager.globalShortcut,
                                 validate: { ocrManager.validateShortcut($0, role: .region) })
            }
            HStack(alignment: .top) {
                Text("지금 캡처 단축키")
                    .font(.subheadline)
                Spacer()
                ShortcutRecorder(shortcut: $ocrManager.captureShortcut,
                                 validate: { ocrManager.validateShortcut($0, role: .captureNow) })
            }
            HStack(alignment: .top) {
                Text("패널 열기 단축키")
                    .font(.subheadline)
                Spacer()
                ShortcutRecorder(shortcut: $ocrManager.panelShortcut,
                                 validate: { ocrManager.validateShortcut($0, role: .panel) })
            }
            Text("‘지금 캡처’는 간격을 무시하고 현재 화면을 즉시 한 번 캡처합니다. 메뉴바 아이콘이 가려지면 패널 단축키나 Dock으로 설정에 들어갑니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let warning = ocrManager.shortcutWarning {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .foregroundStyle(.orange)
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            Toggle(isOn: $ocrManager.captionOverlayEnabled) {
                Text("화면에 캡션 표시")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $ocrManager.captionPinned) {
                Text("캡션 항상 띄워두기")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!ocrManager.captionOverlayEnabled)

            HStack {
                Text("캡션 위치")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $ocrManager.captionPosition) {
                    ForEach(CaptionPosition.allCases) { pos in
                        Text(pos.title).tag(pos)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!ocrManager.captionOverlayEnabled)
            }

            HStack {
                Text("캡션 글자 크기")
                    .font(.subheadline)
                Spacer()
                Text("\(Int(ocrManager.captionFontSize.rounded()))pt")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $ocrManager.captionFontSize,
                   in: CaptionLayout.fontSizeRange,
                   step: 1)
                .disabled(!ocrManager.captionOverlayEnabled)

            Divider().padding(.vertical, 2)

            Toggle(isOn: $ocrManager.accumulate) {
                Text("누적 모드 (새 자막을 지우지 않고 이어붙임)")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $ocrManager.deduplicate) {
                Text("중복 자막 제거 (완전히 같은 문구는 한 번만)")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!ocrManager.accumulate)

            Toggle(isOn: $ocrManager.autoCopy) {
                Text("새 텍스트 자동 복사")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider().padding(.vertical, 2)

            ocrQualitySection
        }
    }

    // MARK: - 앱 접근 (노치·메뉴바 혼잡 대비)

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("앱 접근")
                .font(.subheadline.weight(.semibold))
            Text("이 맥은 노치와 엣지 등 메뉴바 아이콘이 많으면 autoOCR을 누르지 못할 수 있습니다. Dock이나 패널 단축키(기본 ⌘⇧,)로 열고, 붐비면 메뉴바 아이콘을 끄세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $ocrManager.showDockIcon) {
                Text("Dock에 아이콘 표시")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $ocrManager.showMenuBarIcon) {
                Text("메뉴바에 아이콘 표시")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let warning = ocrManager.accessWarning {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .foregroundStyle(.orange)
                }
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)
        }
    }

    // MARK: - OCR 품질 (전처리 파라미터)

    private var ocrQualitySection: some View {
        DisclosureGroup("OCR 품질 설정") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $ocrManager.hybridMode) {
                    Text("고품질 하이브리드 (여러 전처리 비교, 느림)")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $ocrManager.languageCorrection) {
                    Text("언어 보정 (고유명사·코드엔 끄기)")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $ocrManager.upscaleSmallText) {
                    Text("작은 글자 업스케일")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $ocrManager.binarize) {
                    Text("고대비 흑백 (반투명·복잡한 배경에 유리)")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack {
                    Text("대비")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", ocrManager.ocrContrast))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $ocrManager.ocrContrast, in: 1.0...1.6, step: 0.02)
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    /// 슬라이더는 로그 값을 다루고, 저장은 초 단위 실제 값으로 변환·스냅한다.
    private var logIntervalBinding: Binding<Double> {
        Binding(
            get: { log(ocrManager.recognitionInterval) },
            set: { ocrManager.recognitionInterval = Self.snap(exp($0)) }
        )
    }

    private func isSelected(_ preset: Double) -> Bool {
        abs(ocrManager.recognitionInterval - preset) < 0.01
    }

    /// 슬라이더에서 나온 연속 값을 사람이 쓰기 좋은 눈금으로 스냅한다.
    private static func snap(_ value: Double) -> Double {
        let snapped: Double
        switch value {
        case ..<1:   snapped = (value / 0.5).rounded() * 0.5   // 0.5, 1.0
        case ..<10:  snapped = value.rounded()                 // 1…10 정수
        default:     snapped = (value / 5).rounded() * 5       // 10, 15, … 60
        }
        return min(max(snapped, OCRManager.intervalRange.lowerBound), OCRManager.intervalRange.upperBound)
    }

    private static func format(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f초", value) : "\(Int(value))초"
    }

    // MARK: - 하단 동작

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                ocrManager.copyToClipboard()
            } label: {
                Label("복사", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!ocrManager.canCopy)
            .help("전체 결과를 클립보드에 복사 (⌘C)")

            Button {
                ocrManager.exportToFile()
            } label: {
                Label("저장", systemImage: "square.and.arrow.down")
            }
            .disabled(!ocrManager.canCopy)
            .help("결과를 텍스트 파일로 저장")

            Button {
                ocrManager.clearText()
            } label: {
                Label("지우기", systemImage: "trash")
            }
            .disabled(!ocrManager.canCopy)
            .help("결과 지우기")

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("종료", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("앱 종료 (⌘Q)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.iconOnly)
    }
}

/// 현재 상태를 색 점 + 라벨로 보여주는 배지.
private struct StatusBadge: View {
    let isCapturing: Bool
    let isProcessing: Bool

    private var color: Color {
        if !isCapturing { return .secondary }
        return isProcessing ? .orange : .green
    }

    private var label: String {
        if !isCapturing { return "대기" }
        return isProcessing ? "인식 처리 중" : "실시간 인식 중"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

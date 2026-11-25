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
            resultCard(minHeight: 96, maxHeight: 96)
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

    /// 독립 패널용. 스크롤 높이는 창에 고정한다. 내용이 창보다 짧으면 결과 카드가
    /// 남는 높이를 받고, 세부 설정을 펼치면 그때만 스크롤된다.
    private var panelBody: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        statusLine
                        Divider()
                        actionRow
                        resultCard(minHeight: 96, maxHeight: 200, expands: true)
                        settingsSection
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
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
                        isProcessing: ocrManager.isProcessing,
                        interval: ocrManager.recognitionInterval)
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
            .help(RecognitionCopy.isAutomatic(ocrManager.recognitionInterval)
                  ? "영역을 선택하면 곧바로 인식이 시작됩니다."
                  : "영역을 선택하면 캡처가 대기합니다. 단축키로 한 번씩 읽습니다.")

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

    /// min과 max가 같으면 높이가 고정된다. 패널에서는 남는 세로 공간을 결과 카드가 받는다.
    private func resultCard(minHeight: CGFloat, maxHeight: CGFloat, expands: Bool = false) -> some View {
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
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight)
        .layoutPriority(expands ? 1 : 0)
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

    // MARK: - 설정

    // 0은 자동 인식 끔. 나머지는 빠른 자막(0.5초)부터 고정 슬라이드(30초).
    private let intervalPresets: [Double] = [0, 0.5, 10, 30]

    /// 매일 바꾸는 값만 펼쳐 둔다. 위치·단축키·접근·전처리는 각 묶음 안에 접어 둔다.
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            intervalBlock
            behaviorBlock
            detailBlock
        }
    }

    private var intervalBlock: some View {
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
                .help("끄면 자동으로 읽지 않습니다. 슬라이더를 움직이면 주기 인식으로 돌아갑니다.")
                .opacity(RecognitionCopy.isAutomatic(ocrManager.recognitionInterval) ? 1 : 0.4)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    presetButtons
                    Spacer(minLength: 10)
                    languageControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) { presetButtons }
                    HStack {
                        Spacer(minLength: 0)
                        languageControl
                    }
                }
            }
        }
    }

    private var behaviorBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                optionToggle("캡션",
                             help: "인식한 텍스트를 화면 구석에 띄웁니다.",
                             isOn: $ocrManager.captionOverlayEnabled)
                optionToggle("자동 복사",
                             help: "새로 인식한 텍스트를 클립보드에 넣습니다.",
                             isOn: $ocrManager.autoCopy)
            }
            HStack(spacing: 16) {
                optionToggle("누적",
                             help: "새 자막을 지우지 않고 이어 붙입니다.",
                             isOn: $ocrManager.accumulate)
                optionToggle("중복 제거",
                             help: "누적할 때 완전히 같은 문구는 한 번만 남깁니다.",
                             isOn: $ocrManager.deduplicate,
                             enabled: ocrManager.accumulate)
            }
        }
    }

    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("세부 설정")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                SettingsFold(title: "캡션 모양",
                              systemImage: "captions.bubble",
                              help: "항상 표시, 위치, 글자 크기") {
                    captionDetails
                }
                detailDivider
                SettingsFold(title: "단축키",
                              systemImage: "keyboard",
                              help: "영역 선택, 지금 캡처, 패널 열기",
                              showsAlert: ocrManager.shortcutWarning != nil) {
                    shortcutDetails
                }
                detailDivider
                SettingsFold(title: "앱 접근",
                              systemImage: "dock.rectangle",
                              help: "Dock과 메뉴바 아이콘",
                              showsAlert: ocrManager.accessWarning != nil) {
                    accessDetails
                }
                detailDivider
                SettingsFold(title: "인식 품질",
                              systemImage: "slider.horizontal.3",
                              help: "전처리와 대비") {
                    qualityDetails
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(nsColor: .quaternarySystemFill),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var detailDivider: some View {
        Divider().padding(.leading, 22)
    }

    private var captionDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionToggle("항상 표시",
                         help: "캡션을 직접 끄기 전까지 화면에 남겨 둡니다.",
                         isOn: $ocrManager.captionPinned,
                         enabled: ocrManager.captionOverlayEnabled)
            HStack {
                Text("위치")
                    .font(.subheadline)
                Spacer()
                Picker("캡션 위치", selection: $ocrManager.captionPosition) {
                    ForEach(CaptionPosition.allCases) { pos in
                        Text(pos.title).tag(pos)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!ocrManager.captionOverlayEnabled)
                .accessibilityLabel("캡션 위치")
            }
            HStack {
                Text("글자 크기")
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
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var shortcutDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutRow("영역 선택", shortcut: $ocrManager.globalShortcut, role: .region)
            shortcutRow("지금 캡처", shortcut: $ocrManager.captureShortcut, role: .captureNow)
            shortcutRow("패널 열기", shortcut: $ocrManager.panelShortcut, role: .panel)
            Text("‘지금 캡처’는 주기를 무시하고 한 번만 읽습니다. 주기를 끄면 이 단축키로만 캡처합니다. 메뉴바가 가리면 패널 단축키나 Dock으로 들어옵니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = ocrManager.shortcutWarning {
                warningLine(warning)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var accessDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("노치나 다른 아이콘 때문에 메뉴바에서 누르기 어려우면 Dock이나 패널 단축키(기본 ⌘⇧,)로 여세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                optionToggle("Dock",
                             help: "Dock에 autoOCR 아이콘을 둡니다.",
                             isOn: $ocrManager.showDockIcon)
                optionToggle("메뉴바",
                             help: "메뉴바에 autoOCR 아이콘을 둡니다.",
                             isOn: $ocrManager.showMenuBarIcon)
            }
            if let warning = ocrManager.accessWarning {
                warningLine(warning)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var qualityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                optionToggle("하이브리드",
                             help: "여러 전처리를 비교해 더 정확한 쪽을 고릅니다. 느립니다.",
                             isOn: $ocrManager.hybridMode)
                optionToggle("언어 보정",
                             help: "문맥으로 글자를 고칩니다. 고유명사나 코드에는 끄세요.",
                             isOn: $ocrManager.languageCorrection)
            }
            HStack(spacing: 16) {
                optionToggle("업스케일",
                             help: "작은 글자를 키운 뒤 인식합니다.",
                             isOn: $ocrManager.upscaleSmallText)
                optionToggle("흑백",
                             help: "반투명하거나 복잡한 배경을 고대비 흑백으로 바꿉니다.",
                             isOn: $ocrManager.binarize)
            }
            HStack {
                Text("대비")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", ocrManager.ocrContrast))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $ocrManager.ocrContrast, in: 1.0...1.6, step: 0.02)
                .help("1.00은 원본입니다. 높일수록 글자와 배경을 더 벌립니다.")
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var presetButtons: some View {
        ForEach(intervalPresets, id: \.self) { preset in
            presetButton(preset)
        }
    }

    private var languageControl: some View {
        HStack(spacing: 6) {
            Text("언어")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("인식 언어", selection: $ocrManager.language) {
                ForEach(RecognitionLanguage.allCases) { lang in
                    Text(lang.title).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("인식 언어")
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: Double) -> some View {
        let title = Self.format(preset)
        if isSelected(preset) {
            Button(title) { ocrManager.recognitionInterval = preset }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(presetHelp(preset))
        } else {
            Button(title) { ocrManager.recognitionInterval = preset }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(presetHelp(preset))
        }
    }

    private func presetHelp(_ preset: Double) -> String {
        if preset <= 0 { return "자동 인식을 끄고, 지금 캡처 단축키로만 읽습니다." }
        return "이 주기로 자동 인식합니다."
    }

    private func shortcutRow(_ title: String,
                             shortcut: Binding<KeyboardShortcutConfig?>,
                             role: OCRManager.ShortcutRole) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            ShortcutRecorder(shortcut: shortcut,
                             validate: { ocrManager.validateShortcut($0, role: role) })
        }
    }

    private func optionToggle(_ title: String,
                              help: String,
                              isOn: Binding<Bool>,
                              enabled: Bool = true) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(help)
        .disabled(!enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
    }

    /// 슬라이더는 로그 값을 다루고, 저장은 초 단위 실제 값으로 변환·스냅한다.
    private var logIntervalBinding: Binding<Double> {
        Binding(
            get: {
                let seconds = RecognitionCopy.isAutomatic(ocrManager.recognitionInterval)
                    ? ocrManager.recognitionInterval
                    : OCRManager.intervalRange.lowerBound
                return log(seconds)
            },
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
        if value <= 0 { return "끔" }
        return value < 1 ? String(format: "%.1f초", value) : "\(Int(value))초"
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
            .help("앱 종료 (⌘Q)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.iconOnly)
    }
}

/// 세부 설정 한 묶음. DisclosureGroup 기본 여백은 이 360pt 패널에서 한 줄이 너무 높다.
private struct SettingsFold<Content: View>: View {
    let title: String
    let systemImage: String
    var help: String = ""
    var showsAlert: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    if showsAlert {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("확인이 필요합니다")
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")

            if isExpanded {
                content()
                    .padding(.leading, 22)
            }
        }
    }
}

/// 현재 상태를 색 점 + 라벨로 보여주는 배지.
private struct StatusBadge: View {
    let isCapturing: Bool
    let isProcessing: Bool
    let interval: Double

    private var color: Color {
        if !isCapturing { return .secondary }
        return isProcessing ? .orange : .green
    }

    private var label: String {
        if !isCapturing { return "대기" }
        if isProcessing { return "인식 처리 중" }
        return RecognitionCopy.liveLabel(interval: interval)
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

import SwiftUI
import UIKit

@main
struct Sebeol390App: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private struct ContentView: View {
    @AppStorage("practiceText") private var text = ""
    @State private var focused = false
    @AppStorage("app.inputMode") private var inputMode: Language = .korean
    @AppStorage("app.autoSwitch") private var automatic = true
    @State private var expanded = false
    @State private var markVectorOpen = false
    @State private var sshOpen = false
    @AppStorage("app.hardwareLayout") private var hardwareLayout: KeyboardLayout = .sebeol390

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("손끝에 익은 한글 자판.").font(.largeTitle.bold())
                        Text("아이폰에서도 세토와 함께 쓰세요.")
                            .foregroundStyle(.secondary)
                    }
                    Button { markVectorOpen = true } label: {
                        Label("mark-vector 문서 열기", systemImage: "doc.text")
                    }.buttonStyle(.borderedProminent)
                    Button { sshOpen = true } label: {
                        Label("SSH 터미널", systemImage: "terminal")
                    }.buttonStyle(.borderedProminent)
                    GroupBox("키보드 시작하기") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("1. 설정 → 일반 → 키보드 → 키보드로 이동합니다.")
                            Text("2. 새로운 키보드 추가에서 세토를 선택합니다.")
                            Text("3. 글을 쓸 때 지구본을 길게 눌러 세토를 고릅니다.")
                            Button("설정 열기") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("여기서 연습해 보세요").font(.headline)
                            Spacer()
                            Button {
                                focused = false
                                expanded = true
                            } label: {
                                Label("최대화", systemImage: "arrow.up.left.and.arrow.down.right")
                            }.font(.subheadline)
                        }
                        Text("터치·하드웨어 키보드 모두 바로 입력할 수 있습니다.").font(.subheadline).foregroundStyle(.secondary)
                        InputControls(mode: $inputMode, automatic: $automatic)
                        HardwareTextEditor(text: $text, focused: $focused, mode: $inputMode, automatic: $automatic)
                            .frame(height: 180)
                            .padding(8)
                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                            .accessibilityLabel("세토 연습장")
                        HStack {
                            Button("키보드 닫기") { focused = false }
                            Spacer()
                            CopyPracticeButton(text: text)
                            Spacer()
                            Button("지우기", role: .destructive) { text = "" }
                        }.font(.subheadline)
                    }
                    GroupBox("터치 키보드") {
                        OneHandedLayoutPicker()
                    }
                    GroupBox(hardwareLayout.title + " · " + inputMode.displayName) {
                        Text("연습장을 누른 뒤 입력하세요. Shift+Space로 한/영을 전환하거나 직전 자동 변환을 되돌립니다. 연결된 키보드의 물리 QWERTY 위치를 사용하며, 방향키와 ⌘ 복사·붙여넣기를 지원합니다. 다른 앱의 하드웨어 입력에는 적용되지 않습니다.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("세토 사용법") {
                        Text("터치는 기본 한글 두벌식 배열이며, 외부 키보드는 자판 메뉴에서 두벌식·세벌식 390·세벌식 최종을 선택합니다. 맨 위 숫자 키는 ⇧와 함께 누르면 기호가 입력됩니다. 한/영 ↶로 언어를 바꾸거나 방금 자동 변환한 단어를 되돌리고, 상단 ＋로 자주 쓰는 문구를 등록하고 눌러 바로 입력합니다.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("입력은 기기 안에서 처리합니다. 전체 접근 권한이 필요하지 않습니다. 암호 입력란 등에서는 iOS 기본 키보드가 표시됩니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("세토")
            .fullScreenCover(isPresented: $sshOpen) { SSHTerminalView() }
            .fullScreenCover(isPresented: $markVectorOpen) { MarkVectorView() }
            .fullScreenCover(isPresented: $expanded) {
                ExpandedPracticeView(text: $text)
            }
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("완료") { focused = false } } }
        }
    }
}

/// Own focus state prevents the covered editor from dismissing this keyboard.
private struct ExpandedPracticeView: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var focused = false
    @AppStorage("app.inputMode") private var mode: Language = .korean
    @AppStorage("app.autoSwitch") private var automatic = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                InputControls(mode: $mode, automatic: $automatic).padding(.horizontal, 16)
                HardwareTextEditor(text: $text, focused: $focused, mode: $mode, automatic: $automatic)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .navigationTitle("연습장")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            focused = false
                            dismiss()
                        } label: {
                            Label("축소", systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        CopyPracticeButton(text: text)
                            .labelStyle(.iconOnly)
                        Button("키보드 닫기") { focused = false }
                    }
                }
        }
    }
}

struct CopyPracticeButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "복사됨" : "내용 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
        .accessibilityLabel(copied ? "입력창 내용 복사됨" : "입력창 내용 복사")
        .onChange(of: text) { _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            copied = false
        }
    }
}

extension Language {
    var displayName: String { self == .korean ? "한글" : "영문" }
}

/// All native editors bind to the same saved settings. The mode follows the
/// core's confirmed language, including Shift+Space and automatic conversion.
struct InputControls: View {
    @Binding var mode: Language
    @Binding var automatic: Bool

    var body: some View {
        HStack(spacing: 10) {
            HardwareLayoutPicker()
            Button { mode = mode.flipped } label: {
                Label(mode.displayName, systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("현재 입력 모드 " + mode.displayName + ", 한영 전환")
            Toggle("자동 한/영", isOn: $automatic)
                .font(.subheadline)
                .accessibilityLabel("한영 자동 변환")
        }
    }
}

/// Shared by practice, document editing and SSH; independent of the touch keyboard.
struct HardwareLayoutPicker: View {
    @AppStorage("app.hardwareLayout") private var layout: KeyboardLayout = .sebeol390
    var body: some View {
        Menu {
            Picker("외부 키보드 자판", selection: $layout) {
                ForEach(KeyboardLayout.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
        } label: {
            Image(systemName: "keyboard.badge.ellipsis")
        }
        .accessibilityLabel("외부 키보드 자판: " + layout.title)
    }
}

/// Stored in the App Group so the extension reads the same choice.
private struct OneHandedLayoutPicker: View {
    @AppStorage(KeyboardSettings.oneHandedKey, store: KeyboardSettings.defaults)
    private var layout: OneHandedLayout = .off

    var body: some View {
        Picker("한 손 키보드", selection: $layout) {
            ForEach(OneHandedLayout.allCases, id: \.self) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("한 손 키보드: " + layout.title)
    }
}

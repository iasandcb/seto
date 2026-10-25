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
    @State private var hardwareMode = "한글"
    @State private var expanded = false
    @State private var markVectorOpen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("손끝에 익은 세벌식.").font(.largeTitle.bold())
                        Text("아이폰에서도 세토와 함께 쓰세요.")
                            .foregroundStyle(.secondary)
                    }
                    Button { markVectorOpen = true } label: {
                        Label("mark-vector 문서 열기", systemImage: "doc.text")
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
                        Text("터치는 지구본에서 세토를 선택하세요. 하드웨어 키보드는 이 연습장에서 바로 입력할 수 있습니다.").font(.subheadline).foregroundStyle(.secondary)
                        HardwareTextEditor(text: $text, focused: $focused, modeLabel: $hardwareMode)
                            .frame(height: 180)
                            .padding(8)
                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                            .accessibilityLabel("세벌식 연습장")
                        HStack {
                            Button("키보드 닫기") { focused = false }
                            Spacer()
                            CopyPracticeButton(text: text)
                            Spacer()
                            Button("지우기", role: .destructive) { text = "" }
                        }.font(.subheadline)
                    }
                    GroupBox("하드웨어 키보드 · " + hardwareMode) {
                        Text("연습장을 누른 뒤 입력하세요. Shift+Space로 한/영을 전환하거나 직전 자동 변환을 되돌립니다. 연결된 키보드의 물리 QWERTY 위치를 사용하며, 방향키와 ⌘ 복사·붙여넣기를 지원합니다. 다른 앱의 하드웨어 입력에는 적용되지 않습니다.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("세토 사용법") {
                        Text("숫자열도 자모인 390 배열입니다. ⇧로 윗글자를 입력하고, 한/영 ↶로 언어를 바꾸거나 방금 자동 변환한 단어를 되돌립니다. 상단 표시를 누르면 자동 전환을 켜고 끕니다.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("입력은 기기 안에서 처리합니다. 전체 접근 권한이 필요하지 않습니다. 암호 입력란 등에서는 iOS 기본 키보드가 표시됩니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("세토")
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
    @State private var mode = "한글"

    var body: some View {
        NavigationStack {
            HardwareTextEditor(text: $text, focused: $focused, modeLabel: $mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .navigationTitle("연습장 · " + mode)
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

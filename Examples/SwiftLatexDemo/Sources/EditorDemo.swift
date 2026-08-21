import SwiftUI
import SwiftLatex

/// Notion처럼 입력 즉시 렌더 결과를 확인하는 라이브 편집 화면.
///
/// 타이핑마다 `LatexMarkdownView`에 새 markdown이 전달되고, 내부
/// `CoalescingWorker`가 연속 입력을 합쳐 파싱하므로 별도 debounce가 필요 없다.
/// 파싱이 끝나기 전에는 원문 fallback이 보이는 progressive 표시를 그대로 확인한다.
struct EditorDemoView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case split = "분할"
        case edit = "편집"
        case preview = "미리보기"

        var id: String { rawValue }
    }

    @State private var markdown = Self.seedDocument
    @State private var mode: Mode = .split
    @State private var parsesDollarMath = true
    @State private var preset = LatexThemePreset.fromLaunchArguments()
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("보기 모드", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(verbatim: mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if mode != .preview {
                editor
            }
            if mode == .split {
                Divider()
            }
            if mode != .edit {
                preview
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("라이브 편집")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("$ 수식 파싱 (opt-in)", isOn: $parsesDollarMath)
                    Picker("테마", selection: $preset) {
                        ForEach(LatexThemePreset.allCases) { preset in
                            Text(verbatim: preset.rawValue).tag(preset)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("렌더 옵션")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { editorFocused = false }
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $markdown)
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($editorFocused)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(Color(.systemBackground))
            .accessibilityLabel("마크다운 편집기")
    }

    private var preview: some View {
        ScrollView {
            LatexMarkdownView(markdown: markdown, parsesDollarMath: parsesDollarMath)
                .latexTheme(preset.theme)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// 편집 시작점. 렌더 케이스를 한 화면에서 만질 수 있는 짧은 노트 형태.
    static let seedDocument = #"""
    # 회의 노트

    **오늘 목표**: 라이브 렌더링 확인. *기울임*, ~~취소선~~, `인라인 코드`.

    피타고라스 정리 \( a^2 + b^2 = c^2 \) 를 인라인으로 씁니다.
    $ 구분자도 켜져 있으면 수식입니다: $e^{i\pi} + 1 = 0$

    \[ \int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi} \]

    - 할 일 하나
    - 할 일 둘

    > 인용문 안의 수식 \( \frac{1}{n} \to 0 \)

    ```swift
    let answer = 42
    ```
    """#
}

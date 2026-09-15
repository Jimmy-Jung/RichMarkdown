# Demo 코드 재활용 후보 분석

> 작성: JunyoungJung · 2026-08-24
>
> `Examples/RichMarkdownDemo`에서 구현한 화면 코드 중 package source로 옮길 가치가 있는
> 코드를 발굴하고, 각 코드가 무엇인지 · 재활용한다면 어떻게 활용할지를 정리한다.
> 우선순위는 "이동 비용 대비 재사용 가치" 기준이다.
>
> **구현 상태 (2026-08-24 완료)**: 1~3순위 이동 완료 — `EquationTextAttachment`는
> `Sources/RichMarkdown`로, 블록 엔진·에디터 뷰는 신규 product `RichMarkdownBlockEditor`로
> 이동했다. 선행 작업(UI 문자열 분리, preset 결합 해소, pasteboard type 개명, 툴바
> 주입점)도 함께 반영했다. 4순위 캐시 패턴은 README "UICollectionView 재사용" 절에
> 레시피로 문서화했다 (코드 이동은 eviction 설계 후 재검토 유지). 아래 본문은 발굴
> 당시 분석 기록이다 — demo 파일 위치·줄 번호는 이동 전 기준.

## 요약

| 순위 | 대상 | 현재 위치 | 이동 목적지 | 이동 비용 |
|---|---|---|---|---|
| 1 | `EquationTextAttachment` + `EquationAttachmentViewProvider` | `BlockEditorTextView.swift:848-950` | `Sources/RichMarkdown` | 낮음 |
| 2 | 블록 편집 엔진 (`EditorBlock*`, `InlineMarkdownCodec`, `BlockEditorModel`) | `BlockEditorModel.swift` (1,555줄) | 신규 타깃 `RichMarkdownBlockEditor` | 중간 |
| 3 | `BlockDocumentTextEditor` + `MarkdownStyler` + pasteboard payload | `BlockEditorTextView.swift` | 신규 타깃 `RichMarkdownBlockEditor` | 중간~높음 |
| 4 | `AssistantMessageViewCache` + 셀 attach/detach 패턴 | `UIKitChatDemo.swift:226-403` | 코드 이동 대신 문서화 (레시피) | 낮음 |
| — | `BlockKeyboardToolbar`, `RichMarkdownThemePreset`, fixtures | demo 각 파일 | 이동 비추천 (demo 잔류) | — |

---

## 1. `EquationTextAttachment` + `EquationAttachmentViewProvider`

**위치**: `Examples/RichMarkdownDemo/Sources/BlockEditorTextView.swift:848-950`

### 어떤 코드인가

TextKit 2의 `NSTextAttachment` / `NSTextAttachmentViewProvider` 서브클래스 한 쌍.
`UITextView` 문서 흐름 안에 LaTeX 수식을 **라이브 뷰**(`LatexEquationUIView`)로
배치한다. 비트맵 이미지 attachment가 아니라 실제 뷰라서 다크 모드 전환·테마 교체가
즉시 반영된다.

핵심 동작:

- `allowsTextAttachmentView = true` + `tracksTextAttachmentViewBounds = true`로
  TextKit 2가 뷰 크기를 추적하게 한다.
- `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`가
  수식 뷰의 `intrinsicContentSize`를 line fragment 폭 안으로 clamp하고,
  display 수식은 줄 높이만큼 baseline을 내려 블록처럼 보이게 한다.
- inline 수식은 주변 폰트의 `descender`에 맞춰 baseline을 정렬한다.

의존성은 package public API(`LatexEquationUIView`, `RichMarkdownTheme`)뿐이다.
demo 타입에 대한 의존이 전혀 없어 **그대로 잘라 옮길 수 있다**.

### 재활용 방법

`UITextView` 기반 에디터/뷰어를 가진 앱이라면 블록 에디터 없이도 이것만으로
수식 렌더링을 얻는다.

**예시 1 — 인라인·display 수식이 섞인 문서 구성** (TextKit 2 `UITextView` 전제):

```swift
import RichMarkdown
import UIKit

final class NoteViewController: UIViewController {
    // iOS 16+: usingTextLayoutManager로 TextKit 2 스택을 명시한다.
    private let textView = UITextView(usingTextLayoutManager: true)

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.frame = view.bounds
        textView.isEditable = false
        view.addSubview(textView)
        textView.attributedText = Self.makeDocument(theme: .default)
    }

    private static func makeDocument(theme: RichMarkdownTheme) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString(
            string: "가우스 적분은 ",
            attributes: [.font: body]
        )

        // 인라인 수식 — attachmentBounds가 주변 폰트의 descender를 읽어
        // baseline을 맞추므로, attachment 문자에도 .font를 부여해야 한다.
        let inline = EquationTextAttachment(
            latex: #"e^{-x^2}"#,
            source: #"\(e^{-x^2}\)"#,   // 복사/편집 시 되돌릴 원문
            theme: theme,
            isDisplay: false,
            pointSize: body.pointSize
        )
        result.append(NSAttributedString(
            attachment: inline,
            attributes: [.font: body]
        ))
        result.append(NSAttributedString(
            string: " 형태의 적분입니다.\n",
            attributes: [.font: body]
        ))

        // display 수식 — 별도 문단 + 중앙 정렬. isDisplay가 baseline을
        // 줄 높이만큼 내려 블록처럼 배치한다.
        let display = EquationTextAttachment(
            latex: #"\int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}"#,
            source: #"\[ \int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi} \]"#,
            theme: theme,
            isDisplay: true,
            pointSize: body.pointSize
        )
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        result.append(NSAttributedString(
            attachment: display,
            attributes: [.font: body, .paragraphStyle: centered]
        ))
        return result
    }
}
```

**예시 2 — 테마 교체**: attachment는 init 시점의 `theme`을 캡처하므로, 테마가
바뀌면 attributed string을 다시 만든다. 수식 원문은 `source`에 보존돼 있어
재구성 비용은 문자열 순회뿐이다.

```swift
func applyTheme(_ theme: RichMarkdownTheme, to textView: UITextView) {
    let old = textView.attributedText ?? NSAttributedString()
    let rebuilt = NSMutableAttributedString(attributedString: old)
    old.enumerateAttribute(
        .attachment,
        in: NSRange(location: 0, length: old.length)
    ) { value, range, _ in
        guard let equation = value as? EquationTextAttachment else { return }
        let replacement = EquationTextAttachment(
            latex: equation.latex,
            source: equation.source,
            theme: theme,                    // 새 테마로 재생성
            isDisplay: equation.isDisplay,
            pointSize: equation.pointSize
        )
        rebuilt.addAttribute(.attachment, value: replacement, range: range)
    }
    textView.attributedText = rebuilt
}
```

활용 시나리오:

1. **노트 앱·메모 앱의 수식 삽입** — 기존 `NSAttributedString` 파이프라인에 attachment
   하나만 끼우면 된다. TextKit 2 스택(`NSTextLayoutManager`)이면 즉시 동작.
2. **`RichMarkdownUIView`를 못 쓰는 커스텀 에디터** — 자체 attributed-string 렌더러를
   가진 앱이 수식 구간만 이 attachment로 치환.
3. **package 내부 재사용** — 현재 UIKit 렌더러가 수식을 다루는 경로와 통합해
   중복 제거 여지가 있다.

이동 시 유의점:

- `source` 프로퍼티는 편집기에서 attachment ↔ 원문 왕복에 쓰인다. 뷰어 전용
  사용자는 무시해도 되므로 기본값(`source: String = ""` 또는 `latex`와 동일)을
  검토한다.
- iOS 15+ (TextKit 2) 전제. package 최소 배포 타깃과 일치 여부 확인.

---

## 2. 블록 편집 엔진 — `EditorBlockKind` / `EditorBlock` / `InlineMarkdownCodec` / `BlockEditorModel`

**위치**: `Examples/RichMarkdownDemo/Sources/BlockEditorModel.swift` (파일 전체, 1,555줄)

### 어떤 코드인가

Notion 스타일 블록 문서의 **순수 로직 엔진**. `Foundation`만 import하며 UI 의존이
전혀 없다. 네 부분으로 구성된다.

**`EditorBlockKind`** — 블록 종류 enum. 문단·제목(1–3)·글머리/번호 목록·할 일·인용·
코드·수식. 종류별 정책을 computed property로 노출한다:
`continuationKind`(Enter 시 다음 블록 종류), `preservesLineBreaks`(코드·수식은 개행
유지), `supportsIndentation`.

**`EditorBlock`** — 블록 하나의 값 타입. `markdown:` 이니셜라이저가 한 블록 분량의
markdown을 파싱하고(`# `, `- [ ] `, ` ``` ` fence, `\[...\]` 수식 등), `markdown(numberedListOrdinal:)`이
역직렬화한다. **파싱↔직렬화 왕복이 손실 없이 보존**되는 것이 핵심 계약이다.

**`InlineMarkdownCodec`** (private) — 인라인 서식(`**bold**`, `*italic*`, `~~strike~~`,
`` `code` ``)을 텍스트 + `[InlineMark]`(UTF-16 `NSRange` 기반)로 분리하는 코덱.
어려운 케이스를 이미 해결했다:

- **LaTeX-aware**: `\(...\)`, `$...$` 구간 안의 `*`, `_`는 서식 구분자로 해석하지 않는다.
- 코드 마크 안에서는 다른 서식을 무효화(subtract)한다.
- 이스케이프(`\*`, `\$`), 중첩 서식, 겹치는 마크 병합·정규화.

**`BlockEditorModel`** — 문서 전체 모델. 제공 기능:

- 블록↔문서 좌표 변환: 전역 UTF-16 offset ↔ (블록 index, 블록 내 offset).
  TextKit이 주는 전역 변경을 논리 블록 변경으로 환원한다 (`replaceDocumentText`).
- 블록 조작: split(Enter) / merge(Backspace) / indent·outdent / 종류 변환 /
  복제·삭제·이동 / 인라인 서식 토글(`applyInlineFormat` — 전체 덮임 여부로
  적용/해제 판단).
- undo/redo 스택(상한 100) + 선택 복원.
- markdown 직렬화 시 번호 목록 ordinal을 depth별로 재계산.

demo에 이미 단위 테스트가 있다: `Examples/RichMarkdownDemo/Tests/BlockEditorModelTests.swift`.
이동 시 테스트도 함께 옮긴다.

### 재활용 방법

**신규 package 타깃 `RichMarkdownBlockEditor`의 코어**로 이동을 권장한다. 렌더
라이브러리(RichMarkdown)와 편집기는 관심사가 달라 기존 타깃에 합치지 않는다.

```swift
// Package.swift
.target(name: "RichMarkdownBlockEditor", dependencies: ["RichMarkdown"]),
```

활용 시나리오:

**예시 1 — 앱에 블록 에디터 탑재**: markdown 문자열 하나로 초기화하고, 편집 결과를
다시 markdown으로 뽑는다. 저장 포맷이 markdown이므로 서버·다른 클라이언트와
호환된다.

```swift
// 로드 → 편집 → 저장 왕복. 파싱↔직렬화가 손실 없이 보존된다.
var model = BlockEditorModel(markdown: note.body)

// TextKit delegate가 주는 전역 UTF-16 변경을 그대로 위임하면
// 모델이 논리 블록 변경(split/merge/치환)으로 환원한다.
let nextSelection = model.replaceDocumentText(
    in: NSRange(location: 42, length: 0),
    with: "\n"                    // 문단 중간의 Enter → 블록 split
)

note.body = model.markdown        // 저장
```

**예시 2 — 프로그래밍 방식 문서 조작** (UI 없이 모델만 사용):

```swift
var model = BlockEditorModel(markdown: "# 회의 노트\n\n- 안건 정리")

// 마지막 목록 뒤에 할 일 블록 삽입
let listID = model.blocks.last { $0.kind == .bulletedList }?.id
if let selection = model.insert(after: listID, kind: .toDo(isChecked: false)) {
    _ = model.replaceText(
        id: selection.blockID,
        range: NSRange(location: 0, length: 0),
        with: "회의록 공유"
    )
    _ = model.indent(id: selection.blockID)   // 한 단계 들여쓰기
}

// 첫 문단을 인용으로 변환
if let paragraph = model.blocks.first(where: { $0.kind == .paragraph }) {
    model.transform(id: paragraph.id, to: .quote)
}

model.undo()          // 직전 변경 취소 — 선택 위치도 함께 복원된다
print(model.markdown)
// # 회의 노트
// - 안건 정리
//   - [ ] 회의록 공유
```

**예시 3 — 서버 응답 markdown 분석 파이프라인** (블록 단위 추출·집계):

```swift
// LLM 응답에서 코드 블록과 수식만 추출
let model = BlockEditorModel(markdown: response)
let codeBlocks = model.blocks.compactMap { block -> (language: String?, code: String)? in
    guard case let .code(language) = block.kind else { return nil }
    return (language, block.text)
}
let equations = model.blocks.filter { $0.kind == .equation }.map(\.text)

// 미완료 할 일 개수 집계
let remaining = model.blocks.count { $0.kind == .toDo(isChecked: false) }
```

**예시 4 — 인라인 서식 토글** (선택 구간에 굵게 적용/해제):

```swift
// applyInlineFormat은 선택 구간이 이미 전부 굵게 덮여 있으면 해제,
// 아니면 적용한다. 코드 마크와 겹치는 구간은 정규화 단계에서 무효화된다.
if let active = model.blockSelection(for: documentSelection) {
    let next = model.applyInlineFormat(.bold, id: active.blockID, range: active.range)
    model.updateSelection(next)   // 서식 적용 후 선택 유지
}
```

**예시 5 — `InlineMarkdownCodec` 단독 사용** (`internal` → `public` 승격 시):
"LaTeX 구간을 보호하는 인라인 markdown 파서"로 재사용한다. 채팅 입력창의
WYSIWYG 서식 토글 같은 곳에 맞는다.

```swift
// 파싱: 서식 문자를 벗겨낸 순수 텍스트 + UTF-16 range 마크
let (text, marks) = InlineMarkdownCodec.parse(#"**중요** 값은 \(x^2\)입니다"#)
// text  = "중요 값은 \(x^2\)입니다"      ← LaTeX 구간은 건드리지 않음
// marks = [InlineMark(format: .bold, range: {0, 2})]

// 직렬화: 마크를 다시 구분자로 감싼다. 왕복 보존.
let markdown = InlineMarkdownCodec.serialize(text: text, marks: marks)
```

이동 전 정리할 것 (API 결함):

- **한국어 UI 문자열 하드코딩** — `EditorBlockKind.title`("텍스트", "제목 1" …)과
  `systemImage`는 표시용이므로 로직 엔진에 있으면 안 된다. UI 레이어로 옮기거나
  `String Catalog` 로컬라이제이션으로 분리한다.
- **정책 상수가 코드에 박혀 있음** — heading level 1…3, indent 0…3, history 100,
  pasteboard 256KB. package화하면 최소한 문서화하고, 필요 시 설정 주입을 검토한다
  (당장은 문서화만으로 충분).
- `InlineFormat.italic`의 정식 구분자가 `<em>`인 점(별표와 밑줄은 파싱만 지원)은
  직렬화 결과에 영향을 주므로 반드시 문서화한다.

---

## 3. `BlockDocumentTextEditor` + `MarkdownStyler` + `BlockDocumentPasteboardPayload`

**위치**: `Examples/RichMarkdownDemo/Sources/BlockEditorTextView.swift` (attachment 제외 전체)

### 어떤 코드인가

2번 엔진의 **뷰 레이어**. 논리 블록 배열 전체를 TextKit 2 문서 하나로 투영해,
UIKit 기본 선택기가 블록 경계와 무관하게 선택·복사·전체 선택을 처리하게 한다.

**`BlockDocumentTextEditor`** (`UIViewRepresentable`) + `Coordinator` — 실측으로
잡은 어려운 문제들이 이 안에 있다. 재구현 비용이 가장 큰 부분:

- **한글 IME composition 처리**: `markedTextRange`가 있는 동안 모델 갱신을 보류하고
  `compositionRange`를 기억했다가, 조합 확정 시점에 baseline 텍스트와 diff로
  실제 변경(`range`, `replacement`)을 복원한다. 이 처리가 없으면 한글 입력 중
  모델 재적용이 조합을 끊는다.
- **diff 기반 변경 복원**: delegate가 range를 안 주는 외부 변경(받아쓰기, 자동 수정)도
  `singleReplacement(from:to:)`의 prefix/suffix 비교로 단일 치환을 추출한다.
- **수식 경계 보정** (`sourceAlignedSelection`): 수식 attachment(1글자) ↔ 원문
  (N글자) 전환 시 선택 offset이 문자 경계를 벗어나지 않게 보정한다.
- attribute-only 변경 시 `textStorage` 직접 재작성으로 전체 리셋을 피하고,
  `InlineCodeDecorationView`에 무효화를 직접 알린다.

**`MarkdownStyler`** — `[EditorBlock]` → `NSAttributedString` 스타일러.
블록 종류별 폰트(Dynamic Type 대응 `UIFontMetrics` 스케일링 포함), `NSTextList`
기반 목록 마커, 들여쓰기 paragraph style, 편집 중이 아닌 수식만 attachment로 치환
(편집 중인 수식은 원문 노출), 인라인 코드 칩 attribute(`.inlineCodeChip`) 부착.

**`BlockDocumentUITextView` + `BlockDocumentPasteboardPayload`** — 전체 선택 복사 시
앱 전용 pasteboard type(JSON, 버전 필드 포함)에 블록 구조를 실어, 붙여넣기에서
블록 종류·인라인 마크·들여쓰기를 손실 없이 복원한다. plain text fallback 동시 게시.
payload 디코딩 시 heading level·indent를 clamp해 조작된 데이터를 방어한다.

### 재활용 방법

2번과 함께 `RichMarkdownBlockEditor` 타깃으로. 앱 입장에서는 이 뷰 하나가 공개
진입점이 된다.

**예시 1 — SwiftUI 화면 전체 배선** (모델 + 뷰 + 툴바 액션 라우팅.
`BlockEditorDemoView`가 실제 동작 레퍼런스):

```swift
import RichMarkdownBlockEditor
import SwiftUI

struct NoteEditorScreen: View {
    @State private var model: BlockEditorModel
    let onSave: (String) -> Void

    init(markdown: String, onSave: @escaping (String) -> Void) {
        _model = State(initialValue: BlockEditorModel(markdown: markdown))
        self.onSave = onSave
    }

    var body: some View {
        BlockDocumentTextEditor(
            blocks: model.blocks,
            selection: model.currentDocumentSelection,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            onReplaceText: { model.replaceDocumentText(in: $0, with: $1) },
            onSelectionChange: { model.updateDocumentSelection($0) },
            onToolbarAction: perform,
            onReplaceDocumentBlocks: { model.replaceDocumentBlocks(in: $0, with: $1) },
            theme: .default              // ← 정리 후: preset 대신 RichMarkdownTheme
        )
        .onDisappear { onSave(model.markdown) }
    }

    /// 키보드 액세서리(또는 자체 툴바)의 액션을 모델 조작으로 라우팅한다.
    private func perform(_ action: EditorToolbarAction, selection: NSRange) {
        model.updateDocumentSelection(selection)
        guard let active = model.blockSelection(for: selection) else { return }

        switch action {
        case let .insert(kind):
            if let next = model.insert(after: active.blockID, kind: kind) {
                model.updateSelection(next)
            }
        case let .transform(kind):
            model.transform(id: active.blockID, to: kind)
        case let .format(format):
            let next = model.applyInlineFormat(
                format, id: active.blockID, range: active.range
            )
            if let next { model.updateSelection(next) }
        case .indent:  _ = model.indent(id: active.blockID)
        case .outdent: _ = model.outdent(id: active.blockID)
        case .undo:    _ = model.undo()
        case .redo:    _ = model.redo()
        case .duplicate:
            if let next = model.duplicate(id: active.blockID) {
                model.updateSelection(next)
            }
        case .delete:
            if let next = model.delete(id: active.blockID) {
                model.updateSelection(next)
            }
        case .moveUp:   _ = model.moveUp(id: active.blockID)
        case .moveDown: _ = model.moveDown(id: active.blockID)
        case .done:     break   // 뷰가 resignFirstResponder 처리
        }
    }
}
```

**예시 2 — `MarkdownStyler` 단독 사용** (편집기 없이 읽기 전용 렌더):
블록 모델만 있으면 스타일된 `NSAttributedString`을 얻는다. 상세 화면·미리보기
셀처럼 편집이 필요 없는 곳에 쓴다.

```swift
let blocks = BlockEditorModel(markdown: document).blocks
textView.attributedText = MarkdownStyler.styledDocument(
    blocks,
    parsesDollarMath: true,
    traitCollection: textView.traitCollection   // Dynamic Type 스케일 반영
)
// editingEquationIDs를 비워 두면(기본값) 모든 수식이 attachment로 렌더된다.
// 편집 화면에서는 선택 중인 수식 블록 ID를 넘겨 원문을 노출한다.
```

**예시 3 — 구조 보존 복사/붙여넣기** (pasteboard payload 단독 활용):
두 화면(또는 두 앱)이 같은 payload 포맷을 알면 블록 구조가 손실 없이 오간다.

```swift
// 보내는 쪽: markdown + 구조 payload를 동시 게시.
// plain text만 아는 앱은 markdown을, 아는 앱은 구조를 집는다.
var item: [String: Any] = [
    UTType.utf8PlainText.identifier: model.markdown,
]
if let data = BlockDocumentPasteboardPayload.encode(model.blocks) {
    item["com.richmarkdown.block-document"] = data   // demo 접미사 제거 후
}
UIPasteboard.general.setItems([item])

// 받는 쪽: 구조 payload 우선, 실패 시 markdown fallback.
// decode가 heading level·indent를 clamp해 조작된 데이터를 방어한다.
if let data = UIPasteboard.general.data(forPasteboardType: "com.richmarkdown.block-document"),
   let blocks = BlockDocumentPasteboardPayload.decode(data) {
    model.replaceDocumentBlocks(
        in: NSRange(location: 0, length: model.documentText.utf16.count),
        with: blocks
    )
} else if let markdown = UIPasteboard.general.string {
    model = BlockEditorModel(markdown: markdown)
}
```

활용 시나리오:

1. **수식 지원 노트/문서 에디터** — SwiftUI 화면에 예시 1 하나로 Notion류 편집 UX
   (라이브 수식 렌더, 인라인 코드 칩, 목록 마커) 완성.
2. **한글 IME + TextKit 2 레퍼런스** — composition reconcile 로직은 블록 에디터가
   아니어도 한글 입력을 다루는 모든 `UIViewRepresentable` 텍스트 뷰에 그대로 적용
   가능한 패턴이다. 별도 추출 가치가 있다.
3. **구조 보존 복사/붙여넣기** — 예시 3의 payload 패턴은 앱 간 블록 데이터 교환
   포맷의 시작점.

이동 전 정리할 것:

- **`RichMarkdownThemePreset` 결합 해소** — `MarkdownStyler`의 폰트·색 결정이 demo 전용
  preset enum에 걸려 있다 (`preset == .large ? 20 : nil`, Georgia 서체 분기 등).
  package API는 `RichMarkdownTheme`(+ 필요 시 폰트 소스 프로토콜)을 직접 받도록 바꾸고,
  preset별 분기는 demo의 `RichMarkdownThemePreset.theme`으로 밀어낸다.
- pasteboard type 문자열 `com.richmarkdown.demo.block-document` → `com.richmarkdown.block-document`.
- `BlockKeyboardToolbar` 의존 분리 — 툴바는 주입 가능한 `inputAccessoryView`로
  두고 package에는 포함하지 않는다 (아래 "이동 비추천" 참고).

---

## 4. `AssistantMessageViewCache` + 셀 attach/detach 패턴

**위치**: `Examples/RichMarkdownDemo/Sources/UIKitChatDemo.swift:226-403`

### 어떤 코드인가

`RichMarkdownUIView`를 `UICollectionView` 셀에서 재사용할 때의 정석 패턴.
메시지 identity(`ChatMessage.ID`) → 렌더된 뷰 인스턴스 캐시로, **셀 재사용과
뷰 수명을 분리**한다. 화면 재진입·스크롤 왕복에도 이미 렌더된 수식이 다시
파싱되지 않는다.

실측으로 잡은 결함 대응이 코드에 박혀 있다:

- **빠른 스크롤 왕복 시 뷰 탈취**: reuse pool에 있던 셀이 늦게 `prepareForReuse`를
  타면, 같은 메시지 뷰가 이미 다른 셀로 이사한 상태다. `superview === bubble`
  체크 없이 `removeFromSuperview()`하면 화면에 보이는 셀에서 뷰를 뜯어낸다
  (`detachMessageView` 주석 참고).
- **prewarm**: 앱 시작 직후 `prewarmSharedMessageViews`로 파싱·raster 파이프라인을
  미리 돌려, 화면 첫 진입이 전환 애니메이션(0.35s) 안에 완성 상태가 된다.
  SwiftMath 폰트 등록 + 12개 메시지 raster가 전환 시간을 넘기는 것을 영상 실측으로
  확인한 결과다.
- 생성 직후의 빈 fallback 콜백은 무시하고, 콘텐츠 주입 후 갱신만
  `invalidateIntrinsicContentSize`로 연결 (`beginObservingContentChanges`).

### 재활용 방법

**코드 이동보다 문서화(레시피)를 권장한다.** 이유: 캐시에 eviction 정책이 없다
(고정 fixture 데모라 상한 불필요 — 코드 주석에 명시). 실제 무한 피드 앱은 메모리
측정 후 상한·eviction을 앱 특성에 맞게 정해야 하므로, 지금 package API로 굳히면
잘못된 기본값을 배포하게 된다.

**예시 1 — 레시피 핵심 코드** (앱에 옮겨 적을 최소 형태). 셀 재사용과 뷰 수명을
분리하는 세 지점 — configure의 attach, `prepareForReuse`의 detach, detach의
`superview` 체크:

```swift
final class ChatMessageCell: UICollectionViewCell {
    private let bubble = UIView()
    private var entry: AssistantMessageViewCache.Entry?

    func configure(_ message: ChatMessage, cache: AssistantMessageViewCache) {
        let entry = cache.entry(for: message)
        attach(entry)
        entry.view.markdown = message.text     // 캐시 hit이면 dedupe로 no-op
        entry.beginObservingContentChanges()   // 렌더 완료 → 셀 재측정 연결
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        detach()
    }

    private func attach(_ newEntry: AssistantMessageViewCache.Entry) {
        guard entry !== newEntry else { return }
        detach()
        entry = newEntry
        bubble.addSubview(newEntry.view)       // + Auto Layout 제약
        newEntry.attach(to: self)
    }

    private func detach() {
        guard let entry else { return }
        entry.detach(from: self)
        // 핵심: 뷰가 아직 이 셀에 붙어 있을 때만 제거한다.
        // reuse pool의 셀이 늦게 prepareForReuse를 타는 사이 같은 메시지가
        // 다른 셀로 이사했으면, 무조건 removeFromSuperview 시 화면에 보이는
        // 셀에서 뷰를 뜯어내 빈 버블이 남는다 (빠른 스크롤 왕복에서 재현).
        if entry.view.superview === bubble {
            entry.view.removeFromSuperview()
        }
        self.entry = nil
    }
}
```

**예시 2 — prewarm 호출 시점** (루트 화면, 채팅 화면 진입 전):

```swift
struct RootView: View {
    var body: some View {
        NavigationStack { /* ... */ }
            // 앱 시작 직후 파싱·raster 파이프라인을 미리 돌린다.
            // 화면 전환(0.35s) 안에 SwiftMath 폰트 등록 + 메시지 raster가
            // 끝나지 않으므로, 진입 직전 prewarm으로는 부족하다 (영상 실측).
            .task {
                for message in recentMessages where message.role == .assistant {
                    let entry = messageViewCache.entry(for: message)
                    entry.view.theme = currentTheme
                    entry.view.markdown = message.text   // 재호출은 dedupe로 no-op
                    entry.beginObservingContentChanges()
                }
            }
    }
}
```

**예시 3 — 무한 피드용 eviction 확장 스케치** (package 승격 시 선행 설계 대상):

```swift
// ponytail: 개수 상한 + 접근 순서 LRU. 메모리 실측 후 상한을 정한다.
func entry(for message: ChatMessage) -> Entry {
    if let hit = entries[message.id] {
        accessOrder.removeAll { $0 == message.id }
        accessOrder.append(message.id)
        return hit
    }
    if entries.count >= limit, let oldest = accessOrder.first {
        // 화면에 붙어 있는 뷰는 쫓아내면 안 된다 — attach 상태 확인 필요.
        entries.removeValue(forKey: oldest)
        accessOrder.removeFirst()
    }
    let entry = Entry()
    entries[message.id] = entry
    accessOrder.append(message.id)
    return entry
}
```

활용 시나리오:

1. **UIKit 채팅 앱 통합 가이드** — README 또는 `DEVELOPMENT.md`에 "RichMarkdownUIView
   + UICollectionView" 절을 만들고 예시 1·2를 옮겨 적는다. attach/detach의
   `superview` 체크와 prewarm 호출 시점(루트 화면 `.task`)이 핵심.
2. **추후 package API 후보** — 예시 3의 eviction 정책(LRU + 개수 상한)을 설계하고
   메모리 비용을 실측한 뒤 `LatexMessageViewCache`류 public 유틸리티로 승격을
   재검토한다.

---

## 이동 비추천 (demo 잔류)

| 대상 | 이유 |
|---|---|
| `BlockKeyboardToolbar` | 제품 특화 UI. 한국어 라벨 하드코딩, `UIScreen.main` 사용(resize 환경 비권장 API). 에디터 package는 `inputAccessoryView` 주입점만 열어두면 된다. |
| `RichMarkdownThemePreset` | 예시용 테마 4종 + UI 테스트용 launch argument 헬퍼. package 사용자는 `RichMarkdownTheme`을 직접 만들면 되고, 프리셋은 README 예제 코드로 충분하다. |
| `ChatFixtures` / `ChatBubble` / `ChatDemoView` | 렌더 케이스 검증용 fixture와 showcase 화면. UI 테스트가 의존하므로 demo에 남아야 한다. |
| `EditorDemoView` / `HostingConfigurationDemo` | `RichMarkdownView` 사용법 자체가 내용의 전부. package로 옮길 로직이 없다. |

## 권장 이동 순서

1. **`EquationTextAttachment`** → `Sources/RichMarkdown`. 의존 정리 불필요, 즉시 가능.
2. **`BlockEditorModel.swift` 전체 + 테스트** → 신규 `RichMarkdownBlockEditor` 타깃.
   선행 작업: `EditorBlockKind.title`/`systemImage` UI 레이어 분리.
3. **`BlockDocumentTextEditor` + `MarkdownStyler` + pasteboard payload** → 같은 타깃.
   선행 작업: `RichMarkdownThemePreset` 결합 해소, pasteboard type 개명, 툴바 주입점 분리.
4. **캐시 패턴 문서화** → README/DEVELOPMENT.md. 코드 이동은 eviction 설계 후 재검토.

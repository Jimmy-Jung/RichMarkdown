# RichMarkdownBlockEditor 동작 명세

기준일: 2026-10-06

현재 구현이 데이터를 보관하고 편집하는 규칙을 관련 테스트와 연결해 설명합니다. 상태는 **구현·패키지 회귀 확인**이며 최종 배포 판정은 [릴리스 검수 기록](../validation.md)에서 구분합니다. [아키텍처](../architecture/RichMarkdownBlockEditor.md) · [ADR](../adr/README.md#richmarkdownblockeditor-adr) · [개선안](../improvements/RichMarkdownBlockEditor.md)을 함께 읽습니다.

이 문서의 블록은 문단·제목·코드처럼 종류를 가진 내용 단위입니다. 인라인 서식은 본문 일부에 적용할 굵게·기울임 같은 서식이며, 본문과 별도로 범위를 저장합니다. 범위는 UTF-16의 16비트 단위로 계산하므로 `😀`처럼 화면에서 한 글자인 문자가 두 단위일 수 있습니다.

## 1. 공개 데이터와 확장점

| API | 의미와 사용 경계 |
| --- | --- |
| `EditorBlockKind` | 일반 문단(paragraph), 제목(heading 1...3), 기호 목록(bulletedList), 번호 목록(numberedList), 할 일(toDo), 인용(quote), 코드(code), 수식(equation) 종류입니다. |
| `EditorBlock` | 블록 ID(UUID), 종류(kind), 본문(text), 서식 범위(inlineMarks), 들여쓰기(indentLevel)를 보관하는 값입니다. 생성·직접 대입에서 들여쓰기 0...3·제목 1...3을 유지하고, 서식 범위는 유효한 형태로 정리(정규화)합니다. 같은 문서에서 ID가 중복되지 않게 하는 일은 앱 책임입니다. |
| `InlineMark`, `BlockSelection` | 블록 원문 안의 위치·길이를 UTF-16 `NSRange`로 나타냅니다. 화면 글자 수 기준이 아닙니다. |
| `BlockEditorModel` | 블록(blocks), 블록 안·전체 문서의 선택(selection), 되돌리기(undo)·다시 실행(redo) 가능 상태를 관리합니다. |
| `BlockDocumentTextEditor` | 블록·선택 상태와 편집·선택·도구 모음(toolbar) 콜백을 받습니다. UIKit 뷰를 SwiftUI에서 사용하는 `UIViewRepresentable`입니다. |
| `BlockDocumentUITextView` | iOS 텍스트 배치 엔진 TextKit 2의 문서·장식·전체 문서 복사/붙여넣기(copy/paste)를 연결합니다. |
| `BlockDocumentPasteboardPayload` | 블록을 복사할 실제 데이터(payload)의 version 1 JSON 표현입니다. 블록 UUID는 제외합니다. |
| `BlockEditorInputAccessory`, `EditorToolbarAction` | 앱 도구 모음의 상태 갱신과 편집 명령 규칙입니다. `.done`은 전송 요청이 아닙니다. |
| `MarkdownStyler`, `BlockAlignmentConfiguration` | 본문과 별도로 관리한 서식·수식·테마를 화면에 반영하고 코드·수식 정렬을 제공합니다. |

근거: [EditorBlock.swift](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift), [BlockEditorModel.swift](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift), [BlockDocumentTextEditor.swift](../../../Sources/RichMarkdownBlockEditor/BlockDocumentTextEditor.swift), [MarkdownStyler.swift](../../../Sources/RichMarkdownBlockEditor/MarkdownStyler.swift). 패키지 구성품(product)의 사용 기준은 [Package.swift](../../../Package.swift)의 iOS 16 이상입니다.

## 2. 블록·선택·편집 요구

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| E-01 | 일반 블록의 개행은 블록 경계, 코드·수식의 개행은 내부 텍스트입니다. 문서 끝에 빈 문단을 유지합니다. | [normalized·replaceDocumentText](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [initialTextNormalizesLineBreaksByBlockKind·distinguishesBlockBreakFromCodeSoftBreak](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-02 | 분할(split)은 왼쪽 블록과 분할 대상이 아닌 블록의 ID를 유지하며 오른쪽에 새 ID를 발급합니다. | [split](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift) | [splitBlockAtCaret](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-03 | 텍스트 교체·종류 변환·들여쓰기·이동은 대상 ID를 유지합니다. 복제(duplicate)는 새 ID를 만듭니다. | [편집 명령](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [editCommandsAreUndoable·moveBoundaries](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-04 | 전체 문서의 위치는 블록 본문의 UTF-16 길이와 블록 사이 구분 개행 한 단위를 합해 계산합니다. 코드 내부 개행도 포함합니다. | [documentText·documentBlockRanges](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [projectsBlocksIntoContinuousDocument](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-05 | 전체 문서의 선택 범위는 여러 블록에 걸칠 수 있습니다. `blockSelection(for:)`은 선택이 시작하는 블록 안의 범위만 반환합니다. | [blockSelection](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [historyRestoresCrossBlockDocumentSelection](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-06 | 끝 위치를 더하기 전에 범위의 음수·문서 밖 위치·길이를 검사합니다. 유효하지 않은 편집 범위와 UTF-16의 두 단위 문자 짝(surrogate) 중간 분할은 nil로 거절하고 문서를 바꾸지 않습니다. 잘못된 서식 범위·스타일러 선택은 무시하고 뷰 선택은 표시 문서 범위로 제한합니다. | [validated·documentRange](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift), [isValidRange·replacingText·normalized](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift), [selection 경계](../../../Sources/RichMarkdownBlockEditor/MarkdownStyler.swift), [clamped·sourceAlignedSelection](../../../Sources/RichMarkdownBlockEditor/BlockDocumentTextEditor.swift) | [invalidRangesAreRejected·invalidInlineMarkRangesAreIgnored·invalidPublicEditRangesAreRejected·invalidStylerSelectionsAreIgnored·coordinatorClampsOverflowingSelections](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-07 | 빈 목록 Enter는 같은 ID의 문단으로 돌아갑니다. 일반 Enter의 후속 종류는 `continuationKind`입니다. | [splitBlock](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [emptyListBecomesParagraph·documentEnterExitsEmptyList](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-08 | 서식 블록 시작 Backspace는 먼저 문단으로 변환합니다. 문단은 앞 블록과 합치되 앞이 코드·수식이면 경계를 보존합니다. | [backspaceAtStart](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [convertFormattedBlockBeforeMerging·documentBackspaceUsesBlockBoundaryRules](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-09 | 범위가 여러 블록을 가로지르면 중간 블록을 제거하고 양끝의 남은 텍스트를 연결합니다. | [replaceDocumentText](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [replacesAcrossBlockBoundaries](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-10 | 블록 생성·직접 대입에서 들여쓰기 0...3·제목 레벨 1...3을 유지합니다. `indent`·`outdent`와 모델 변환도 같은 범위를 사용합니다. | [changeIndent·transform](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift), [init·프로퍼티 observer](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift) | [directIndentValuesAreClamped·directHeadingValuesAreClamped·formattingShortcutAndIndent·paragraphIndentUpdatesLayout](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |

`replaceDocumentText`는 새 전체 문서 커서(caret) 위치를 반환하고 모델 선택도 갱신합니다. `splitBlock`, `replaceText`, `insert`, `duplicate`, `delete`, `applyInlineFormat` 등 블록 단위 API는 반환한 `BlockSelection`을 앱이 `updateSelection`에 적용해야 합니다. `.done`을 제외한 도구 모음 명령의 실행 연결 예시는 [BlockEditorDemo.perform](../../../Examples/RichMarkdownDemo/Sources/BlockEditorDemo.swift)에 있습니다.

## 3. 서식·수식·입력기·되돌리기 요구

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| E-11 | 굵게(bold)·기울임(italic)·취소선·코드(code)는 원문 text와 별도의 UTF-16 서식 범위로 관리합니다. 범위 생성·직접 대입은 정규화를 거치며 코드 범위에서는 겹친 일반 서식을 제외합니다. | [inlineMarks observer·InlineMarkdownCodec.normalized](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift) | [storesInlineMarkRangesAsUTF16Offsets·inlineCodeClipsOverlappingMarks·invalidInlineMarkRangesAreIgnored](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-12 | 인라인 서식을 끄면(toggle 해제) 선택한 하위 범위의 서식만 제거하고 앞뒤 서식 범위는 남깁니다. | [applyInlineFormat](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [inlineFormatToggleSubtractsSelectedRange](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-13 | 코드·수식 블록은 인라인 Markdown 서식을 적용하지 않습니다. | [styled](../../../Sources/RichMarkdownBlockEditor/MarkdownStyler.swift) | [codeStaysLiteralAndEquationUsesAttachment](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-14 | 선택하지 않은 수식은 텍스트에 삽입한 수식 첨부 요소(attachment)로 보이고, 선택이 겹치면 원문으로 바뀝니다. 표시 문자열의 UTF-16 길이는 원문 길이와 같습니다. | [equationAttachment·sourceAlignedSelection](../../../Sources/RichMarkdownBlockEditor/MarkdownStyler.swift), [선택 정렬](../../../Sources/RichMarkdownBlockEditor/BlockDocumentTextEditor.swift) | [dollarMathRenderingIsOptInAndPreservesOffsets·equationSourceTransitionAlignsUnicodeCaret](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-15 | `\(...\)`는 기본으로 수식으로 읽습니다. 본문 내 달러 수식은 명시적으로 켰을 때만(opt-in) 사용하며 코드·문법 해석을 피하도록 처리한 표현(escape)·통화 표현은 제외합니다. | [inlineMathSpans](../../../Sources/RichMarkdownBlockEditor/MarkdownStyler.swift) | [inlineMathUsesCanonicalScannerAndSurroundingFont](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-16 | 한글 등 입력기(IME)의 조합 중에는 모델 교체·스타일 덮어쓰기·도구 모음 명령을 보류합니다. 확정 시 원래 편집 범위로 한 번 전달합니다. | [Coordinator.reconcileTextChange·handleToolbarAction](../../../Sources/RichMarkdownBlockEditor/BlockDocumentTextEditor.swift) | [markedTextCommitsOneReplacement·markedTextPreservesAmbiguousInsertionRange·coordinatorUsesTextViewEditRange](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-17 | 되돌리기는 이전 블록·전체 문서 선택 상태를 담은 스냅샷(snapshot)을 최대 100개 보관합니다. 새 편집은 다시 실행 기록을 지웁니다. | [apply·undo·redo·trimHistory](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [textInputParticipatesInHistory·historyRestoresSelection·textAndSelectionUpdateAtomically](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift); 100개 경계 직접 테스트 없음 |
| E-18 | 테마·사용자의 글자 크기 설정(Dynamic Type)·앱이 전달한 정렬을 현재 표시와 새로 입력할 문자의 속성(typing attributes)에 적용합니다. 코드 기본값은 `.natural`, 수식 기본값은 `.center`입니다. | [MarkdownStyler](../../../Sources/RichMarkdownBlockEditor/MarkdownStyler.swift) | [themeChangesEditorTypographyAndColor·blockAlignmentIsInjectable·dynamicTypeScalesMonospacedFonts](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |

## 4. Markdown과 복사·붙여넣기 계약

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| E-19 | 저장·보내기용 출력은 `model.markdown`입니다. 지원 서식은 패키지가 정한 일관된 표기(canonical)로 문자열로 변환(직렬화)합니다. | [markdown](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift), [EditorBlock.markdown](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift) | [reserializesSemanticInlineMarksToMarkdown·crossingInlineMarksRoundTrip·literalDelimitersRoundTrip](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-20 | 전체 선택 복사는 앱이 준 `sourceMarkdown`을 일반 텍스트(plain text)로 싣고, 가능하면 논리 블록 JSON도 함께 싣습니다. 부분 선택은 UIKit 기본 복사입니다. | [BlockDocumentUITextView.copy](../../../Sources/RichMarkdownBlockEditor/BlockDocumentTextEditor.swift) | 이 재정의(override)와 실제 클립보드(pasteboard) 경로의 전용 테스트 없음 |
| E-21 | 복사할 데이터(payload)는 version 1, 비어 있지 않은 blocks, 최대 256 KiB 조건을 충족해야 합니다. 복원(decode)할 때 제목 1...3·들여쓰기 0...3으로 제한하고 inlineMarks를 정규화합니다. | [BlockDocumentPasteboardPayload](../../../Sources/RichMarkdownBlockEditor/BlockDocumentTextEditor.swift) | 버전·크기·변조 데이터 복원의 전용 테스트 없음 |
| E-22 | `replaceDocumentBlocks`는 전체 문서 선택만 받으며 전달된 블록 구조를 복원합니다. 불일치 범위는 nil입니다. | [replaceDocumentBlocks](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [wholeDocumentBlockRoundTripPreservesBlocks·wholeDocumentBlockPastePreservesAmbiguousBlocks](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-23 | 외부 일반 텍스트로 전체 문서를 교체하면 Markdown 문법으로 다시 분석하지 않고 문단을 만듭니다. | [replaceDocumentText 전체 선택 분기](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [wholeDocumentPlainTextReplacementDoesNotParseMarkdown](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-24 | 일반 문단(paragraph)의 제목·목록 기호(bullet)·번호·인용 시작 마커와 블록 수식 모양을 문자 그대로 읽도록 처리해 재분석 후 kind·text·inlineMarks를 보존합니다. 출력이 `\[`로 시작하고 `\]`로 끝나면 양끝 역슬래시(backslash)를 한 번 더 표시하며 실제 수식(equation) 블록은 그대로 출력합니다. | [escapedParagraph·InlineMarkdownCodec](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift) | [literalParagraphMarkersRoundTrip·literalEquationParagraphRoundTrip·ambiguousDocumentMarkdownRoundTrip](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |
| E-25 | 코드 블록을 여닫는 외부 구분기호(fence)는 역따옴표(backtick) 최소 3개이며 본문 안의 가장 긴 연속 역따옴표보다 길게 출력합니다. 종료 줄은 시작 구분기호(opener) 길이 이상의 역따옴표만 포함해야 하며 앞뒤 공백은 허용합니다. | [fencedCode·codeFenceLength·closesCodeFence](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift), [split](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift) | [codeFenceContentsRoundTrip·codeFenceClosingRequiresLengthAndEmptySuffix·ambiguousDocumentMarkdownRoundTrip](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift) |

재변환(roundtrip)은 블록을 Markdown으로 출력한 뒤 다시 블록으로 읽는 과정입니다. 현재 보존 대상은 지원하는 인라인 서식과 블록 표현의 의미이며, 제목 등 문법으로 읽히지 않아야 하는 문자 그대로(literal)의 문단 시작·블록 수식 모양 문단·코드 본문 구분기호 충돌도 포함합니다. 코드 언어(language)는 개행·역따옴표와 앞뒤 공백이 없는 단일행 표기만 지원 범위에 포함합니다.

모든 Markdown 입력의 바이트 동일성, 원본 번호·목록 기호·빈 줄과 중간 빈 문단 개수, 목록 이외 블록의 들여쓰기, 블록 UUID 보존은 보장하지 않습니다. 논리 블록 JSON은 전체 문서 내부 복사에서 종류·원문·서식·들여쓰기를 직접 전달하지만 일반 파일 저장 포맷이나 서버 API는 아닙니다.

표·이미지·링크·복잡한 HTML에 별도 블록 종류를 제공하지 않습니다. 수식 첨부 요소가 들어간 `UITextView.text`를 원문으로 저장하지 않습니다. `.done`은 키보드를 닫는 동작과 앱 콜백일 뿐 저장·전송 성공을 의미하지 않습니다.

## 5. 확인한 것과 남은 검증

공개 API, 모델 상태 변화, 스타일·입력기 처리, 데모 연결과 테스트 코드를 대조했습니다. 숫자 경계, 문자 그대로인 문단, 코드 구분기호에서 기존 구현이 실패함을 확인한 뒤 수정했고, 공개 범위 검사와 블록 수식 모양 문단의 회귀 테스트도 추가했습니다. 수정 후 전체 패키지 테스트가 exit 0, 실패 테스트 0, 오류 0으로 완료되어 새 회귀를 포함한 패키지 동작을 확인했습니다.

이후 번들 의존성 보안 변경을 포함한 최종 패키지·Demo 재검수와 배포 판정은 [릴리스 검수 기록](../validation.md)에서 관리합니다. 현재 패키지 회귀 성공이 최종 배포 검수 완료를 뜻하지 않습니다. 실제 복사/붙여넣기·음성 읽기·긴 문서 성능과 물리 기기 화면 동작은 별도 검증 범위입니다.

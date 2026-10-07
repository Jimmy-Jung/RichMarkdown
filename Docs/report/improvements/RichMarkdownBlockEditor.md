# RichMarkdownBlockEditor 개선안

기준일: 2026-10-06 · 상태: **구현·패키지 회귀 확인**

조사에서 발견한 문제를 회귀 테스트로 먼저 기록하고 소스에 반영했습니다. 숫자 경계, 문법 대신 문자 그대로 읽어야 하는 문단(literal), 코드 블록 구분기호(fence)는 수정 전 테스트가 실패하는 단계(RED)도 확인했습니다. 수정 후 전체 패키지 테스트는 exit 0, 실패 테스트 0, 오류 0으로 완료되었으며 공개 범위 검사와 블록 수식 모양 문단의 새 회귀 테스트를 포함합니다.

반영한 동작 규칙은 [명세](../spec/RichMarkdownBlockEditor.md)에 갱신했습니다. 이후 번들 의존성 보안 변경을 포함한 최종 패키지·Demo 재검수와 배포 판정은 [릴리스 검수 기록](../validation.md)에서 구분합니다.

## IE-01. 직접 블록 생성의 들여쓰기 범위

**수정 전 문제:** `EditorBlock.init`과 공개 `indentLevel` 직접 대입은 값을 그대로 저장했습니다. 입력을 일정한 형태로 정리하는 모델의 정규화도 이 값을 모든 입력 경로에서 제한하지 않았고, `changeIndent`와 클립보드(pasteboard) 데이터 복원(decode)만 0...3으로 제한했습니다. 생성자 주석은 범위를 제한한다(clamp)고 설명했지만 실제 공개 입력 처리는 달랐습니다.

**발생 조건:** 앱이 `EditorBlock(kind: .bulletedList, text: "항목", indentLevel: -1)`을 만들거나 나중에 음수를 대입한 뒤 Markdown 출력·스타일링에 전달합니다. 생성자 주석을 믿고 범위 검사를 생략할 때 노출됩니다.

**영향:** Markdown 출력의 `String(repeating:count:)`와 스타일러의 `0...block.indentLevel`에 음수가 전달될 수 있었고, 큰 양수는 불필요한 반복·목록 객체를 만들 수 있었습니다. 수정 전 실패 실행은 경계 값이 기대한 범위와 다름을 확인했습니다. 테스트는 안전한 값인지 확인하는 guard 이후에 출력·스타일링을 호출하므로, 앱 종료(crash)나 대량 메모리 할당 자체를 실행해 재현한 것은 아닙니다.

**적용:** [EditorBlock.swift](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift)의 생성자와 프로퍼티 값 변경을 감지하는 observer에서 들여쓰기(indent) 0...3을 유지합니다. 같은 공개 입력 경로에서 제목(heading) 레벨도 1...3으로 제한해 모델의 종류와 Markdown 출력이 일치하도록 했습니다. ID·`text`와 공개 프로퍼티 설정 권한(setter 접근 범위)은 유지하고 새로운 래퍼 타입은 추가하지 않았습니다.

**회귀 테스트:** [directIndentValuesAreClamped·directHeadingValuesAreClamped](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift)는 `Int.min`·음수·정상 경계·초과 값·`Int.max`로 블록을 직접 만들고 값을 대입합니다. 정규화 값·ID·`text`·Markdown 결과·목록 서식 객체(textLists) 개수와 제목의 모델 변환을 확인합니다. 기존 정상 편집 명령 테스트도 유지합니다.

**검수 상태:** 수정 전 테스트 실패와 수정 후 전체 패키지 회귀 성공을 확인했습니다. 최종 배포 전 재검수 판정은 릴리스 검수 기록에 남깁니다. 별도 클립보드 데이터 변조·크기 제한 테스트와 긴 문서 성능은 이 수정에서 실행해 확인한 범위가 아닙니다.

## IE-02. 모호한 블록의 Markdown 출력

**수정 전 문제:** 일반 문단(paragraph)의 시작 마커는 문법 대신 문자 그대로 읽도록 하는 처리(escape)가 없었습니다. 코드(code)는 역따옴표(backtick) 3개로 만든 고정 구분기호로 출력했습니다. 문단의 `# 리터럴 제목`은 다시 읽을 때 제목이 되고, 블록 수식 모양 `\[리터럴\]`은 수식(equation)으로 바뀔 수 있었습니다.

코드 안의 구분기호 줄은 문서를 블록으로 나누는 처리기(splitter)의 종료 경계와 충돌했습니다. 내부 전체 문서 복사 데이터(payload)는 이 재분석을 거치지 않았지만 Markdown으로 저장하는 문제를 해결하지는 않았습니다.

**발생 조건과 영향:** 앱이 블록 편집 모델을 Markdown으로 저장·보낸 뒤 다시 모델로 읽으며 같은 종류·`text`가 돌아오기를 기대할 때 발생합니다. 이처럼 `블록 → Markdown → 블록`으로 재변환하는 과정을 roundtrip이라고 합니다. 지원하는 본문 일부 서식의 재변환 테스트가 모든 종류의 블록을 손실 없이 보존한다는 보장은 아니며, 논리 블록 클립보드는 내부 전체 문서 경로에서만 재분석을 피합니다.

**적용:** [EditorBlock.swift](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift)의 문단 출력 처리(serializer)는 제목·목록 기호(bullet)·번호·인용 시작 마커 앞에 역슬래시를 넣고, 기존 `InlineMarkdownCodec`은 읽을 때 이를 해제합니다. 처리할 문자 앞에 원래 있던 역슬래시(backslash)도 보존합니다. 문단의 인라인 서식을 출력한 결과가 `\[`로 시작하고 `\]`로 끝나면 양끝 역슬래시도 처리해 수식 블록으로 바뀌지 않게 하며, 실제 수식 블록의 출력은 유지합니다.

코드 외부 구분기호는 최소 3개이며 본문 안에서 가장 길게 이어진 역따옴표보다 길게 선택합니다. 블록 구문 분석기(parser)와 [BlockEditorModel.split](../../../Sources/RichMarkdownBlockEditor/BlockEditorModel.swift)는 같은 길이 판별·종료 규칙을 사용합니다. 따라서 더 짧은 구분기호나 구분기호 뒤에 다른 문자열(suffix)이 붙은 본문 줄은 코드 블록을 닫지 않습니다.

**회귀 테스트:** [literalParagraphMarkersRoundTrip·literalEquationParagraphRoundTrip·ambiguousDocumentMarkdownRoundTrip·codeFenceContentsRoundTrip·codeFenceClosingRequiresLengthAndEmptySuffix](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift)는 문자 그대로인 문단, 블록 수식 모양 문단, 원래 역슬래시, 인라인 서식, 내부 구분기호와 잘못된 종료 후보를 확인합니다. 종료 후보에는 구분기호가 짧거나 뒤에 문자열이 붙은 경우가 포함됩니다. `blocks → markdown → model` 재변환에서 kind·text·inlineMarks를 비교하며 Markdown에 저장하지 않는 UUID는 제외합니다.

빈 코드 본문과 기존 역따옴표 3개 출력 테스트도 유지합니다.

**남은 지원 한계:** 중간 빈 문단 개수와 목록 이외 블록의 들여쓰기는 Markdown 재변환의 보존 대상에 포함하지 않습니다. 전체 문서 내부 복사 데이터가 이 구조를 보존합니다. 코드 언어(language)는 개행·역따옴표와 앞뒤 공백이 없는 단일행 표기만 재변환 지원 범위에 포함합니다.

전체 CommonMark 편집기나 영구 저장 형식(schema)으로 확장하지 않았습니다.

**검수 상태:** 초기 문단·구분기호의 수정 전 테스트 실패와 수정 후 전체 패키지 회귀 성공을 확인했습니다. 이후 추가한 블록 수식 모양 문단 테스트도 패키지 회귀에서 통과했습니다. 최종 배포 전 검수 결과는 릴리스 검수 기록에 남기며 실제 UIKit 복사/붙여넣기와 물리 기기 화면 표시 검수와 구분합니다.

## IE-03. 공개 UTF-16 범위의 합계 검사

**수정 전 문제:** 공개 범위는 UTF-16의 16비트 단위로 계산하는 `NSRange`의 위치(location)·길이(length)입니다. 일부 공개 입력 경로는 음수 여부를 확인한 뒤 `NSMaxRange`의 합계만 본문 길이와 비교했습니다. 매우 큰 위치·길이의 합계가 정수 범위를 벗어나면 끝 위치(end) 검사만으로 유효한 범위를 판단할 수 없습니다.

본문 일부의 서식 범위인 인라인 마크를 직접 대입한 뒤 스타일링하면, 잘못된 범위가 iOS의 서식 있는 문자열(attributed text) API까지 전달될 위험이 있었습니다.

**발생 조건:** 앱이 `InlineMark`, `BlockSelection`, 문서 선택이나 텍스트 교체에 `NSRange(location: Int.max, length: 1)` 또는 `NSRange(location: 1, length: Int.max)`를 전달합니다. 직접 서식 범위 대입·선택 변환·스타일러·뷰 입력을 모델에 연결하는 처리에서 같은 숫자 제한을 적용해야 합니다.

**적용:** [EditorBlock.isValidRange](../../../Sources/RichMarkdownBlockEditor/EditorBlock.swift)는 `location >= 0`, `length >= 0`, `location <= count`, `length <= count - location`을 합계 계산 전에 검사합니다. 문자열 변환기(코덱), 모델 선택과 편집, 스타일러, 입력기(IME)의 교체 문자열 처리에 같은 내부 도우미 함수를 사용합니다. 직접 `inlineMarks`를 대입해도 기존 정규화를 거쳐 유효한 서식 범위만 남깁니다.

모델은 잘못된 편집 범위를 거절하고 스타일러는 잘못된 선택을 무시하며 원문을 유지합니다. 뷰는 끝 위치를 계산하기 전에 기존 선택 제한 처리를 적용합니다. 새 공개 API와 별도 범위 래퍼는 추가하지 않았습니다.

**회귀 테스트:** [invalidInlineMarkRangesAreIgnored·invalidPublicEditRangesAreRejected·invalidStylerSelectionsAreIgnored·coordinatorClampsOverflowingSelections](../../../Tests/RichMarkdownBlockEditorTests/BlockEditorModelTests.swift)는 큰 정수·음수·문서 밖 범위를 생성·직접 대입·선택 변환·교체·스타일링·입력 연결 처리에 전달합니다. 원문과 유효한 서식 보존, 잘못된 편집 거절, 스타일러 선택 무시, 뷰 선택 제한을 확인합니다.

**검수 상태:** 기본 연산만 따로 확인한 사전 검사(primitive)에서는 큰 합계가 표현 범위를 넘어 다른 정수 값으로 돌아오는 현상(wrap)을 확인했습니다. 이를 정수 범위 초과로 실행이 중단되는 현상(overflow trap)이나 앱 종료 재현으로 해석하지 않습니다. 이 항목의 수정 전 제품 테스트는 다른 모듈 컴파일 오류로 실행하지 못했습니다.

테스트를 먼저 추가한 뒤 수정했고, 전체 패키지 실행에서 새 범위 회귀 테스트가 통과함을 확인했습니다. 이후 최종 패키지·Demo 재검수와 배포 판정은 릴리스 검수 기록에 남깁니다.

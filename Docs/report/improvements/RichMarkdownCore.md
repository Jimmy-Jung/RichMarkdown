# RichMarkdownCore 개선안

기준일: 2026-10-06 · 상태: **구현 반영, 패키지 회귀 확인**

아래 두 개선은 코드에 반영했습니다. 변경 전 테스트 실패와 변경 후 통과는 구분하며, 실행 결과는 [검수 기록](../validation.md)에 모읍니다. 현재 계약은 [명세](../spec/RichMarkdownCore.md), 구조는 [아키텍처](../architecture/RichMarkdownCore.md), 선택 근거는 [ADR](../adr/README.md#richmarkdowncore-adr)을 따릅니다.

Core는 Markdown 원문을 분석하는 내부 모듈입니다. 이 문서의 원문 위치는 UTF-8 바이트 기준이며, Swift `Character`로 센 글자 수나 UIKit의 UTF-16 `NSRange`와 다릅니다. 예를 들어 이모지는 `Character` 하나여도 여러 바이트를 차지하므로 같은 숫자를 서로의 위치 값으로 사용할 수 없습니다.

## CORE-IMP-01: 단독 CR 줄바꿈 뒤의 위치 변환 기준

**변경 전 근거:** CR·LF·CRLF는 텍스트 파일에 쓰는 줄바꿈 형식입니다. [UTF8LineMap](../../../Sources/RichMarkdownCore/UTF8LineMap.swift)은 이 중 LF에서만 새 행 시작을 기록했습니다. 고정 의존성 swift-markdown 0.4.0의 `SourceLocation`은 1부터 시작하는 행 번호·UTF-8 바이트 열 번호를 쓰며, 내부 Markdown 파서인 cmark는 CR·LF를 행 종료로, CRLF를 한 행 종료로 처리합니다.

두 기준이 달라 CR 다음 행의 [DocumentBuilder](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) 문맥 범위와 원문 복원이 어긋났습니다. 단순화한 예로 CR 다음 행의 수식을 찾을 때 두 모듈의 행 번호가 다르면, 올바른 원문 구간을 찾지 못할 수 있습니다.

**반영:** 원문 UTF-8 배열에서 CR·LF·CRLF를 각각 한 행의 끝으로 세고 CRLF는 한 번만 등록합니다. 원문을 LF로 바꾸지 않으므로 원문 처음부터 센 바이트 위치와 원문 자체가 유지됩니다. 열 번호 계산은 남은 바이트 수를 검사한 뒤 더해 `Int.max` 입력도 nil로 거절합니다.

**회귀 선언:** 회귀 테스트는 수정 후 기존 기능이 다시 깨지지 않는지 확인하는 테스트입니다. [MaskRoundTripTests](../../../Tests/RichMarkdownCoreTests/MaskRoundTripTests.swift)의 `lineMapMatchesDependencySourceLocations`는 세 줄바꿈 형식에서 실제 의존 라이브러리의 `SourceLocation`과 원문 바이트 위치를 대조합니다. `lineMapRejectsOverflowingColumn`은 덧셈의 정수 범위 초과를 검사합니다.

[MathScannerFixtureTests](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `commonMarkLineEndingsPreserveMathAndCodeBarriers`는 수식 원문과 코드 제외 구간을 확인합니다. 제외 구간(barrier)은 내부 기호를 수식으로 잘못 읽지 않도록 검색에서 빼는 범위입니다.

**검수 경계:** 새 회귀 선언 외에도 기존 코드·HTML 제외 구간, `multilingualSurroundingRangesPreserved`, 수식을 임시 문자로 덮었다가 원문으로 복원하는 검사(mask round-trip)를 함께 유지해야 합니다. 테스트 선언 자체는 변경 후 실행 통과를 뜻하지 않습니다.

## CORE-IMP-02: 수식 검색 전 인용 중첩 깊이 검사

**변경 전 근거:** 문서 전체를 분석하는 경로(full parse)는 [InputLimits.bound](../../../Sources/RichMarkdownCore/InputLimits.swift)로 인용 중첩 깊이를 검사했습니다. 반면 수식 구간만 찾는 [RichMarkdownParser.scanInlineMathSpans](../../../Sources/RichMarkdownCore/DocumentBuilder.swift)는 그 검사 없이 AST를 만들었습니다. AST는 원문을 문단·코드 등의 노드로 분석한 문서 구조이며, 공개 [LatexInlineMathScanner.scan](../../../Sources/RichMarkdown/LatexInlineMathScanner.swift)도 바이트 상한만 검사했습니다.

**반영:** 수식 구간 검색도 첫 AST 전에 바이트 상한과 문서 전체 분석의 기존 인용 깊이 검사를 재사용합니다. 이렇게 분석 전에 입력을 검사하는 것을 preflight라고 합니다. 262,144바이트 또는 깊이 64를 초과하면 빈 배열 `[]`를 반환합니다.

이 API는 원문의 위치를 반환해야 하므로 원문을 자르거나 생략 표시(marker)를 넣지 않습니다. 허용된 입력의 제외 범위·반환 위치는 그대로이며, 백틱이나 물결표로 감싼 코드 블록(fence) 내부 `>`를 인용으로 세지 않는 정책도 공유합니다.

**회귀 선언:** [MathScannerFixtureTests](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `inlineScannerRejectsExcessiveQuoteDepthWithoutChangingSource`는 CR·LF·CRLF에서 깊이 64의 원문 범위를 유지하고 깊이 65를 거절합니다. `inlineScannerAllowsQuoteLikeFencedCodeAndKeepsOriginalOffsets`는 코드 블록 본문과 다국어 앞부분의 UTF-8 범위를 검사합니다.

**검수 경계:** 공개 API의 UTF-16 위치 변환과 제외 범위는 기존 [inlineMathScannerUsesCanonicalRulesAndPreservesUTF16Ranges](../../../Tests/RichMarkdownTests/RichMarkdownUIViewTests.swift)도 함께 확인해야 합니다. 깊게 중첩된 입력에서 실제 앱 중단이 재현됐다는 주장과, 입력 제한을 공유하도록 수정했다는 사실은 구분합니다.

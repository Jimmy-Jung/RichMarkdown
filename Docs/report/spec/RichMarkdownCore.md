# RichMarkdownCore 동작 명세

기준일: 2026-10-06 · 현재 구현의 계약입니다.

이 문서는 Core 내부 모듈이 원문을 분석하는 방법, 원문 위치를 나타내는 기준, 대기 요청을 합치는 규칙을 정의합니다. SwiftPM의 target은 함께 컴파일하는 코드 단위이고, product는 외부에 공개하는 사용 단위입니다. Core는 별도 공개 product가 아니며 UI를 만들지 않습니다.

[아키텍처](../architecture/RichMarkdownCore.md), [ADR](../adr/README.md#richmarkdowncore-adr), [개선 기록](../improvements/RichMarkdownCore.md)을 함께 읽습니다. 공개 product와 지원 OS 선언은 [Package.swift](../../../Package.swift)를 기준으로 합니다.

아래 테스트는 **소스에 존재하는 선언 근거**입니다. 실행 결과는 [검수 기록](../validation.md)을 따르며, 표의 수용 조건 자체는 실행 통과 판정이나 성능 보장이 아닙니다.

## 파싱과 원문 보존

파싱은 Markdown 원문을 문단·코드·링크 등의 문서 구조로 바꾸는 작업입니다. 이 구조를 AST(추상 구문 트리)라고 하며, Core는 AST를 두 번 만들어 Markdown 기호가 수식 내용을 바꾸지 않도록 보호합니다. 아래의 `source`는 구분자를 포함한 원문, span은 원문에서 수식이 차지하는 구간을 뜻합니다.

UTF-8은 문자를 바이트로 저장하는 방식이고 UTF-16은 16비트 단위로 저장하는 방식이며, Swift `Character`는 결합 문자나 이모지 조합을 하나로 묶은 글자 단위입니다. 단순화한 예 `A😀B`는 UTF-8로 6바이트, UTF-16으로 4단위, Swift `Character`로 3개입니다. Core의 UTF-8 반열린 범위 `1..<5`는 시작 위치 1을 포함하고 끝 위치 5를 제외하므로, 이 예에서 이모지의 4바이트를 가리킵니다.

| ID | 현재 요구·수용 조건 | 구현 | 관련 테스트 선언 |
| --- | --- | --- | --- |
| CORE-001 | Core는 외부에 공개하는 product 없이 같은 패키지에서만 접근하는 `package` 모델·파서를 제공합니다. UI 프레임워크에 의존하지 않습니다. | [패키지 선언](../../../Package.swift), [모델](../../../Sources/RichMarkdownCore/ParsedDocument.swift) | 패키지 선언과 import를 코드에서 확인했습니다. 별도 경계 테스트는 없습니다. |
| CORE-002 | 두 단계 AST 파싱 사이에서 원문 수식을 보호합니다. Markdown 기호가 든 수식도 원문이 유지되어야 합니다. | [DocumentBuilder](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `mathWithAsteriskSurvivesMarkdown`, `mathWithUnderscoreBracketSurvivesMarkdown`, `linkLikeMathSourceSurvives` |
| CORE-003 | 수식 부분을 임시 문자로 덮은 보호 버퍼는 원문과 UTF-8 바이트 길이가 같고 CR·LF 줄바꿈 바이트를 보존해야 합니다. 보호한 수식 구간을 복원하면 바이트 단위로 원문과 같아야 합니다. | [MathProtector](../../../Sources/RichMarkdownCore/MathProtector.swift) | [보호·복원 테스트](../../../Tests/RichMarkdownCoreTests/MaskRoundTripTests.swift)의 `maskPreservesByteLengthAndNewlines`, `restoreProtectRoundTripIsExact`, `fuzzRoundTrip` |
| CORE-004 | 수식 구간은 UTF-8 반열린 범위이며 구분자 포함 `source`를 보존합니다. 한글·이모지·결합 문자·오른쪽에서 왼쪽으로 쓰는 문자(RTL) 주변과 CR·LF·CRLF 줄바꿈의 원문 위치를 유지해야 합니다. CRLF는 한 행 종료이며 정수 범위를 넘길 열 번호는 nil로 거절합니다. | [MathSpan](../../../Sources/RichMarkdownCore/MathSpan.swift), [UTF8LineMap](../../../Sources/RichMarkdownCore/UTF8LineMap.swift) | [보호·복원 테스트](../../../Tests/RichMarkdownCoreTests/MaskRoundTripTests.swift)의 `spanSourceMatchesOriginalSlice`, `multilingualSurroundingRangesPreserved`, `lineMapMatchesDependencySourceLocations`, `lineMapRejectsOverflowingColumn`; [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `koreanEmojiCombiningRTLOffsets`, `commonMarkLineEndingsPreserveMathAndCodeBarriers` |
| CORE-005 | 문단·제목·코드·블록 수식·인용·순서 있는 목록과 없는 목록·표·수평 구분선을 내부 모델로 변환합니다. 수식은 문서 순서로 중복 제거해 수집합니다. | [모델](../../../Sources/RichMarkdownCore/ParsedDocument.swift), [builder](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) | [Render 모델 테스트](../../../Tests/RichMarkdownTests/RichMarkdownRenderModelTests.swift)의 `parsesTableStructureAlignmentAndInlineContent`; 전체 블록 종류와 수식 중복 제거를 한 번에 확인하는 전용 테스트는 없습니다. |
| CORE-006 | 일반 텍스트의 `\*` 같은 기호 이스케이프와 `&amp;` 같은 HTML 문자 표기는 해석합니다. 수식 원문과 미완성 수식 구분자의 역슬래시는 보존합니다. | [DocumentBuilder](../../../Sources/RichMarkdownCore/DocumentBuilder.swift), [MarkdownUnescaping](../../../Sources/RichMarkdownCore/MarkdownUnescaping.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `htmlEntitiesAroundInlineMathRemainDecoded`, `decodedEntityCannotCollideWithOpaqueMathMarker`, `escapedMathDelimitersKeepBackslash`, `mathSourceKeepsItsBackslashes` |

## 구분자와 문맥

구분자는 `\(`와 `\)`처럼 수식의 시작과 끝을 나타내는 기호입니다. 문장 안에 놓는 수식을 인라인(inline), 문단 전체를 차지해 별도로 표시하는 수식을 블록 또는 display 수식이라고 합니다. 코드·HTML 안의 같은 기호는 수식으로 오인하지 않도록 제외합니다.

| ID | 현재 요구·수용 조건 | 구현 | 관련 테스트 선언 |
| --- | --- | --- | --- |
| CORE-007 | 기본 `\(...\)`은 한 행 안의 인라인 수식입니다. `\[...\]`은 바깥 공백을 제외한 문단 전체일 때만 블록 수식입니다. 빈 내용·중첩·닫히지 않은 괄호 구분자는 텍스트와 내부 진단으로 남습니다. | [MathScanner](../../../Sources/RichMarkdownCore/MathScanner.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `inlineParenMath`, `displayBracketWholeParagraphIsBlockMath`, `midParagraphDisplayBracketStaysPlainText`, `emptyInlineMathStaysPlain`, `nestedDelimiterStaysPlainTextEntirely` |
| CORE-008 | 달러 기호 수식은 옵션으로 명시적으로 켜야 합니다(opt-in). `.single`은 `$...$`, `.inlineDouble`은 문장 안 `$$...$$`를 켭니다. 옵션이 하나라도 켜지면 문단 전체의 `$$...$$`는 블록 수식으로 먼저 판정합니다. | [DollarMathOptions](../../../Sources/RichMarkdownCore/MathSpan.swift), [scanner](../../../Sources/RichMarkdownCore/MathScanner.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `dollarMathDisabledByDefault`, `inlineDoubleDollarWorksWithoutSingleDollar`, `paragraphWideDoubleDollarStaysDisplayWithInlineDoubleEnabled` |
| CORE-009 | 인라인 달러 수식은 시작 기호 직후·끝 기호 직전의 공백이나 탭, 끝 기호 직후의 ASCII 숫자, 줄바꿈을 허용하지 않습니다. 통화 표현은 이 규칙으로만 구별하며 모든 통화 표현의 식별을 보장하지 않습니다. | [MathScanner](../../../Sources/RichMarkdownCore/MathScanner.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `currencyRangeStaysPlain`, `closingDollarFollowedByDigitStaysPlain`, `inlineDoubleDollarFollowsSpacingDigitAndLineRules`, `inlineDollarDoesNotCrossNewline` |
| CORE-010 | 코드·HTML은 내부나 경계를 가로지르는 수식을 허용하지 않는 제외 구간(hard barrier)입니다. 링크·이미지 내부 구분자는 수식이 아니며, 수식 내용이 링크·이미지처럼 보이는 범위를 완전히 감싸면 수식이 우선합니다. | [Pass1Collector·MathScanner](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `inlineCodeProtectsDelimiters`, `fencedCodeBlockProtectsDelimiters`, `htmlBlockProtectsDelimitersAndShowsLiteral`, `linkInternalDelimiterProtected`, `linkLikeMathSourceSurvives` |
| CORE-011 | 링크는 URL 종류를 나타내는 scheme이 `https`·`http`·`mailto`일 때만 모델에 남깁니다. 상대 URL·다른 scheme은 링크 이름, 이미지는 대체 텍스트, HTML은 원문 텍스트로 표시합니다. | [LinkPolicy](../../../Sources/RichMarkdownCore/ParsedDocument.swift), [builder](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `allowedSchemesBecomeLinks`, `disallowedSchemeAndRelativeURLStayPlainText`, `imageAltOnlyAndInternalDelimiterProtected`, `htmlBlockProtectsDelimitersAndShowsLiteral` |

## 입력 상한

| ID | 현재 요구·수용 조건 | 구현 | 관련 테스트 선언 |
| --- | --- | --- | --- |
| CORE-012 | 문서 전체 분석(full parse)의 원문이 262,144 UTF-8 바이트를 초과하면 앞부분을 65,536바이트 이내로 남깁니다. `Character` 중간에서 자르지 않고 빈 줄·생략 표시를 붙이며 `wasTruncated = true`를 보존합니다. 표시를 붙인 최종 길이는 65,536바이트보다 큽니다. | [InputLimits](../../../Sources/RichMarkdownCore/InputLimits.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `oversizedInputIsTruncatedWithMarker`; [Render 모델 테스트](../../../Tests/RichMarkdownTests/RichMarkdownRenderModelTests.swift)의 `oversizedRequestUsesBoundedFallbackAsItsParseCacheKey` |
| CORE-013 | 문서 전체 분석은 인용 중첩 깊이 64를 초과한 행 앞에서 자릅니다. 백틱이나 물결표로 감싼 코드 블록(fence) 내부의 `>`는 인용 깊이에 더하지 않습니다. CR·LF·CRLF에서 코드 블록과 제한을 판정합니다. | [InputLimits](../../../Sources/RichMarkdownCore/InputLimits.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `excessiveBlockQuoteDepthIsTruncatedBeforeParsing`, `quoteLikeTextInsideFencedCodeDoesNotTriggerDepthLimit`, `deepBlockQuoteAfterCRLineEndingIsTruncated`, `crlfFenceClosingDoesNotBypassFollowingDepthLimit`, `exitingQuotedFenceRestoresDepthLimit` |
| CORE-014 | 표가 32열 또는 헤더 포함 512셀을 초과하면 표 대신 표 원문을 일반 문단으로 표시합니다. 이 대체 표시(fallback)만으로 문서의 `wasTruncated`를 변경하지 않습니다. | [ModelBuilder](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) | [Render 모델 테스트](../../../Tests/RichMarkdownTests/RichMarkdownRenderModelTests.swift)의 `oversizedTableFallsBackToReadableText` |
| CORE-019 | 인라인 수식 구간만 찾는 경로는 262,144바이트 또는 인용 깊이 64를 초과한 입력을 첫 AST 전에 빈 배열 []로 거절합니다. 허용된 입력은 자르거나 생략 표시를 추가하지 않아 원문·제외 범위 위치가 그대로입니다. 코드 블록과 CR·LF·CRLF 판정은 문서 전체 분석과 공유합니다. | [InputLimits](../../../Sources/RichMarkdownCore/InputLimits.swift), [scanner 입구](../../../Sources/RichMarkdownCore/DocumentBuilder.swift) | [입력·기대값 테스트](../../../Tests/RichMarkdownCoreTests/MathScannerFixtureTests.swift)의 `inlineScannerRejectsExcessiveQuoteDepthWithoutChangingSource`, `inlineScannerAllowsQuoteLikeFencedCodeAndKeepsOriginalOffsets` |

수치는 현재 내부 상한이며 공개 API의 고정 옵션이 아닙니다. 4,096바이트 수식 상한은 `MathScanner`가 아닌 UI 수식 처리 서비스가 엔진에 넘기기 전에 검사합니다. 이 사전 검사를 preflight라고 하며, Core의 구간 검색이 긴 수식을 진단하거나 잘라 준다고 해석하지 않습니다.

## 요청 합치기와 스트리밍 끝부분 표시

요청 합치기는 실행 중인 1건을 유지하고, 대기 중인 1건을 가장 최근 입력으로 교체하는 방식입니다. `generation`은 호출자가 정한 요청 순서번호이고, high-water는 지금까지 받은 가장 큰 번호입니다. tail은 스트리밍 중 아직 완성되지 않은 문서 끝부분이며, 표시만 조절하고 원문을 바꾸지 않습니다.

| ID | 현재 요구·수용 조건 | 구현 | 관련 테스트 선언 |
| --- | --- | --- | --- |
| CORE-015 | worker는 `perform` 실행을 1건으로 제한하고 대기는 최신 1건으로 교체합니다. 실행·대기가 모두 없는 상태(idle) 이후에 제출해도 다시 실행합니다. | [CoalescingWorker](../../../Sources/RichMarkdownCore/CoalescingWorker.swift) | [요청 관리자 테스트](../../../Tests/RichMarkdownCoreTests/CoalescingWorkerTests.swift)의 `latestWinsAndSingleConcurrency`, `submitAfterIdleRunsAgain` |
| CORE-016 | 요청번호를 받는 submit 함수(overload)는 최대 수신 번호보다 작거나 같은 `generation`을 받지 않습니다. 실행 중 작업 취소·이전 결과의 화면 반영 차단은 worker의 계약 밖입니다. | [CoalescingWorker](../../../Sources/RichMarkdownCore/CoalescingWorker.swift) | [요청 관리자 테스트](../../../Tests/RichMarkdownCoreTests/CoalescingWorkerTests.swift)의 `lowerGenerationCannotReplaceNewerPendingInput`; 같은 generation 거절의 전용 선언은 없습니다. |
| CORE-017 | 끝부분 표시 변환은 마지막 텍스트 조각(run)의 닫히지 않은 수식 시작 기호(opener)를 표시에서만 숨깁니다. 문단 전체가 사라질 때는 원문 조각을 유지합니다. 달러 기호 옵션과 이스케이프·숫자 문맥을 따릅니다. | [StreamingTail](../../../Sources/RichMarkdownCore/StreamingTail.swift) | [끝부분 표시 테스트](../../../Tests/RichMarkdownCoreTests/StreamingTailTests.swift)의 `stripsUnclosedOpenersAtTail`, `emptyParagraphGuardAndRunRemoval`, `doubleDollarOpenerIsHiddenOnlyWithInlineDoubleOption`, `escapesAndLoneBackslash` |
| CORE-018 | 끝부분을 흐리게 표시하는 페이드는 연속된 텍스트 조각에서, 결합 문자를 포함한 글자 단위(grapheme)로 계산합니다. 코드·수식·링크·줄바꿈에서 멈춥니다. 마지막 글자의 불투명도(alpha)는 0.2이며 count 0은 페이드 비활성입니다. | [StreamingTail](../../../Sources/RichMarkdownCore/StreamingTail.swift) | [끝부분 표시 테스트](../../../Tests/RichMarkdownCoreTests/StreamingTailTests.swift)의 `fadeCountsGraphemeClusters`, `fadeStopsAtNonTextRuns`, `fadeAnchorsToTheEndRegardlessOfLength`, `zeroCountDisablesFade` |

## 현재 보장의 경계

- UI 작업을 보호하는 `MainActor`에서 동기 파서를 직접 호출하면, 그 작업이 자동으로 다른 실행 위치로 이동하지 않습니다. worker 경로의 스레드 표본은 [OffMainExecutionTests](../../../Tests/RichMarkdownCoreTests/OffMainExecutionTests.swift)가 검사하며 실제 화면 반응 속도 측정을 대체하지 않습니다.
- `UTF8LineMap`의 CR 행 처리와 수식 검색 전 검사는 [개선 기록](../improvements/RichMarkdownCore.md)에 반영 상태를 기록했습니다. 일반 Core 파서는 편집기가 기호를 이스케이프해 저장한 문단과 길이가 다른 백틱 코드 블록도 해석합니다. `canonicalEditorParagraphEscapesAndVariableCodeFenceStayLiteral`이 이 상호운용 계약을 검사합니다.
- 테스트 함수의 존재는 실행 성공을 의미하지 않습니다. 경계 검사·수식 이미지·뷰 높이·선택·접근성의 UI 계약은 [RichMarkdown spec](RichMarkdown.md)을 따릅니다.

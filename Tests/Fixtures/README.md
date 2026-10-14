# 공용 fixture 코퍼스 계약

- 작성: JunyoungJung · 2026-10-14
- 정본: iOS 저장소 `Tests/Fixtures/`. Android 저장소는 `scripts/sync-ios-fixtures.sh`로 `richmarkdown-core/src/test/resources/fixtures/`에 복사하고 `manifest.json`의 SHA-256으로 일치를 검사한다.
- 목적: 두 플랫폼의 Core 파서가 **같은 입력**에 **같은 구조**를 내는지(패리티), 어떤 입력에도 크래시·멈춤 없이 제한값 안에서 끝나는지(견고성)를 같은 파일로 검사한다.

## 1. 디렉터리

| 경로 | 내용 | 개수 기준 |
|---|---|---|
| `commonmark/spec-0.31.2.json` | CommonMark 0.31.2 공식 예제 652개(`markdown`·`html`·`section`). 출처 <https://spec.commonmark.org/0.31.2/spec.json>, CC-BY-SA 4.0. HTML 결과는 쓰지 않고 입력만 쓴다 | 652 |
| `math/*.md` | 수식 구분자 경계: 중첩·미종료·escape·통화·코드/링크/HTML 문맥·Markdown 기호 포함 수식 | 20+ |
| `unicode/*.md` | 한글·이모지(ZWJ)·결합 문자·RTL·서로게이트·BOM·CRLF·zero-width·NFC/NFD | 10+ |
| `markdown/*.md` | GFM 표·취소선·중첩 목록·링크·이미지·HTML·setext·indented code | 12+ |
| `streaming/*.md` + `*.chunks.json` | prefix 시퀀스 검사용 본문과 조각 크기 계획 | 6+ |
| `pathological/*.gen.json` | 병리 입력 **생성 규칙**(큰 파일을 커밋하지 않는다) | 10+ |
| `security/*.md` | 링크 스킴·HTML·이미지·directive 페이로드. 파서 수준 기대값은 `.meta.json` | 16+ |
| `security/mermaid/*.mmd` | Mermaid XSS 페이로드. Mermaid 모듈 테스트가 사용 | 12+ |
| `samples/*.md` | LLM 답변 유형 샘플(수학·과학·코드·표·목록·혼합, 한국어) | 12+ |
| `regressions/*.md` | 퍼즈가 찾은 최소화 입력. 파일명 `<seed>-<n>.md` | 발견 시 |
| `manifest.json` | 전체 파일의 상대 경로·바이트·SHA-256. `scripts/fixtures-manifest.py`가 생성 | 1 |
| `parity-exceptions.json` | 플랫폼 차이를 **의도된 것**으로 승인한 목록(fixture id, 이유, ADR 링크) | 1 |

파일 id는 확장자를 뺀 상대 경로다(`math/currency-dollar`). `.md`는 입력 원문 그대로이며 줄 끝은 LF다(CRLF 검사 fixture만 CRLF).

## 2. 사이드카 `.meta.json` (선택)

```json
{
  "dollarMath": ["single", "inlineDouble"],
  "budgetMs": 500,
  "expect": {
    "truncated": false,
    "mathLatex": ["A = \\pi r^2"],
    "mathKinds": ["inlineParen"],
    "blockTypes": ["p", "code", "table"],
    "diagnostics": ["nestedDelimiter"],
    "linkCount": 0,
    "plainTextContains": ["c"]
  }
}
```

- `dollarMath` 생략 = 옵션 없음. 값은 `single`·`inlineDouble`.
- `budgetMs` 생략 = 1000(Debug 빌드·시뮬레이터·JVM 공통 기본). 병리 입력은 규칙 파일에 둔다.
- `expect`의 각 키는 있을 때만 검사한다. `mathLatex`·`mathKinds`는 `allMathSegments` 순서, `blockTypes`는 최상위 블록의 `t` 순서, `linkCount`는 문서 전체의 `link` run 수. `plainTextContains`의 대상 문자열은 run의 `v`·수식 `source`·코드 블록 `code`를 문서 순서로 잇고 블록 사이에 `\n`을 넣은 것이다. `diagnostics` 비교는 종류만, 위치(`range`) 기준 안정 정렬 뒤 문서 순서다.

## 3. 정규화 JSON (플랫폼 중립)

각 러너는 파싱 결과를 아래 형식으로 직렬화해 `RICHMARKDOWN_FIXTURE_OUT/<platform>/<id>.json`에 쓴다. 키 순서·공백은 비교에 쓰지 않는다(파싱해 비교). 문자열은 그대로(이스케이프만 JSON 규칙).

```
document := {"truncated": bool, "diagnostics": [diagKind], "blocks": [block]}
block    := {"t":"p","runs":[run]}
          | {"t":"h","level":1..6,"runs":[run]}
          | {"t":"code","lang":string|null,"code":string}
          | {"t":"math","kind":mathKind,"latex":string,"source":string}
          | {"t":"quote","blocks":[block]}
          | {"t":"ul","items":[[block]]}
          | {"t":"ol","start":int,"items":[[block]]}
          | {"t":"table","align":[("left"|"center"|"right"|null)],"header":[[run]],"rows":[[[run]]]}
          | {"t":"hr"}
run      := {"c":"text","v":string} | {"c":"code","v":string}
          | {"c":"math","kind":mathKind,"latex":string,"source":string}
          | {"c":"link","v":string,"href":string}
          | {"c":"br"} | {"c":"sbr"}
            + 선택 키 "b":true, "i":true, "s":true (거짓이면 키 생략)
mathKind := "inlineParen" | "displayBracket" | "inlineDollar" | "displayDollar" | "inlineDoubleDollar"
diagKind := "unterminatedDelimiter" | "emptyMath" | "nestedDelimiter" | "oversizedMathSource" | "nonParagraphDisplayDelimiter"
```

- iOS `MathKind`/`MathDiagnostic.Kind`는 case 이름 그대로, Android는 enum 이름의 첫 글자를 소문자로 바꾼다(`InlineParen` → `inlineParen`).
- `href`는 플랫폼 URL 타입의 `absoluteString`/`toString()`. 둘이 다르면 패리티 예외로 기록한다.
- `diagnostics`는 종류만 문서 순서로 나열한다(위치 단위가 UTF-8/UTF-16으로 달라 비교하지 않는다).

## 4. 러너 동작

```
for fixture in corpus:
    input   = read(fixture.md) 또는 pathological 규칙으로 생성
    options = meta.dollarMath
    t0 = now; doc = parse(input, options); elapsed = now - t0
    assert elapsed < meta.budgetMs
    norm = normalize(doc)
    write RICHMARKDOWN_FIXTURE_OUT/<platform>/<id>.json   # 환경 변수 없으면 생략
    if <id>.expected.json 존재: assert norm == expected    # 파싱 후 비교
    check meta.expect
commonmark spec: 예제마다 id = "commonmark/<example 번호>", 기대값 없음, 무크래시·시간만
```

`scripts/fixtures-parity.py <ios-out> <android-out>`가 두 출력 디렉터리를 비교해 `일치 / 예외 승인 / 미해결 차이` 표를 만든다. 미해결 차이는 결함이거나 새 예외 후보다. 비교 전에 `href`는 표기를 정규화한다: 퍼센트 디코딩(iOS `URL`은 `%5D`, Android `URI`는 `]`), 비ASCII 호스트는 IDNA punycode, 빈 포트 제거. `parity-exceptions.json`의 `ignore` 필드는 두 러너의 기대값 비교에서도 같은 방식으로 뺀다.

알려진 상위 파서 차이: iOS가 쓰는 cmark-gfm은 CommonMark 0.31.2 이전 규칙을 따라 ① 8자리 숫자 문자 참조(`&#87654321;`)를 U+FFFD로 해석하고(예제 28) ② `£`·`€` 같은 통화 기호를 구두점으로 보지 않아 `*£*`를 기울임으로 만든다(예제 354). Android의 commonmark-java 0.30은 0.31.2 명세대로 동작한다. 두 예제는 `parity-exceptions.json`에 상위 차이로 기록한다.

## 5. 병리 입력 생성 규칙 (`pathological/*.gen.json`)

```json
{"kind":"repeat","unit":"> ","count":10000,"suffix":"깊은 인용","budgetMs":2000}
{"kind":"repeat-lines","line":"- 항목 \\(x\\)","count":20000,"budgetMs":3000}
{"kind":"nested-list","depth":500,"indent":"  ","item":"- 항목","budgetMs":2000}
{"kind":"math-oversize","open":"\\(","close":"\\)","fill":"x","count":4097,"budgetMs":500,"expect":{"diagnostics":["oversizedMathSource"]}}
{"kind":"repeat","unit":"$","count":100000,"dollarMath":["single"],"budgetMs":3000}
```

- `repeat`: `unit × count + suffix`. `repeat-lines`: `prefix`(선택, 기본 빈 문자열) 뒤에 `line`을 `count`번 `\n`으로 연결. `nested-list`: `i`번째 줄은 `indent × i + item`(0 ≤ i < depth)을 `\n`으로 연결. `math-oversize`: `open + fill × count + close`. `table`: 머리글 `| cell | cell | … |`(열 `columns`개), 구분선 `|---|---|…|`, 본문 `rows`개 줄 — 모두 `\n`으로 연결.
- 규칙 파일의 `dollarMath`·`expect`는 `.meta.json`과 같은 뜻이다.
- 생성 결과의 UTF-8 바이트 수가 256 KiB를 넘으면 `truncated == true`를 기대한다(별도 `expect.truncated`가 없어도).

## 6. 퍼즈 생성기 (두 플랫폼 동일 결과)

같은 시드에서 같은 입력열이 나오도록 아래를 그대로 구현한다.

- RNG: SplitMix64. `state += 0x9E3779B97F4A7C15; z = state; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) * 0x94D049BB133111EB; return z ^ (z >> 31)` (64-bit wrapping, 부호 없는 비교·나눗셈).
- `pick(n) = next() % n` (부호 없는 64-bit 나머지).
- 알파벳(순서 고정, 29개): `"a"`, `"한"`, `"🙂"`, `"👨‍👩‍👧"`, `"é"`, `"ע"`, `"\\"`, `"("`, `")"`, `"["`, `"]"`, `"$"`, `" "`, `"\n"`, `"\r\n"`, `"*"`, `"_"`, `"`"`, `"~"`, `"#"`, `">"`, `"-"`, `"|"`, `"<"`, `"!"`, `"​"`, `"﻿"`, `"1"`, `"."`.
- 기본 입력: `base = corpus[pick(corpus.count)]` (corpus는 `math/`·`markdown/`·`unicode/`·`samples/`의 `.md`를 id 사전순으로 정렬한 목록).
- 변이 `k = 1 + pick(8)`회, 각 회차 `op = pick(6)`:
  0 삽입: 위치 `pick(len+1)`에 알파벳 원소 `pick(29)` 삽입
  1 삭제: 길이가 1 이상이면 위치 `pick(len)`의 **스칼라 1개** 삭제
  2 중복: 범위 `[a, b)` (`a = pick(len)`, `b = a + pick(min(64, len - a) + 1)`)를 그 자리에 두 번
  3 구분자 토글: 입력 안의 `\(`·`\)`·`\[`·`\]`·`$$`·`$` 중 `pick(6)`번째 종류의 첫 출현을 제거(없으면 무시)
  4 줄바꿈 변형: 첫 `\n`을 `\r\n`으로(없으면 끝에 `\n` 추가)
  5 자르기: 길이 `pick(len+1)`의 prefix만 남김
  위치·길이는 **유니코드 스칼라** 단위다(iOS `unicodeScalars`, Kotlin `codePoints`).
- 검사(각 변이 입력마다): ① parse 무예외 ② `elapsed < 500 ms` ③ `restore(protect(bytes)) == bytes` ④ 제한값 준수 — 블록 인용 깊이 ≤ 64, 표 열 ≤ 32·셀 ≤ 512, 그리고 **`latex`(구분자 제외)가 4096 UTF-8 바이트를 넘는 수식 span이 있으면 `diagnostics`에 `oversizedMathSource`가 있어야 한다**(엔진에 들어가는 문자열 기준. span 자체는 보호·유지되고 렌더 단계가 원문으로 표시한다) ⑤ prefix 5개(길이 `pick(len+1)`)도 무예외.
- 파싱 옵션은 `single + inlineDouble`(가장 넓은 경로)로 고정한다.
- op 2(중복)에서 길이가 0이면 RNG를 소비하지 않고 건너뛴다(op 1과 같다).
- `<seed>` 표기는 10진수다(`0x5EED` → `24301`), `n`은 0부터 센다. 파일명 `regressions/24301-12.md`, 덤프 `fuzz-24301.jsonl`.
- 최소화 상한은 60초다. 첫 fixture에 클래스 로딩·JIT가 실리지 않도록 측정 전에 워밍업 파싱을 1회 한다.
- 실패 시: 최소화(스칼라를 하나씩 지우며 실패가 유지되는 가장 짧은 입력) 후 `regressions/<seed>-<n>.md`로 저장하고 테스트는 실패한다.
- 규모: 환경 변수 `RICHMARKDOWN_FUZZ_ITERATIONS`(기본 10000), `RICHMARKDOWN_FUZZ_SEED`(기본 0x5EED). 10만 회 실행은 수동.
- 덤프: `RICHMARKDOWN_FUZZ_DUMP=1`이면 입력과 정규화 결과를 `RICHMARKDOWN_FIXTURE_OUT/<platform>/fuzz-<seed>.jsonl`에 기록해 패리티 비교에 쓴다.

## 7. 렌더 수준 스트리밍 검사 (Core 밖)

`streaming/*.md`와 `*.chunks.json`(`{"sizes":[1,7,64,1024]}`)으로 각 플랫폼 렌더 모델이 조각을 누적 입력했을 때 **최종 결과가 전체 입력 한 번 파싱과 같은지**를 검사한다. 조각은 유니코드 스칼라 단위로 자른다. iOS는 `RichMarkdownTests`, Android는 `richmarkdown` 모듈 테스트에 둔다.

## 8. Mermaid 보안 페이로드 (`security/mermaid/*.mmd`)

각 파일은 Mermaid 원문이다. 모듈 테스트는 렌더 전에 `window.__richmarkdownPwned = 0`을 두고 페이로드가 실행되면 1이 되도록 페이로드를 작성한다. 통과 조건: 렌더 완료(또는 거부) 후 `__richmarkdownPwned == 0`, 네비게이션 0건, 외부 요청 0건. 파일 상단 `%% expect: rejected|rendered` 주석으로 예상 결과를 적는다.

# 코드 블록 확장: Prism 하이라이팅과 Mermaid 다이어그램

- 작성자: JunyoungJung
- 작성일: 2026-09-14 (KST)
- 상태: 구현 완료. `SwiftLatexHighlight`·`SwiftLatexMermaid` 두 opt-in product로 배포한다.

## 1. 무엇이 바뀌었나

`DEVELOPMENT.md §1`의 비목표에는 「신택스 하이라이팅」, 「Mermaid」, 「WebView」가 들어 있었다.
두 가지 실제 요구가 생겨 이 경계를 바꾼다. 다만 **코어의 경계는 그대로 둔다**.

- `SwiftLatex` product는 여전히 WebKit도 JavaScriptCore도 링크하지 않는다.
  코어에 추가된 것은 프로토콜 2개와 주입 지점 1개뿐이다 (`LatexCodeBlockOptions`).
- 실제 엔진은 각각 별도 product에 있다. 필요 없는 앱은 의존하지 않고, 3 MB가 넘는
  `mermaid.bundle.js`도 링크되지 않는다.

| product | 엔진 | 링크되는 시스템 프레임워크 | 번들 리소스 |
|---|---|---|---:|
| `SwiftLatex` | — | UIKit / SwiftUI | 0 |
| `SwiftLatexHighlight` | Prism 1.30.0 | JavaScriptCore | 약 100 KB |
| `SwiftLatexMermaid` | Mermaid 11.17.2 | WebKit | 약 3.4 MB |

이 문서는 **WKWebView로 공식 Mermaid를 실행하는 경로**를 기록한다.

## 2. 사용법

```swift
import SwiftLatex
import SwiftLatexHighlight
import SwiftLatexMermaid

let options = LatexCodeBlockOptions(
    highlighter: PrismHighlighter.shared,
    diagram: MermaidDiagramRenderer.shared
)

// SwiftUI
LatexMarkdownView(markdown: message)
    .latexTheme(.default)
    .latexCodeBlocks(options)

// UIKit
let view = LatexMarkdownUIView(markdown: message)
view.codeBlocks = options
```

둘 중 하나만 주입해도 된다. 주입하지 않으면 코드 블록은 지금까지와 같은 plain monospace다.

색은 `LatexTheme.syntax`(`LatexSyntaxColors`)가 정한다. 다른 테마 값과 마찬가지로
**역할 단위**이며 문자 구간 단위 지정은 제공하지 않는다.

```swift
var theme = LatexTheme.default
theme.syntax.keyword = .purple
theme.syntax.comment = LatexSyntaxColors.dynamic(light: 0x6B_72_80, dark: 0x9C_A3_AF)
```

## 3. 설계

### 3.1 확장점 두 개, 그 이상은 만들지 않는다

```text
ParsedBlock.codeBlock(language:code:)
  ├─ diagram?.languages에 language가 있으면 → 본문을 다이어그램 뷰로 교체
  ├─ highlighter가 있으면 → plain으로 먼저 그리고, 도착한 UTF-16 범위에 색만 덮음
  └─ 둘 다 없으면 → 기존 plain monospace 경로
```

헤더(언어 라벨 + 복사 버튼)는 세 경로 모두 같다. 다이어그램으로 바뀌어도 **원문은 항상
복사할 수 있다**.

범용 custom renderer API는 여전히 만들지 않는다 (`DEVELOPMENT.md §2`). 확장점은
「코드 블록에 색 범위 주기」와 「특정 언어의 코드 블록을 뷰로 바꾸기」 두 가지로 한정한다.

### 3.2 하이라이팅은 비동기, 크기는 바뀌지 않는다

토큰화는 actor 안에서 끝나고 MainActor를 점유하지 않는다. 코드 블록은 먼저 plain으로
그려지고 색 범위가 도착하면 **색만** 바뀐다. 글자와 폰트가 동일하므로 이미 확정된
코드 블록의 레이아웃 크기가 달라지지 않는다 — 목록이 출렁이거나 셀이 다시 측정되지 않는다.

스트리밍 중에는 원문이 계속 바뀐다. 도착한 범위는 그 범위를 만든 원문과 함께 보관하고,
원문이 달라졌으면 **버린다**. 위치가 밀린 색을 한 프레임도 보여 주지 않는다.

### 3.3 실패는 전부 원문으로 되돌린다

`DEVELOPMENT.md §1`의 「실패 시 표시 원칙」을 그대로 따른다.

| 상황 | 결과 |
|---|---|
| 미지원 언어 | 색 없는 plain 코드 블록 |
| Prism 예외·번들 손상 | 색 없는 plain 코드 블록 |
| 토큰 조각을 이어 붙인 결과가 원문과 다름 | 범위 **전체**를 버리고 plain |
| 코드 블록이 UTF-16 100,000 단위 초과 | 색 없는 plain |
| Mermaid 문법 오류·크기 초과 | 오류 한 줄 + 원문 코드 |
| WebKit 콘텐츠 프로세스 종료 | 한 번만 다시 그리고, 실패하면 원문 코드 |

### 3.4 입력은 코드로 실행되지 않는다

- Prism: 사용자 코드는 `evaluateScript`에 이어 붙이지 않고 `nativeTokenize(source, language)`의
  **문자열 인자**로만 전달한다. `evaluateScript`는 번들 리소스 초기화에만 쓴다.
- Mermaid: 원문은 `callAsyncJavaScript`의 인자다. 페이지는 `securityLevel: 'strict'`,
  CSP `connect-src 'none'`, 링크 실행·외부 이동 차단이며 런타임 다운로드가 없다.

### 3.5 WKWebView는 window 안에서만 로드된다 (실측)

WKWebView를 window에 붙이기 전에 `loadFileURL`을 호출하면 콘텐츠 프로세스가 뜨지 않아
`didFinish`가 오지 않는다. `MermaidDiagramUIView`는 `window != nil`일 때만 렌더를
시작하고 `didMoveToWindow`에서 다시 예약한다. 테스트도 `UIWindow`를 만들어 붙인다.

모든 다이어그램 WebView는 `WKProcessPool` 하나를 공유한다 — 3 MB가 넘는 번들을 매번
새 콘텐츠 프로세스에서 다시 컴파일하지 않는다.

### 3.6 UIKit 렌더러를 SwiftUI에 올릴 때 (실측)

`LatexMarkdownUIView`를 `UIViewRepresentable`로 감싸 SwiftUI `ScrollView`에 넣으면
다이어그램이 보이지 않는다. 다이어그램 높이는 렌더가 끝난 뒤에 정해지는데
`UIViewRepresentable`은 그 뒤의 intrinsic content size 변화를 따라오지 않아 뷰가 0 높이로
접힌다. 둘 중 하나를 쓴다.

- 전용 `UIScrollView`를 가진 `UIViewControllerRepresentable`로 감싼다
  (`Examples/SwiftLatexDemo`의 `CodeBlockExtensionUIKitController`, 다른 UIKit 데모와 같은 방식).
- 또는 `onContentSizeChange`에서 측정한 높이를 SwiftUI state로 올려 `.frame(height:)`에 건다.

SwiftUI `LatexMarkdownView`는 이 문제가 없다 — `MermaidDiagramView`가 안에서 같은 방식으로
높이를 올린다.

## 4. Prism 번들

- 고정 버전: [Prism v1.30.0](https://github.com/PrismJS/prism/releases/tag/v1.30.0)
- 라이선스: MIT. 원문은 `Sources/SwiftLatexHighlight/Resources/Prism/PRISM-LICENSE.txt`.
- 원본을 수정하지 않고 포함했다. `native-tokenize.js`만 이 저장소가 작성한 브리지다.
- 로드 순서가 곧 의존 관계다: `core → clike → markup → css → javascript → jsx →
  typescript → tsx → …`. `extend`로 부모 문법을 참조하므로 순서를 바꾸면 안 된다.

### 4.1 원본과 SHA-256

원본 주소는 `https://raw.githubusercontent.com/PrismJS/prism/v1.30.0/components/<파일명>`이며
라이선스만 `.../v1.30.0/LICENSE`다.

| 번들 파일 | 바이트 | SHA-256 |
| --- | ---: | --- |
| `prism-core.js` | 38451 | `6fe39cc3a95b3da596218fbca3acf03f1208bc936f9fb84d08a2b4a61e2b9af7` |
| `prism-clike.js` | 845 | `6a7e077bbcb4a2259bc3152e55681f804ec8a3c2b969f234bb220df0f2d79654` |
| `prism-markup.js` | 4751 | `981ea1865e1dbe304b661196fac6a6103b4ab19080c58c5b5d8ef2767e905df4` |
| `prism-css.js` | 1746 | `f802a0b3827470dadbbf2841cabd6832fc2d28124ded564d9a590285c627d65d` |
| `prism-javascript.js` | 6325 | `7be3e7caf699bfddcd6d94d01e9df233257477f7f521e6c6765f03bd936a2d3e` |
| `prism-jsx.js` | 4620 | `a361a285f771f9677f8d487e08c475fe7b8a36d407d756380a0bbf13b97e8689` |
| `prism-typescript.js` | 1947 | `9a5181760da3863cb8d414bc756f48853320df224c16bf9f5af2541131bc9412` |
| `prism-tsx.js` | 668 | `9f022f13072288931b8ce4f811fe26f1b276307ad7ee235049b19a8c608c494e` |
| `prism-swift.js` | 4564 | `e0388ce0b2c40de4254865c76c6bfeaaee61f5bbe8af9982b1190a1f1cd01703` |
| `prism-python.js` | 2508 | `fd84d8bedf516b82f1b212fc059d280f8f2ca7230bef6408bea6b5ce4e8e68f4` |
| `prism-json.js` | 592 | `835c44857c3f295f2c5bd70316006e455779da76287b0e14d93bbc995f658e4b` |
| `prism-bash.js` | 9170 | `6c67db1a4c86269dc754b588d0ad3a0cdb295044fd466ea6f66bbf01dec306bd` |
| `prism-kotlin.js` | 2666 | `83691ef79d9bf8bc7436d4cae53f6d40d2891cfc007cd255711b0332018c3c9b` |
| `prism-java.js` | 4130 | `b0cba68acd21aef9605a8ca71bf2fa4579b3b9db63af436ee659f0c727717a8e` |
| `prism-c.js` | 2621 | `326fe0f50c2f00c5c9cf741b693654e215017b5d16a86c1c7938455cc64b340b` |
| `prism-cpp.js` | 3998 | `1f165e550a5545f8e6a32f82e5492273304b78b3495a5666101649d3585d6a0a` |
| `prism-go.js` | 1159 | `a3fcbec67973ab43a7a7ec3cd8e447f254bc0213eed9e6842067da5082bcf60e` |
| `prism-rust.js` | 3819 | `5033845938d1a958bb2a663baa116cecfea679faee91f48c4b9bf0fbdd5b0ae3` |
| `prism-sql.js` | 3451 | `c208fdd212ff69c123c252290d5c325375bfefb0f6c26523b463909606cf3567` |
| `prism-yaml.js` | 3184 | `907706b6b1ca4790755c50ca60f82f0273da640f8dacee5666099ba0bf91b038` |
| `PRISM-LICENSE.txt` | 1066 | `2b947f0901a7ffcf08a89957da9783c0e9c6e72cb6ce8e959f501ab5409e4d2b` |

### 4.2 언어 이름

Prism이 스스로 등록하는 별칭은 그대로 동작한다: `js`, `ts`, `py`, `sh`, `shell`,
`kt`, `kts`, `yml`, `html`, `xml`, `svg`, `webmanifest`. 그 밖에 AI 답변에서 자주 보는
이름만 `PrismHighlighter.aliases`가 보완한다.

| 입력 | 사용하는 문법 |
|---|---|
| `c++`, `cxx`, `cc`, `objective-c++` | `cpp` |
| `golang` | `go` |
| `rs` | `rust` |
| `zsh`, `console`, `shell-session` | `bash` |
| `json5`, `jsonc` | `json` |
| `mysql`, `postgres`, `postgresql`, `sqlite` | `sql` |
| `htm` | `markup` |
| `node` | `javascript` |

목록에 없는 언어는 색 없이 원문으로 표시한다. 문법을 늘리려면 같은 저장소 태그에서
`components/prism-<name>.js`를 받아 `Resources/Prism`에 넣고, `PrismHighlighter.scripts`의
**의존 문법 뒤에** 이름을 추가한 다음 이 표와 SHA-256 표를 갱신한다.

### 4.3 토큰 → 역할 매핑

Prism 토큰은 문법마다 이름이 다르다. 표시에 쓰는 역할은 7종이며, 매핑이 없는 토큰은
색을 주지 않고 본문 색을 유지한다. `operator`와 `punctuation`은 **일부러** 제외했다 —
색을 주면 코드 대부분이 물들어 강조 대비가 사라진다.

| 역할 | 대표 Prism 토큰 |
|---|---|
| `keyword` | keyword, boolean, constant, atrule, null, literal, import, static, directive |
| `string` | string, char, regex, template-string, triple-quoted-string, attr-value, url, scalar |
| `comment` | comment, doc-comment, prolog, doctype, cdata, shebang |
| `number` | number, float, color, datetime |
| `type` | class-name, builtin, namespace, constructor, tag, generic, module, entity |
| `function` | function, function-name, function-variable, method, macro |
| `property` | property, attr-name, annotation, decorator, symbol, label, variable, parameter, key, selector |

## 5. Mermaid 번들

- 고정 버전: Mermaid `11.17.2` (`Sources/SwiftLatexMermaid/Web/package-lock.json`)
- 번들러: esbuild `0.28.2`, `format: 'iife'`, `target: 'safari16'`, `legalComments: 'eof'`
- 서드파티 고지: `Resources/WebAssets/MERMAID-THIRD-PARTY-NOTICES.txt` (64개 패키지)

| 번들 파일 | 바이트 | SHA-256 |
| --- | ---: | --- |
| `mermaid.bundle.js` | 3453031 | `244a929a547cfa38252ef9cabb90052e5f477070c4308a1d09c2c01695fb8615` |
| `index.html` | 3072 | `fb646925c9f12d10a50bb089bf55f3079063f8a5bb062b3dc6cd5bde30cb3499` |

### 5.1 번들 다시 만들기

Node.js가 필요하다. 이 Mac에서는 `node_modules`를 저장소 안에 만들지 않는다.

```sh
cd Sources/SwiftLatexMermaid/Web
npm ci
OUTPUT_DIR=<외장 작업 폴더> npm run build
# 산출물(mermaid.bundle.js, MERMAID-THIRD-PARTY-NOTICES.txt)을 Resources/WebAssets로 복사
```

`OUTPUT_DIR`을 생략하면 `../Resources/WebAssets`에 바로 쓴다.

### 5.2 표시 한계

- 원문 UTF-8 20,000바이트, `maxTextSize` 20,000, `maxEdges` 200, 표시 높이 4,000pt.
- `flowchart: { htmlLabels: false, useMaxWidth: false }` — 라벨을 SVG 텍스트로 그려
  네이티브 화면과 글꼴 해석이 갈리지 않게 한다.
- 가용 폭보다 넓은 다이어그램은 **축소**하고, 좁으면 확대하지 않는다.
- 다크 모드는 Mermaid 내장 `dark` 테마이며 trait 변경 시 다시 그린다.
- 확대는 WebView 스크롤 뷰의 1~5배 줌이다. 세로 스크롤은 바깥 목록이 담당한다.
- 다이어그램 내부 링크·클릭 콜백은 실행하지 않는다.

## 6. 검증

```sh
xcodebuild test -scheme SwiftLatex-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

- `SwiftLatexHighlightTests`: 실제 JavaScriptCore 실행. 문법 16종 로드, 별칭 해석,
  한글·이모지 범위가 `Character` 경계를 지키는지, 토큰 조각이 원문을 손실 없이
  복원하는지, 미지원·빈 입력·초과 입력 fallback, `reset()` 후 동일 결과.
- `SwiftLatexMermaidTests`: 실제 WKWebView 실행. 번들 리소스 존재와 외부 참조 없음,
  flowchart·sequence 렌더, 잘못된 원문 실패 후 같은 WebView 복구, 입력 상한.
- `SwiftLatexTests/CodeBlockExtensionTests`: 코어 구간 분할과 두 렌더러의 배선.

데모는 `Examples/SwiftLatexDemo`의 **코드 블록 확장 (Mermaid · Prism)** 화면이다.
SwiftUI/UIKit 렌더러를 바꿔 가며 두 확장을 켜고 끌 수 있다.

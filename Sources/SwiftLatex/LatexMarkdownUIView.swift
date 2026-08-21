import Combine
import UIKit
// LatexTheme의 SwiftUI.Color를 UIColor로 변환하기 위해서만 쓴다. 뷰 계층은 순수 UIKit이다.
import SwiftUI
import SwiftLatexCore

/// UIKit 네이티브 렌더러. SwiftUI 호스팅 래퍼가 아니다.
///
/// 파싱(`SwiftLatexCore`), 수식 raster(`MathRenderService`), generation 관리
/// (`LatexRenderModel`)는 `LatexMarkdownView`와 동일한 경로를 공유하고
/// 이 타입은 뷰 계층만 담당한다.
///
/// ```swift
/// let view = LatexMarkdownUIView(markdown: message)
/// view.theme = .default
/// view.onContentSizeChange = { [weak cell] in cell?.invalidateIntrinsicContentSize() }
/// ```
public final class LatexMarkdownUIView: UIView {
    /// public ingress에서 한 번 제한한 canonical 입력이다. 과대 원문을 뷰 수명 동안
    /// 보관하지 않고, getter도 실제로 렌더링되는 안전한 텍스트만 반환한다.
    private var boundedMarkdown: InputLimits.BoundedInput

    public var markdown: String {
        get { boundedMarkdown.text }
        set {
            let bounded = InputLimits.bound(newValue)
            guard bounded != boundedMarkdown else { return }
            boundedMarkdown = bounded
            submit()
        }
    }

    public var parsesDollarMath: Bool {
        didSet { if parsesDollarMath != oldValue { submit() } }
    }

    public var theme: LatexTheme {
        didSet {
            guard theme != oldValue else { return }
            // Request에 실리지 않는 변경(인용 바 색 등)은 model이 같은 요청으로 보고
            // dedupe해 게시가 없다. 색·폰트 반영은 rebuild 몫이므로 직접 예약한다.
            scheduleRebuild()
            submit()
        }
    }

    /// 블록 재구성으로 높이가 바뀔 때 호출된다.
    /// 수식 이미지 hydration은 최초 레이아웃 뒤에 오므로, 셀 재사용 환경에서는
    /// 여기서 셀의 self-sizing 재측정을 요청해야 한다.
    public var onContentSizeChange: (() -> Void)?

    /// 테스트에서 idle 판정(`hasOutstandingWork`)에 쓴다.
    let model = LatexRenderModel()
    /// 테스트에서 블록 구성 검증에 쓴다.
    let blockStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var cancellable: AnyCancellable?
    private var rebuildScheduled = false
    private var contentSizeChangeScheduled = false

    /// 마지막 rebuild가 만든 블록별 뷰. 같은 값으로 다시 게시되면 재사용한다.
    private struct RenderedBlock {
        let block: ParsedBlock
        let view: UIView
        /// 이 블록이 수식 이미지 사전에서 찾아 쓴 개수. hydration 게시로 이 수가 바뀌면
        /// attributed string이 달라지므로 뷰를 다시 만들어야 한다.
        let mathImageCount: Int
    }

    /// 블록 뷰 재사용 판정용 겉모습 식별자.
    ///
    /// 해석된 `UIFont`를 그대로 담아 Dynamic Type·Bold Text 같은 trait 변화를 값 비교로
    /// 잡는다. 텍스트 색은 resolved RGBA다 — 다크 모드 전환이 여기서 잡힌다.
    /// `theme` 자체도 담는다: 인용 바 색처럼 Request에 실리지 않는 필드가 바뀌면
    /// 파생 폰트·색만으로는 구별되지 않는다.
    private struct AppearanceKey: Equatable {
        let theme: LatexTheme
        let bodyFont: UIFont
        let codeFont: UIFont
        let textColorRGBA: UInt32
        let displayScale: CGFloat
    }

    private var renderedBlocks: [RenderedBlock] = []
    private var renderedAppearance: AppearanceKey?

    /// 테스트의 조건 기반 idle 대기용 상태다. 외부 API 계약은 아니다.
    var hasPendingRebuild: Bool { rebuildScheduled || contentSizeChangeScheduled }

    public init(markdown: String = "", parsesDollarMath: Bool = false, theme: LatexTheme = .default) {
        self.boundedMarkdown = InputLimits.bound(markdown)
        self.parsesDollarMath = parsesDollarMath
        self.theme = theme
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LatexMarkdownUIView는 코드로만 생성한다")
    }

    private func setUp() {
        addSubview(blockStack)
        NSLayoutConstraint.activate([
            blockStack.topAnchor.constraint(equalTo: topAnchor),
            blockStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            blockStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            blockStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // objectWillChange는 변경 직전에 오므로 rebuild를 다음 MainActor hop으로 미룬다.
        // 같은 요청의 게시 3회(document, mathImages 초기화, hydration)를 1회로 합친다.
        cancellable = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleRebuild()
        }

        if #available(iOS 17.0, *) {
            registerForTraitChanges(
                [
                    UITraitPreferredContentSizeCategory.self,
                    UITraitUserInterfaceStyle.self,
                    UITraitDisplayScale.self,
                ]
            ) { (view: Self, _: UITraitCollection) in
                view.submit()
            }
        }

        // 초기 렌더는 worker 게시를 기다리지 않는다. `submit`이 동기 갱신한 제한된
        // fallback을 바로 구성해 빈 UIView가 한 프레임 보이지 않게 한다.
        submit(showFallbackImmediately: true)
    }

    /// iOS 16 배포 타깃용 경로. iOS 17+는 `registerForTraitChanges`가 담당한다.
    @available(iOS, deprecated: 17.0)
    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if #unavailable(iOS 17.0) {
            submit()
        }
    }

    // MARK: - Render request

    private func submit(showFallbackImmediately: Bool = false) {
        model.submit(currentRequest)

        // 초기 setup에서만 worker 게시 이전 fallback을 즉시 구성한다. 이후 property
        // setter는 coalesced rebuild를 써서 self-sizing callback이 스크롤 중 동기로
        // 재진입하지 않게 한다.
        if showFallbackImmediately {
            rebuildImmediately()
        }
    }

    private var currentRequest: LatexRenderModel.Request {
        LatexRenderModel.Request(
            boundedInput: boundedMarkdown,
            parsesDollarMath: parsesDollarMath,
            pointSize: bodyUIFont.pointSize,
            colorRGBA: UIColor(theme.textColor).resolvedColor(with: traitCollection).rgbaValue,
            displayScale: displayScale,
            mathFont: theme.mathFont
        )
    }

    /// 테마 폰트는 항상 뷰의 `traitCollection`으로 해석한다. 앰비언트(앱 전역) trait을
    /// 쓰면 `traitOverrides`를 건 뷰에서 색·displayScale만 따라오고 글자 크기는 안 따라온다.
    private var bodyUIFont: UIFont {
        theme.bodyFont.resolvedUIFont(compatibleWith: traitCollection)
    }

    private var codeUIFont: UIFont {
        theme.codeFont.resolvedUIFont(compatibleWith: traitCollection)
    }

    /// window에 붙기 전에는 trait의 displayScale이 0일 수 있다.
    private var displayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self, self.rebuildScheduled else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func rebuildImmediately() {
        // `objectWillChange`가 같은 turn에 예약한 rebuild는 취소한다. 초기 fallback은
        // 지금 그렸으므로 다음 MainActor hop에서 같은 계층을 또 만들 필요가 없다.
        rebuildScheduled = false
        rebuild()
    }

    private func rebuild() {
        let signpostState = SwiftLatexSignposts.rebuild.beginInterval("rebuild")
        defer { SwiftLatexSignposts.rebuild.endInterval("rebuild", signpostState) }

        if let document = model.document {
            // 문서는 같아도 theme/color/scale 요청이 바뀌면 새 raster가 필요하다.
            // `imageRequest`가 일치할 때만 이전 bitmap을 쓴다.
            let images = model.imageRequest == currentRequest ? model.mathImages : [:]
            rebuildBlocks(document.blocks, images: images)
        } else {
            // 최신 원문 fallback 즉시 표시 (DEVELOPMENT.md §4).
            //
            // `renderedBlocks`는 비우지 않는다. markdown이 바뀌면 model이 항상
            // `document = nil`을 먼저 게시하므로 스트리밍 append는 매 갱신이 이 단계를
            // 거친다. 여기서 비우면 재사용이 0이 된다. 뷰 인스턴스를 살려 두고 계층에서만
            // 떼어, parse가 끝난 다음 게시에서 앞쪽 블록을 그대로 되돌린다.
            setBlockViews(
                [
                    textView(NSAttributedString(string: model.fallbackMarkdown, attributes: [
                        .font: bodyUIFont,
                        .foregroundColor: UIColor(theme.textColor),
                    ])),
                ],
                reusedCount: 0
            )
        }

        invalidateIntrinsicContentSize()
        scheduleContentSizeChange()
    }

    /// 블록 단위 재사용. `ParsedBlock`이 `Hashable`이라 값 비교로 판단한다.
    ///
    /// 스트리밍 입력은 append 중심이라 앞쪽 블록이 안정적이다. 값이 처음 달라지는
    /// index부터 뒤쪽 전부를 새로 만든다(suffix 교체). 중간 삽입 diff(LCS)는 복잡도
    /// 대비 이득이 없어 구현하지 않는다.
    private func rebuildBlocks(_ blocks: [ParsedBlock], images: [MathSegment: RenderedMath]) {
        let appearance = currentAppearance
        // 폰트·색·scale이 바뀌면 모든 블록의 attributed string이 달라진다.
        let reusable = appearance == renderedAppearance ? renderedBlocks : []

        var reusedCount = 0
        while reusedCount < min(blocks.count, reusable.count) {
            let block = blocks[reusedCount]
            guard reusable[reusedCount].block == block,
                  reusable[reusedCount].mathImageCount == mathImageCount(block, images: images)
            else { break }
            reusedCount += 1
        }

        let fresh = blocks.dropFirst(reusedCount).map { block in
            RenderedBlock(
                block: block,
                view: blockView(block, images: images),
                mathImageCount: mathImageCount(block, images: images)
            )
        }
        let rendered = Array(reusable.prefix(reusedCount)) + fresh

        setBlockViews(rendered.map(\.view), reusedCount: reusedCount)
        renderedBlocks = rendered
        renderedAppearance = appearance
    }

    /// 목표 배열로 `blockStack`을 맞춘다.
    ///
    /// 재사용 prefix가 이미 같은 순서로 실려 있으면 뒤쪽만 교체한다. fallback 뷰가
    /// 실려 있는 등 prefix가 계층과 다르면 전량 재배치하되 뷰 인스턴스는 유지한다.
    /// `addArrangedSubview`는 계층에서 떼어낸 뷰에만 호출한다 — 이미 arranged인 뷰에
    /// 다시 호출하면 순서가 바뀔 수 있다.
    private func setBlockViews(_ views: [UIView], reusedCount: Int) {
        let attached = blockStack.arrangedSubviews
        let prefixIsAttached = attached.count >= reusedCount
            && zip(attached, views).prefix(reusedCount).allSatisfy { $0 === $1 }
        let keptCount = prefixIsAttached ? reusedCount : 0

        for view in attached.dropFirst(keptCount) {
            blockStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views.dropFirst(keptCount) {
            blockStack.addArrangedSubview(view)
        }
    }

    private var currentAppearance: AppearanceKey {
        AppearanceKey(
            theme: theme,
            bodyFont: bodyUIFont,
            codeFont: codeUIFont,
            textColorRGBA: UIColor(theme.textColor).resolvedColor(with: traitCollection).rgbaValue,
            displayScale: displayScale
        )
    }

    /// 이 블록이 수식 이미지 사전에서 실제로 찾아 쓰는 수식 중 준비된 개수.
    private func mathImageCount(_ block: ParsedBlock, images: [MathSegment: RenderedMath]) -> Int {
        switch block {
        case .paragraph(let runs), .heading(_, let runs):
            return runs.reduce(0) { count, run in
                guard case .math(let segment) = run.content, images[segment] != nil else { return count }
                return count + 1
            }
        case .blockMath:
            // 블록 수식은 벡터 뷰로 그려 이미지 사전을 쓰지 않는다. 값이 같으면
            // hydration 게시에서도 무조건 재사용이다.
            return 0
        case .blockQuote(let children):
            return children.reduce(0) { $0 + mathImageCount($1, images: images) }
        case .unorderedList(let items), .orderedList(_, let items):
            return items.joined().reduce(0) { $0 + mathImageCount($1, images: images) }
        case .codeBlock, .thematicBreak:
            return 0
        }
    }

    private func scheduleContentSizeChange() {
        guard !contentSizeChangeScheduled else { return }
        contentSizeChangeScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.contentSizeChangeScheduled = false
            self.onContentSizeChange?()
        }
    }

    // MARK: - Blocks

    private func blockView(_ block: ParsedBlock, images: [MathSegment: RenderedMath]) -> UIView {
        switch block {
        case .paragraph(let runs):
            return runsTextView(runs, images: images, font: bodyUIFont)

        case .heading(let level, let runs):
            let view = runsTextView(
                runs,
                images: images,
                font: theme.headingFont(level: level).resolvedUIFont(compatibleWith: traitCollection)
            )
            view.accessibilityTraits.insert(.header)
            return view

        case .codeBlock(let language, let code):
            return codeBlockView(language: language, code: code)

        case .blockMath(let segment):
            return blockMathView(segment: segment)

        case .blockQuote(let children):
            let bar = UIView()
            bar.backgroundColor = UIColor(theme.quoteBar)
            bar.layer.cornerRadius = 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 4).isActive = true

            let row = UIStackView(arrangedSubviews: [
                bar,
                verticalStack(spacing: 8, children.map { blockView($0, images: images) }),
            ])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .fill
            return row

        case .unorderedList(let items):
            return verticalStack(spacing: 4, items.map { item in
                listRow(marker: "•", monospacedDigit: false, item: item, images: images)
            })

        case .orderedList(let start, let items):
            return verticalStack(spacing: 4, items.enumerated().map { index, item in
                listRow(marker: "\(start + index).", monospacedDigit: true, item: item, images: images)
            })

        case .thematicBreak:
            let line = UIView()
            line.backgroundColor = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1 / displayScale).isActive = true
            return line
        }
    }

    private func listRow(
        marker: String,
        monospacedDigit: Bool,
        item: [ParsedBlock],
        images: [MathSegment: RenderedMath]
    ) -> UIView {
        let label = UILabel()
        label.text = marker
        label.textColor = UIColor(theme.textColor)
        label.font = monospacedDigit ? bodyUIFont.monospacedDigitVariant : bodyUIFont
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [
            label,
            verticalStack(spacing: 4, item.map { blockView($0, images: images) }),
        ])
        row.axis = .horizontal
        row.spacing = 8
        // ponytail: 중첩 스택은 firstBaseline이 불안정하다. top 정렬로 고정한다.
        row.alignment = .top
        return row
    }

    private func codeBlockView(language: String?, code: String) -> UIView {
        let title = UILabel()
        title.text = language ?? "code"
        title.font = theme.codeLabelFont.resolvedUIFont(compatibleWith: traitCollection)
        // secondaryLabel(회색)은 밝은 헤더 배경에서 작은 텍스트 대비 기준(4.5:1)에
        // 미달해 접근성 audit이 실패한다. 테마 텍스트 색을 쓴다.
        title.textColor = UIColor(theme.textColor)
        title.setContentHuggingPriority(.required, for: .horizontal)

        let copy = copyButton(text: code, accessibilityLabel: "코드 복사")

        let header = UIStackView(arrangedSubviews: [title, UIView(), copy])
        header.axis = .horizontal
        header.spacing = 4
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.backgroundColor = UIColor(theme.codeHeaderBackground)

        let body = textView(NSAttributedString(string: code, attributes: [
            .font: codeUIFont,
            .foregroundColor: UIColor(theme.textColor),
        ]))
        body.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let scroll = horizontalScroll(content: body, contentSize: Self.fittingSize(body))
        scroll.backgroundColor = UIColor(theme.codeBlockBackground)

        let container = UIStackView(arrangedSubviews: [header, scroll])
        container.axis = .vertical
        container.alignment = .fill
        container.layer.cornerRadius = 8
        container.clipsToBounds = true
        return container
    }

    /// 블록 수식은 raster가 아니라 SwiftMath의 공개 벡터 뷰로 그린다.
    ///
    /// `MTMathUILabel`은 내부에서 동기 typeset하고 CoreText로 직접 드로잉하므로
    /// 이미지 중간 단계가 없다. 그래서 크기가 이 시점에 확정되고, 이미지 도착을 기다리는
    /// 원문 → 이미지 교체와 그에 따른 셀 리사이즈가 사라진다.
    /// 인라인 수식은 `NSTextAttachment`가 이미지를 요구하므로 raster를 유지한다.
    private func blockMathView(segment: MathSegment) -> UIView {
        let content: UIView
        let contentSize: CGSize
        if let vector = vectorMathView(for: segment) {
            content = vector
            contentSize = vector.intrinsicContentSize
        } else {
            // preflight 초과·latex parse 실패 시 원래 구분자를 포함한 source를 표시한다.
            let view = textView(NSAttributedString(string: segment.source, attributes: [
                .font: codeUIFont,
                .foregroundColor: UIColor(theme.textColor),
            ]))
            content = view
            contentSize = Self.fittingSize(view)
        }

        let copy = copyButton(text: segment.source, accessibilityLabel: "수식 원문 복사")
        let row = UIStackView(arrangedSubviews: [
            horizontalScroll(content: content, contentSize: contentSize),
            copy,
        ])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .top
        return row
    }

    /// 블록 수식의 벡터 뷰. 실패(preflight 초과·latex parse 오류)는 nil이다.
    ///
    /// 요청 재료는 raster와 동일한 `MathRenderKey`다 — 같은 preflight 상한을 지나고
    /// 인라인 수식과 폰트·색·mode 해석이 갈리지 않는다.
    private func vectorMathView(for segment: MathSegment) -> UIView? {
        let textColor = UIColor(theme.textColor).resolvedColor(with: traitCollection)
        let key = MathRenderKey(
            latex: segment.latex,
            mathFont: theme.mathFont,
            pointSize: bodyUIFont.pointSize,
            colorRGBA: textColor.rgbaValue,
            isDisplay: segment.kind.isDisplay,
            displayScale: displayScale
        )
        guard let view = BlockMathVectorView.make(key: key, textColor: textColor) else { return nil }

        // 벡터 드로잉은 텍스트로 읽히지 않는다. raster `UIImageView`와 같은 표현을 준다.
        view.isAccessibilityElement = true
        view.accessibilityLabel = "수식: \(segment.latex)"
        return view
    }

    // MARK: - Inline runs

    private func runsTextView(
        _ runs: [InlineRun],
        images: [MathSegment: RenderedMath],
        font: UIFont
    ) -> LatexTextView {
        let string = NSMutableAttributedString()
        for run in runs {
            string.append(attributed(run, images: images, font: font))
        }
        let view = textView(string)

        // 수식이 든 문단의 접근성 표현: "수식: 원본 LaTeX"를 읽기 순서대로 제공한다.
        // 링크가 있는 문단은 덮어쓰지 않는다 — 개별 link semantics를 없애지 않기 위함 (§5).
        var hasMath = false
        var hasLink = false
        for run in runs {
            switch run.content {
            case .math: hasMath = true
            case .link: hasLink = true
            default: break
            }
        }
        if hasMath && !hasLink {
            view.spokenOverride = spokenText(runs)
        }
        return view
    }

    private func attributed(
        _ run: InlineRun,
        images: [MathSegment: RenderedMath],
        font: UIFont
    ) -> NSAttributedString {
        switch run.content {
        case .text(let string):
            return NSAttributedString(string: string, attributes: baseAttributes(run, font: font))

        case .code(let code):
            var attributes = baseAttributes(run, font: codeUIFont)
            attributes[.backgroundColor] = UIColor(theme.inlineCodeBackground)
            return NSAttributedString(string: code, attributes: attributes)

        case .math(let segment):
            guard let rendered = images[segment] else {
                return NSAttributedString(string: segment.source, attributes: baseAttributes(run, font: font))
            }
            let attachment = MathTextAttachment(image: rendered.image, descent: rendered.descent)
            return NSAttributedString(attachment: attachment)

        case .link(let label, let destination):
            var attributes = baseAttributes(run, font: font)
            attributes[.link] = destination
            // 대비 기준을 넘는 링크 색 + 밑줄(색 외 구분 수단).
            attributes[.foregroundColor] = UIColor(theme.linkColor)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: label, attributes: attributes)

        case .hardBreak:
            return NSAttributedString(string: "\n", attributes: baseAttributes(run, font: font))

        case .softBreak:
            return NSAttributedString(string: " ", attributes: baseAttributes(run, font: font))
        }
    }

    private func baseAttributes(_ run: InlineRun, font: UIFont) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.styled(font, bold: run.bold, italic: run.italic),
            .foregroundColor: UIColor(theme.textColor),
        ]
        if run.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private func spokenText(_ runs: [InlineRun]) -> String {
        runs.map { run in
            switch run.content {
            case .text(let string): return string
            case .code(let code): return code
            case .math(let segment): return "수식: \(segment.latex)"
            case .link(let label, _): return label
            case .hardBreak, .softBreak: return " "
            }
        }.joined()
    }

    // MARK: - View factories

    private func textView(_ attributed: NSAttributedString) -> LatexTextView {
        let view = LatexTextView()
        view.attributedText = attributed
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // 링크 색·밑줄은 attributed string이 정한다.
        view.linkTextAttributes = [:]
        // 폰트는 rebuild가 다시 만든다. UIKit의 자동 스케일링은 쓰지 않는다.
        view.adjustsFontForContentSizeCategory = false
        return view
    }

    private func copyButton(text: String, accessibilityLabel: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        // UIButton(type: .system)의 기본 tint는 시스템 파랑이다. SwiftUI 렌더러와
        // 같은 색 규칙을 쓰고 테마로 제어할 수 있게 textColor로 고정한다.
        button.tintColor = UIColor(theme.textColor)
        button.accessibilityLabel = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        // 최소 44×44pt hit target (§5 접근성). 고정 크기다: 아이콘 교체로 폭이 바뀌면
        // 가로 ScrollView가 재측정되고 XCUITest의 idle 대기가 풀리지 않는다.
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        button.addAction(
            UIAction { [weak button] _ in
                CopyButton.copy(text)
                // ponytail: 체크 표시는 다시 누를 때까지 유지한다 (SwiftUI판과 동일 규칙).
                button?.setImage(UIImage(systemName: "checkmark"), for: .normal)
            },
            for: .primaryActionTriggered
        )
        return button
    }

    /// 가로 스크롤 컨테이너. content 크기를 명시 제약으로 고정해
    /// UIScrollView의 높이 모호성을 없앤다.
    private func horizontalScroll(content: UIView, contentSize: CGSize) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: contentSize.width),
            content.heightAnchor.constraint(equalToConstant: contentSize.height),
            scroll.heightAnchor.constraint(equalToConstant: contentSize.height),
        ])
        return scroll
    }

    private func verticalStack(spacing: CGFloat, _ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    // MARK: - Fonts

    /// 굵게/기울임 적용.
    ///
    /// 한글은 시스템 폰트에 italic 변형이 없어 기울임이 시각적으로 적용되지 않는다
    /// (iOS 제약). italic 요청이 실패할 때 bold까지 잃지 않도록 bold만 재시도한다.
    private static func styled(_ font: UIFont, bold: Bool, italic: Bool) -> UIFont {
        guard bold || italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        if bold,
           let descriptor = font.fontDescriptor.withSymbolicTraits(
               font.fontDescriptor.symbolicTraits.union(.traitBold)
           ) {
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }

    /// 줄바꿈을 유지한 자연 크기. 가로 스크롤 콘텐츠 폭을 정하는 데 쓴다.
    private static func fittingSize(_ view: UITextView) -> CGSize {
        let size = view.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// 인라인 수식 attachment.
///
/// `bounds` 프로퍼티에 넣은 값은 `UITextView`에 실린 뒤 `.zero`로 읽히고 baseline 보정이
/// 사라진다(실측). 그래서 TextKit이 레이아웃 때 실제로 묻는
/// `attachmentBounds(for:proposedLineFragment:glyphPosition:characterIndex:)`를 직접 답한다.
final class MathTextAttachment: NSTextAttachment {
    let descent: CGFloat

    init(image: UIImage, descent: CGFloat) {
        self.descent = descent
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MathTextAttachment는 코드로만 생성한다")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let size = image?.size else { return .zero }
        // origin.y는 baseline 기준 오프셋이다. `-descent`로 내려
        // SwiftUI판의 `baselineOffset(-descent)`와 같은 정렬을 만든다 (§5).
        return CGRect(x: 0, y: -descent, width: size.width, height: size.height)
    }
}

/// 수식 이미지는 text attachment라 본문 텍스트로 읽히지 않는다.
/// 합성 label을 지정한 경우 UITextView 기본 value(본문)와 이중 낭독되지 않도록 value를 비운다.
final class LatexTextView: UITextView {
    var spokenOverride: String? {
        didSet { accessibilityLabel = spokenOverride }
    }

    override var accessibilityValue: String? {
        get { spokenOverride == nil ? super.accessibilityValue : nil }
        set { super.accessibilityValue = newValue }
    }
}

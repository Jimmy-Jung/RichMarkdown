// Created by JunyoungJung on 2026-10-14.

import Foundation
import RichMarkdown
import SwiftUI
import Testing
import UIKit
@testable import RichMarkdownBlockEditor

/// `BlockDocumentUITextView`에 문서를 올리고 window layout까지 마친 상태.
@MainActor
private struct LaidOutDocument {
    let window: UIWindow
    let textView: BlockDocumentUITextView
    let model: BlockEditorModel

    init(_ blocks: [EditorBlock], theme: RichMarkdownTheme = .default) {
        model = BlockEditorModel(blocks: blocks)
        // 높이를 내용보다 넉넉히 잡아 contentSize 변화가 아닌 편집 알림만 재계산을 일으키게 한다.
        textView = BlockDocumentUITextView()
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        textView.attributedText = MarkdownStyler.styledDocument(model.blocks, theme: theme)
        window = UIWindow(frame: textView.frame)
        window.overrideUserInterfaceStyle = .light
        window.addSubview(textView)
        window.isHidden = false
        layOut()
    }

    func layOut() {
        if let manager = textView.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
        }
        window.layoutIfNeeded()
        textView.layoutIfNeeded()
    }

    /// 블록 첫 글자가 놓인 줄의 rect (text view 좌표).
    func lineRect(ofBlock id: UUID) throws -> CGRect {
        let offset = try #require(model.documentRange(for: id)).location
        let start = try #require(textView.position(from: textView.beginningOfDocument, offset: offset))
        let end = try #require(textView.position(from: start, offset: 1))
        return textView.firstRect(for: try #require(textView.textRange(from: start, to: end)))
    }

    var checkboxLayers: [CAShapeLayer] {
        textView.toDoCheckboxDecoration?.layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
    }

    var quoteLayer: CAShapeLayer? {
        textView.quoteBarDecoration?.layer as? CAShapeLayer
    }

    func close() {
        window.isHidden = true
    }
}

/// path의 하위 경로(moveTo 단위)별 bounding box. 둥근 사각형·체크 표시는 제어점도 자기 영역 안에 있다.
private func subpathBounds(_ path: CGPath?) -> [CGRect] {
    guard let path else { return [] }
    var boxes: [CGRect] = []
    var points: [CGPoint] = []
    func flush() {
        guard let first = points.first else { return }
        boxes.append(points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        })
        points.removeAll()
    }
    path.applyWithBlock { element in
        let pointCount = switch element.pointee.type {
        case .moveToPoint, .addLineToPoint: 1
        case .addQuadCurveToPoint: 2
        case .addCurveToPoint: 3
        default: 0
        }
        if element.pointee.type == .moveToPoint { flush() }
        points += (0..<pointCount).map { element.pointee.points[$0] }
    }
    flush()
    return boxes
}

private func rgba(_ color: CGColor?) -> [CGFloat]? {
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let converted = color?.converted(to: srgb, intent: .defaultIntent, options: nil)
    else { return nil }
    return converted.components
}

private func isClose(_ lhs: [CGFloat]?, _ rhs: [CGFloat]?) -> Bool {
    guard let lhs, let rhs, lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.01 }
}

@MainActor
@Suite("편집기 장식 뷰 — 할 일 체크박스·인용 바", .serialized)
struct DecorationViewTests {
    @Test("할 일 체크박스는 문단마다 하나, 체크 표시는 완료 항목에만 텍스트 왼쪽 여백에 그린다")
    func checkboxesDrawOnePerParagraphAndCheckOnlyCompleted() throws {
        let shopping = EditorBlock(kind: .toDo(isChecked: false), text: "장보기")
        let workout = EditorBlock(kind: .toDo(isChecked: true), text: "운동")
        let reading = EditorBlock(kind: .toDo(isChecked: true), text: "독서")
        let document = LaidOutDocument([shopping, workout, EditorBlock(text: "본문"), reading])
        defer { document.close() }
        let layers = document.checkboxLayers
        try #require(layers.count == 3, "미완료 테두리 / 완료 채움 / 체크 표시 layer")

        let unchecked = subpathBounds(layers[0].path)
        let checked = subpathBounds(layers[1].path)
        let marks = subpathBounds(layers[2].path)
        #expect(unchecked.count == 1)
        #expect(checked.count == 2)
        try #require(marks.count == 2, "체크 표시는 완료 항목 수만큼만 그린다")
        for (mark, box) in zip(marks, checked) {
            #expect(box.contains(mark))
        }

        let pairs = try zip(
            [unchecked[0], checked[0], checked[1]],
            [shopping.id, workout.id, reading.id].map(document.lineRect(ofBlock:))
        )
        for (box, line) in pairs {
            #expect(box.width == box.height)
            #expect(box.width <= ToDoCheckboxMetrics.side)
            #expect(box.minX >= 0, "박스는 들여쓰기 여백 안에 있어야 한다")
            #expect(box.maxX <= line.minX, "박스 \(box)가 텍스트 \(line)와 겹친다")
            #expect(line.minY <= box.midY && box.midY <= line.maxY, "박스 \(box)가 줄 \(line)을 벗어난다")
        }

        let decoration = try #require(document.textView.toDoCheckboxDecoration)
        let traits = decoration.traitCollection
        #expect(traits.userInterfaceStyle == .light)
        #expect(layers[0].fillColor == nil, "미완료는 테두리만 그린다")
        #expect(layers[0].strokeColor == UIColor.secondaryLabel.resolvedColor(with: traits).cgColor)
        #expect(layers[1].fillColor == decoration.tintColor.resolvedColor(with: traits).cgColor)
        #expect(layers[2].strokeColor == UIColor.white.cgColor)
        #expect(document.quoteLayer?.path == nil, "인용이 없으면 바를 그리지 않는다")
    }

    @Test("다크 모드 전환과 tint 변경은 체크박스를 현재 trait에 맞춰 다시 칠한다")
    func checkboxColorsFollowTraitsAndTint() throws {
        let document = LaidOutDocument([
            EditorBlock(kind: .toDo(isChecked: false), text: "할 일"),
            EditorBlock(kind: .toDo(isChecked: true), text: "완료"),
        ])
        defer { document.close() }
        let decoration = try #require(document.textView.toDoCheckboxDecoration)
        let layers = document.checkboxLayers
        try #require(layers.count == 3)
        let lightStroke = try #require(layers[0].strokeColor)

        document.window.overrideUserInterfaceStyle = .dark
        document.layOut()

        #expect(decoration.traitCollection.userInterfaceStyle == .dark)
        let darkStroke = try #require(layers[0].strokeColor)
        #expect(darkStroke == UIColor.secondaryLabel.resolvedColor(with: decoration.traitCollection).cgColor)
        #expect(darkStroke != lightStroke)

        document.textView.tintColor = .systemPink
        #expect(layers[1].fillColor == UIColor.systemPink.resolvedColor(with: decoration.traitCollection).cgColor)
        #expect(layers[2].strokeColor == UIColor.white.cgColor, "체크 표시는 채움 위에서 항상 흰색")
    }

    @Test("연속 인용 블록은 세로 바 하나로 잇고 떨어진 인용은 따로, 테마 색으로 그린다")
    func consecutiveQuotesShareOneBarInThemeColor() throws {
        let first = EditorBlock(kind: .quote, text: "첫 인용")
        let second = EditorBlock(kind: .quote, text: "둘째 인용")
        let body = EditorBlock(text: "본문")
        let third = EditorBlock(kind: .quote, text: "셋째 인용")
        let theme = RichMarkdownTheme(quoteBar: Color(red: 0.9, green: 0.3, blue: 0.1))
        let document = LaidOutDocument([first, second, body, third], theme: theme)
        defer { document.close() }
        let shape = try #require(document.quoteLayer)
        let bars = subpathBounds(shape.path)
        try #require(bars.count == 2)

        let firstLine = try document.lineRect(ofBlock: first.id)
        let secondLine = try document.lineRect(ofBlock: second.id)
        let bodyLine = try document.lineRect(ofBlock: body.id)
        let thirdLine = try document.lineRect(ofBlock: third.id)
        #expect(bars[0].minY <= firstLine.midY && bars[0].maxY >= secondLine.midY, "두 인용을 한 바로 잇는다")
        #expect(bars[0].maxY < bodyLine.midY, "인용이 아닌 본문까지 내려오지 않는다")
        #expect(thirdLine.minY <= bars[1].midY && bars[1].midY <= thirdLine.maxY)
        #expect(bars[1].maxY <= thirdLine.maxY + 1, "마지막 인용 바가 문서 끝 빈 문단 줄까지 내려온다")
        let expectedX = document.textView.textContainerInset.left + QuoteBarMetrics.leadingOffset
        for bar in bars {
            #expect(abs(bar.minX - expectedX) < 0.5)
            #expect(abs(bar.width - QuoteBarMetrics.width) < 0.5)
        }
        #expect(isClose(rgba(shape.fillColor), [0.9, 0.3, 0.1, 1]))
        #expect(document.checkboxLayers.allSatisfy { $0.path == nil }, "할 일이 없으면 박스를 그리지 않는다")
    }

    @Test("인용 run 끝의 빈 인용 줄도 바가 덮는다")
    func emptyTrailingQuoteLineKeepsBar() throws {
        let quote = EditorBlock(kind: .quote, text: "인용")
        let emptyQuote = EditorBlock(kind: .quote, text: "")
        let document = LaidOutDocument([quote, emptyQuote, EditorBlock(text: "본문")])
        defer { document.close() }
        let bars = subpathBounds(try #require(document.quoteLayer).path)
        try #require(bars.count == 1)

        let quoteLine = try document.lineRect(ofBlock: quote.id)
        let emptyLine = try document.lineRect(ofBlock: emptyQuote.id)
        #expect(bars[0].minY <= quoteLine.midY)
        #expect(bars[0].maxY >= emptyLine.midY, "빈 인용 줄 \(emptyLine)까지 바 \(bars[0])가 이어져야 한다")
    }

    @Test("다크 모드 전환 뒤에도 인용 바는 경로를 유지하고 테마 색을 현재 trait로 다시 칠한다")
    func quoteBarSurvivesTraitChange() throws {
        let document = LaidOutDocument([EditorBlock(kind: .quote, text: "인용")])
        defer { document.close() }
        let decoration = try #require(document.textView.quoteBarDecoration)
        let shape = try #require(document.quoteLayer)
        let expected = QuoteBarStyle(theme: .default).color
        let lightBars = subpathBounds(shape.path)
        #expect(shape.fillColor == expected.resolvedColor(with: decoration.traitCollection).cgColor)

        document.window.overrideUserInterfaceStyle = .dark
        document.layOut()

        #expect(decoration.traitCollection.userInterfaceStyle == .dark)
        #expect(shape.fillColor == expected.resolvedColor(with: decoration.traitCollection).cgColor)
        #expect(subpathBounds(shape.path) == lightBars)
    }

    @Test("편집 알림은 다음 layout에서 체크박스와 인용 바 위치를 다시 계산한다")
    func textChangeNotificationRebuildsDecorations() throws {
        let paragraph = EditorBlock(text: "본문")
        let document = LaidOutDocument([
            paragraph,
            EditorBlock(kind: .toDo(isChecked: false), text: "할 일"),
            EditorBlock(kind: .quote, text: "인용"),
        ])
        defer { document.close() }
        let textView = document.textView
        let layers = document.checkboxLayers
        try #require(layers.count == 3)
        let boxBefore = try #require(subpathBounds(layers[0].path).first)
        let shape = try #require(document.quoteLayer)
        let barBefore = try #require(subpathBounds(shape.path).first)

        // 본문 끝에서 줄을 하나 추가하면 아래 할 일·인용이 한 줄 내려간다.
        textView.selectedRange = NSRange(location: paragraph.text.utf16.count, length: 0)
        textView.typingAttributes = MarkdownStyler.typingAttributes(for: paragraph)
        textView.insertText("\n둘째 줄")
        document.layOut()

        let boxAfter = try #require(subpathBounds(layers[0].path).first)
        let barAfter = try #require(subpathBounds(shape.path).first)
        #expect(boxAfter.minY > boxBefore.minY + 10)
        #expect(boxAfter.minX == boxBefore.minX)
        #expect(abs((boxAfter.minY - boxBefore.minY) - (barAfter.minY - barBefore.minY)) < 1)
    }
}

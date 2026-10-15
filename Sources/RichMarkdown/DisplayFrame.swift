// Author: JunyoungJung
// Date: 2026-10-15

import QuartzCore

/// 다음 디스플레이 프레임 첫머리에 한 번 실행한다.
///
/// 스트리밍 게시를 임의 시각이 아니라 프레임 시작에 반영해, 이어지는 SwiftUI·UIKit 갱신이 프레임
/// 예산 전체를 쓰게 한다. vsync 직후가 아니라 프레임 중간에 시작한 갱신은 다음 렌더 패스를 놓쳐
/// hitch가 된다(2026-10 iPad 8·iPad Pro 실측). 대가는 최대 한 프레임의 지연이다.
@MainActor
package enum DisplayFrame {
    /// 다음 프레임에 `action`을 실행하도록 예약한다. 테스트는 수동 프레임으로 바꿔 끼운다.
    package typealias Scheduler = @MainActor (_ action: @escaping @MainActor () -> Void) -> Void

    /// main run loop(`.common`)에 붙인 `CADisplayLink`의 첫 콜백에서 `action`을 부르고 링크를 끝낸다.
    /// 기다리는 동작이 없으면 링크도 없다. iOS 16 배포 타깃이라 `UIUpdateLink`(iOS 18+)는 쓰지 않는다.
    @discardableResult
    package static func next(_ action: @escaping @MainActor () -> Void) -> CADisplayLink {
        let link = CADisplayLink(target: Callback(action), selector: #selector(Callback.fire(_:)))
        link.add(to: .main, forMode: .common)
        return link
    }

    /// 링크가 target을 강하게 잡는다. `invalidate()`가 run loop의 링크 참조와 링크의 target 참조를 함께 놓는다.
    @MainActor
    private final class Callback: NSObject {
        let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func fire(_ link: CADisplayLink) {
            link.invalidate()
            action()
        }
    }
}

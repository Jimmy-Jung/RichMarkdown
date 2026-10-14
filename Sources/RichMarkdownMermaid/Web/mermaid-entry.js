// Created by JunyoungJung on 2026-09-14.
// 번들 진입점. WKWebView의 `window.mermaid`로만 노출하고 다른 전역은 만들지 않는다.
// polyfill이 먼저 평가돼야 한다: Mermaid 모듈은 로드하는 순간 Object.hasOwn을 부른다(WebView 91 실측).
import './polyfills.js';
import mermaid from 'mermaid';
window.mermaid = mermaid;

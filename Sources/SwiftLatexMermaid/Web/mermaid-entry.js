// Created by JunyoungJung on 2026-09-14.
// 번들 진입점. WKWebView의 `window.mermaid`로만 노출하고 다른 전역은 만들지 않는다.
import mermaid from 'mermaid';
window.mermaid = mermaid;

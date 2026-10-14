// Created by JunyoungJung on 2026-10-14.
//
// Mermaid 11 번들이 쓰는 내장 API 중 Android System WebView 91(API 30 기본 이미지)에 없는 것만 채운다.
// 실측(2026-10-14 RichMarkdown_API30, WebView 91.0.4472.114): `Object.hasOwn is not a function`으로 번들 전체가
// 로드되지 않아 모든 다이어그램이 원문으로 대체됐다. 번들의 사용처를 집계해 존재 확인 없이 부르는 것은 아래 넷이다.
//   Object.hasOwn (Chrome 93) · Array/String/TypedArray .at (Chrome 92) · structuredClone (Chrome 98)
//   URL.canParse (Chrome 120, 다이어그램 링크 검사에서만 불려 페이로드 테스트 click-href-external이 찾았다)
// iOS 16 이상 WKWebView와 최신 WebView에는 모두 내장돼 있어 이 코드는 아무것도 정의하지 않는다.

if (typeof Object.hasOwn !== 'function') {
    Object.defineProperty(Object, 'hasOwn', {
        value: (object, key) => Object.prototype.hasOwnProperty.call(Object(object), key),
        configurable: true,
        writable: true,
    });
}

function at(index) {
    const length = this.length;
    let relative = Math.trunc(index) || 0;
    if (relative < 0) relative += length;
    return relative < 0 || relative >= length ? undefined : this[relative];
}

const typedArrayPrototype = Object.getPrototypeOf(Int8Array.prototype);
for (const prototype of [Array.prototype, String.prototype, typedArrayPrototype]) {
    if (typeof prototype.at !== 'function') {
        Object.defineProperty(prototype, 'at', { value: at, configurable: true, writable: true });
    }
}

// HTML 구조화 복제 중 Mermaid가 넘기는 값(평범한 객체·배열·Date·RegExp·Map·Set·Error·버퍼)을 다룬다.
// 함수·Symbol처럼 복제할 수 없는 값은 브라우저와 같이 예외를 던진다.
function structuredClonePolyfill(value) {
    const seen = new Map();
    const clone = input => {
        if (typeof input === 'symbol') throw new TypeError('structuredClone: Symbol 값은 복제할 수 없다');
        if (typeof input === 'function') throw new TypeError('structuredClone: 함수는 복제할 수 없다');
        if (input === null || typeof input !== 'object') return input;
        if (seen.has(input)) return seen.get(input);
        if (input instanceof Date) return remember(input, new Date(input.getTime()));
        if (input instanceof RegExp) return remember(input, new RegExp(input.source, input.flags));
        if (input instanceof ArrayBuffer) return remember(input, input.slice(0));
        if (ArrayBuffer.isView(input)) return remember(input, new input.constructor(input));
        if (input instanceof Error) {
            const Constructor = typeof globalThis[input.name] === 'function' ? globalThis[input.name] : Error;
            const output = remember(input, new Constructor(input.message));
            output.stack = input.stack;
            if ('cause' in input) output.cause = clone(input.cause);
            return output;
        }
        if (input instanceof Map) {
            const output = remember(input, new Map());
            input.forEach((item, key) => output.set(clone(key), clone(item)));
            return output;
        }
        if (input instanceof Set) {
            const output = remember(input, new Set());
            input.forEach(item => output.add(clone(item)));
            return output;
        }
        if (Array.isArray(input)) {
            const output = remember(input, new Array(input.length));
            input.forEach((item, index) => { output[index] = clone(item); });
            return output;
        }
        const output = remember(input, {});
        for (const key of Object.keys(input)) output[key] = clone(input[key]);
        return output;
    };
    const remember = (input, output) => {
        seen.set(input, output);
        return output;
    };
    return clone(value);
}

if (typeof URL.canParse !== 'function') {
    Object.defineProperty(URL, 'canParse', {
        value: canParse,
        configurable: true,
        writable: true,
    });
}

function canParse(url, base) {
    try {
        // eslint-disable-next-line no-new
        new URL(url, base);
        return true;
    } catch {
        return false;
    }
}

if (typeof globalThis.structuredClone !== 'function') {
    Object.defineProperty(globalThis, 'structuredClone', {
        value: structuredClonePolyfill,
        configurable: true,
        writable: true,
    });
}

export { at, canParse, structuredClonePolyfill };

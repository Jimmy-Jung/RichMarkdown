// Created by JunyoungJung on 2026-09-14.
//
// 번들에 고정한 이 래퍼만 실행한다. 사용자 코드는 실행할 스크립트에 이어 붙이지 않고
// 이 함수의 문자열 인자로만 전달한다.
//
// Prism.tokenize의 중첩 토큰을 평탄화해 { content, kind } 조각 배열로 만든다.
// 자식 토큰의 역할이 부모보다 우선하고, alias가 있으면 alias를 쓴다.
// 토큰 사이의 일반 텍스트는 부모 역할을 물려받는다.
function nativeTokenize(source, language) {
    var grammar = Prism.languages[language];
    if (!grammar) throw new Error('Unsupported grammar: ' + language);
    var chunks = [];
    function flatten(value, inheritedKind) {
        if (typeof value === 'string') {
            chunks.push({ content: value, kind: inheritedKind });
        } else if (Array.isArray(value)) {
            value.forEach(function (child) { flatten(child, inheritedKind); });
        } else if (value && typeof value.type === 'string') {
            var alias = Array.isArray(value.alias) ? value.alias[0] : value.alias;
            flatten(value.content, typeof alias === 'string' ? alias : value.type);
        } else {
            throw new Error('Unexpected Prism token structure');
        }
    }
    flatten(Prism.tokenize(source, grammar), 'plain');
    return chunks;
}

// Swift가 번들 문법 목록을 물어볼 때 쓴다. 별칭도 Prism.languages에 등록돼 있으면 true다.
function nativeHasGrammar(language) {
    return Boolean(Prism.languages[language]);
}

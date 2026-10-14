검색 파이프라인은 다음과 같습니다.

```mermaid
graph TD
  A[사용자 질의] --> B[정규화]
  B --> C{캐시 적중?}
  C -->|예| D[캐시 응답]
  C -->|아니오| E[벡터 검색]
  E --> F[LLM 응답 생성]
  F --> G[캐시 저장]
  G --> D
```

정규화 단계의 코드는 다음과 같습니다.

```typescript
export function normalize(query: string): string {
  return query.trim().toLowerCase().replace(/\s+/g, " ");
}
```

캐시 적중률이 \(p\)이면 평균 지연은 \(p \cdot t_{\text{cache}} + (1-p) \cdot t_{\text{llm}}\)입니다.

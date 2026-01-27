---
Description: Comprehensive code review
Argument-hint: [file or leave empty for staged changes]
---
Review $ARGUMENTS (or staged changes if not specified) using the code-reviewer subagent.

## Check For
- Security: OWASP Top 10, auth issues, data exposure
- Performance: N+1 queries, memory leaks, blocking calls
- Correctness: Edge cases, error handling, type safety
- Maintainability: Complexity, naming, duplication

## Output Format
### 🚨 Critical (blocks merge)
### ⚠️ Warnings (should fix)
### 💡 Suggestions (nice to have)

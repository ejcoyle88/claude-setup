# Writing Guide for RFCs and ADRs

## Keeping Documents Concise

**Principle**: Shorter documents are more likely to be read. Every sentence should earn its place.

### Strategies

1. **Start with the core message**
   - State the problem and solution upfront
   - Don't bury the lead in background context

2. **Use examples instead of lengthy explanations**
   ```
   ❌ "The system needs to handle various scenarios including but not limited to cases where..."
   ✅ "The system must handle: login timeouts, concurrent sessions, expired tokens."
   ```

3. **Cut redundancy**
   - Don't repeat information between sections
   - If something is in the template example, you don't need to restate it

4. **Use bullet points and tables**
   - Dense paragraphs are harder to scan
   - Tables work well for comparing alternatives

5. **Be specific, not comprehensive**
   ```
   ❌ "We explored many different database solutions and evaluated them thoroughly..."
   ✅ "We evaluated PostgreSQL, MySQL, and SQLite. PostgreSQL won for..."
   ```

## Writing Effective Consequences and Trade-offs

**Principle**: Good decisions acknowledge what they sacrifice. Great consequences sections help future maintainers understand why things are the way they are.

### Structure for Consequences

**What becomes easier:**
- Concrete benefits the decision enables
- New capabilities unlocked
- Problems that are now simpler

**What becomes harder:**
- Constraints introduced
- New complexity or maintenance burden
- Future options that are now closed off

**What stays the same:**
- Clarify what isn't affected (prevents scope creep in discussions)

### Example: "Use Rust for backend"

```markdown
## Consequences

**Easier:**
- Memory safety without garbage collection overhead
- Confident refactoring with compile-time guarantees
- High performance for compute-intensive operations

**Harder:**
- Steeper learning curve for new contributors
- Slower initial development (stricter compiler)
- Smaller ecosystem than Python/Node.js for some libraries

**Unchanged:**
- Frontend technology choices remain independent
- Deployment strategy (containers work the same)
- Testing philosophy (unit/integration/e2e still apply)
```

### Common Pitfalls

1. **Only listing benefits**
   - Every decision has trade-offs
   - If you can't find downsides, you haven't thought hard enough

2. **Vague consequences**
   ```
   ❌ "Will improve developer experience"
   ✅ "Reduces build time from 10min to 2min"
   ```

3. **Ignoring long-term implications**
   - Consider: maintenance, hiring, migration paths, ecosystem trends
   - What happens in 2 years?

## Section-Specific Guidance

### RFC: Problem Section

**Goal**: Convince readers the problem is worth solving.

**Structure**:
1. What's broken/missing (1-2 sentences)
2. Impact on users/business (with metrics if available)
3. Why now (optional: why is this urgent?)

**Keep it short**: 1-2 paragraphs maximum. If you need more, your scope might be too large.

### RFC: Solution Section

**Goal**: Explain the approach at the right level of abstraction.

**Balance**:
- High-level enough that the RFC doesn't become outdated as implementation details change
- Specific enough that reviewers can spot problems

**Include**:
- Core approach (1-2 paragraphs)
- Key architectural decisions
- Diagram if it clarifies (but only if it's simple)

**Avoid**:
- Implementation details that belong in code comments
- Pseudocode unless the algorithm is the point
- Extensive code samples

### RFC: Prior Art Section

**Goal**: Show you've considered alternatives and explain why you rejected them.

**Structure per alternative**:
1. What is it (1 sentence)
2. Why it's appealing (1-2 points)
3. Why we're not using it (1-3 points)
4. Optional: In what situations it would be better

**Common trap**: Strawman alternatives. If you can't steelman an alternative, don't list it.

### ADR: Context Section

**Goal**: Future you (or future maintainers) need to understand what was happening when this decision was made.

**Include**:
- What prompted the decision
- Relevant constraints (time, resources, requirements)
- What was known/unknown at the time

**Length**: 2-4 sentences usually sufficient.

### ADR: Decision Section

**Goal**: State the decision clearly and unambiguously.

**Format**:
- Single sentence for simple decisions
- Bullet points for multi-part decisions
- Avoid justification here (that's what consequences are for)

**Example**:
```
We will use SQLite for the initial MVP, with a migration path to PostgreSQL planned for v2.0.
```

## Review Checklist

Before finalizing an RFC/ADR, check:

- [ ] Can someone unfamiliar with the project understand the problem?
- [ ] Is the decision clear and unambiguous?
- [ ] Have I explained why alternatives were rejected?
- [ ] Do consequences include both benefits and drawbacks?
- [ ] Could I cut 20% of the words without losing meaning?
- [ ] Are there metrics or examples instead of vague claims?
- [ ] Will this make sense to someone reading it in 6 months?

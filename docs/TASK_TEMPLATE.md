# EAD Task Shard Template

Task shards are self-contained specifications that enable a subagent to complete work without asking questions. Each shard contains everything needed for implementation.

**Key Principles:**
- Subagent writes ALL code - shards contain specifications, not implementations
- Follow CLAUDE.md conventions throughout
- TDD approach: write tests first, then implementation
- Not every task requires enforcement tests - suggest them when drift potential is identified
- Code in tasks must be **prescriptive, not suggestive** (see guidelines below)

---

## Template Structure

```markdown
# [Area]-task-[NN]: [Descriptive Name]

## Objective

[2-3 sentences: What are we building and why does it matter?]

---

## Requirements

[Copy specific requirement IDs from requirements.md - surgical excerpts, not entire tables]

| ID | Requirement | Priority |
|----|-------------|----------|
| XXX-01 | [Exact text from requirements.md] | P0 |
| XXX-02 | [Exact text from requirements.md] | P0 |

---

## Design Context

[Relevant excerpts from design docs with file:line references]

From `docs/design-01-architecture.md:142`:
> [Quoted relevant section]

From `docs/design-02-auth.md:87`:
> [Quoted relevant section]

---

## Research

[URLs for external dependencies, documentation, or complex libraries]

- [Dependency Name]: [URL] - [Why it's relevant]
- [API Docs]: [URL] - [Specific section to read]

---

## Patterns to Follow

[file:line references to existing code that demonstrates the pattern]

- Three-tier caching pattern: `api/src/data/collections/base.py:45-120`
- Endpoint structure: `api/src/routes/health.py:15-40`
- Test structure: `api/tests/enforcement/test_env_var_enforcement.py`

---

## Files to Create/Modify

### Create
- `api/src/path/to/new_file.py` - [Brief description]
- `api/tests/test_new_file.py` - [Brief description]

### Modify
- `api/src/existing_file.py` - [What to add/change]

---

## Implementation Notes

[Specific guidance on approach - architectural decisions and key behaviors]

1. [First step or consideration]
2. [Second step or consideration]
3. [Key decision point with recommended approach]

**Code in this section must be PRESCRIPTIVE, not suggestive.** See "When to Include Code" below.

---

## Anti-patterns

[What NOT to do - common mistakes to avoid]

- DO NOT [specific anti-pattern] - [why it's bad]
- DO NOT [specific anti-pattern] - [why it's bad]
- AVOID [pattern] - use [alternative] instead

---

## Success Criteria

[Measurable outcomes - how we know it's done]

- [ ] [Specific, verifiable outcome]
- [ ] [Specific, verifiable outcome]
- [ ] [Specific, verifiable outcome]
- [ ] All tests pass: `poetry run pytest api/tests/path/ -v`
- [ ] Type checking passes: `poetry run mypy api/src/path/`

---

## Verification

[Exact commands to run to confirm completion]

```bash
# Run tests
cd api && poetry run pytest tests/path/to/tests.py -v

# Type check
cd api && poetry run mypy src/path/to/module.py

# Manual verification (if applicable)
curl http://localhost:8000/api/v1/endpoint
```

---

## Enforcement Test Suggestions

[Subagent completes this section at end of task if drift potential identified]

After completing this task, consider whether enforcement tests are needed for:

- [ ] [Pattern that might drift] - Suggested test: [brief description]
- [ ] [Convention that might be violated] - Suggested test: [brief description]

**Note:** Do not implement enforcement tests without approval. Document suggestions here for review.
```

---

## Guidelines for Writing Shards

### When to Include Code (CRITICAL)

Code in task shards must be **prescriptive** (must be done exactly this way) rather than **suggestive** (here's how you might do it). The subagent is capable of writing standard implementations - only include code when deviation would cause problems.

**DO include code for:**
- Exact values that must match across systems (enum values, error codes, magic numbers)
- Specific formulas or algorithms (e.g., exponential backoff: `Math.min(1000 * Math.pow(2, attempts), 30000)`)
- Configuration mappings that must be consistent (e.g., reaction type to emoji mappings)
- Protocol details (WebSocket close codes, message formats that must match client/server)
- Security-critical patterns where the wrong approach creates vulnerabilities

**DO NOT include code for:**
- Standard CRUD operations (subagent knows how to write these)
- Boilerplate (class definitions, imports, basic function signatures)
- Type definitions that follow obvious patterns from the design doc
- API client implementations that follow existing patterns
- Test implementations (describe what to test, not how)

**Example - GOOD (prescriptive):**
```typescript
// These close codes must match between frontend and backend
// 4001: Invalid token
// 4002: Token expired
// 4003: User banned
```

**Example - BAD (suggestive):**
```typescript
// Don't include full class implementations like this:
class WebSocketClient {
  connect() { ... }
  disconnect() { ... }
  // etc.
}
```

Instead, describe the behaviors: "Create a WebSocketClient class with connect/disconnect methods that tracks subscriptions and restores them after reconnection."

### Specificity
- Use exact file:line references, not vague pointers
- Copy relevant requirement text, don't just reference IDs
- Be explicit about files to create vs modify

### Context
- Assume subagent has access to CLAUDE.md and codebase
- Include enough design context that subagent doesn't need to read entire design docs
- Research section prevents subagent from guessing at external dependencies

### Success Criteria
- Every criterion must be verifiable
- Include specific test commands
- "It works" is not a success criterion

### Anti-patterns Section
- Include lessons learned from similar tasks
- Prevent common mistakes before they happen
- Reference enforcement tests that catch these patterns

### Enforcement Test Suggestions
- Subagent fills this out at task completion
- Only suggest tests when genuine drift potential exists
- Suggestions require review before implementation

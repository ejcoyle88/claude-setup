/**
 * Minimal, dependency-free JSON-Schema-*like* structural validator, plus the
 * parse+validate step that sits between a raw Ollama response and a tool
 * result (bead claude-r30.5).
 *
 * Why hand-written instead of a library (e.g. `ajv`, the de-facto standard
 * JSON-Schema validator for Node)? The schemas that ever reach this code are
 * narrow: `summarize_file` and `classify` each build one fixed, flat,
 * one-level-deep object schema themselves (see their tool handlers in
 * `index.ts`); `extract`'s caller-supplied `schema` is open-ended in
 * principle but in practice is the same shape of thing -- a flat-ish object
 * describing a handful of fields, per its own tool description. None of the
 * three need `oneOf`/`anyOf`/`$ref`/`pattern`/numeric bounds/tuple-typed
 * arrays, or any of the rest of full JSON-Schema. Pulling in `ajv` (plus its
 * transitive deps: `fast-deep-equal`, `json-schema-traverse`, `fast-uri`,
 * ...) for "required fields present, typeof matches, enum membership for one
 * string field" is a heavier dependency footprint than the actual need
 * justifies, and this server already has a "read the whole thing" bar for
 * dependencies (see `tools/ollama-mcp/README.md`'s minimal `package.json`).
 * If a future bead needs real JSON-Schema (nested `$ref`, `oneOf`, format
 * validators, etc.), reconsider `ajv` then -- this module deliberately only
 * covers `type: object|array|string|number|integer|boolean`, `required`,
 * `properties` (recursively), `items` (recursively), and `enum`.
 */

/** A JSON-Schema-like object, e.g. `{ type: "object", properties: {...},
 * required: [...] }`. Not a real `JSONSchema` type (no draft is enforced) --
 * matches how `index.ts` already treated schemas passed to Ollama's
 * structured-output `format` field before this bead. */
export type JsonSchema = Record<string, unknown>;

export type ValidationResult = { ok: true } | { ok: false; error: string };

/** Upper bound on `validateAgainstSchema`'s recursion depth (one level per
 * nested `properties`/`items`). The schemas this module documents as its
 * actual scope are flat-ish and one level deep at most, so this is generous
 * headroom above real usage, not a tight fit -- its purpose is purely to
 * turn a pathologically/maliciously deep caller-supplied `schema` (see
 * `extract`'s `schema` argument in `index.ts`, which is otherwise
 * open-ended) into a clean `ok: false` validation result instead of a
 * `RangeError: Maximum call stack size exceeded` crash. Exported so
 * `index.ts`'s `withoutRequiredForChunkMap` -- a second recursion-depth
 * guard against this exact same threat model (the same caller-supplied
 * `extract` schema, walked the same way) -- reuses this constant instead of
 * maintaining an independent literal the two guards could silently drift
 * apart from (bead claude-72l). */
export const MAX_SCHEMA_DEPTH = 20;

/** Human-readable type name for an error message, treating `null` and
 * arrays distinctly from generic "object" (matches JSON-Schema's own type
 * vocabulary, where `null`, `array`, and `object` are separate types even
 * though `typeof null === "object"` and `typeof [] === "object"` in JS). */
function describeType(value: unknown): string {
  if (value === null) {
    return "null";
  }
  if (Array.isArray(value)) {
    return "array";
  }
  return typeof value;
}

/**
 * Checks `value` against `schema`'s declared shape, recursively for nested
 * `properties`/`items`. This is intentionally partial (see file header): an
 * unrecognized or unsupported `schema.type` (e.g. `oneOf`, `type` given as
 * an array of types) is accepted rather than rejected -- this validator's
 * job is to catch the shapes it *can* check, not to be a complete
 * JSON-Schema implementation. `path` is a `$`-rooted pointer used only to
 * make error messages locate the failing field (e.g. `$.items[2].title`).
 * `depth` guards recursion (see `MAX_SCHEMA_DEPTH`) -- callers should not
 * normally pass it; it's incremented on each recursive call into a nested
 * `properties`/`items` schema.
 */
export function validateAgainstSchema(schema: JsonSchema, value: unknown, path = "$", depth = 0): ValidationResult {
  if (depth > MAX_SCHEMA_DEPTH) {
    return { ok: false, error: `${path}: schema nested too deeply (exceeds max depth ${MAX_SCHEMA_DEPTH})` };
  }

  const type = schema.type;
  // A `schema.type` of exactly "object" is the common case, but an
  // LLM-authored `schema` (this is exactly `extract`'s caller-supplied
  // path) plausibly omits `type` while still including `required`/
  // `properties` -- e.g. `{ properties: { title: { type: "string" } },
  // required: ["title"] }`. Treat that as an object schema too rather than
  // silently skipping the required/properties checks (review finding:
  // without this, a root schema with no explicit `type` let a response of
  // `{}` pass despite a missing required field). This only fires when
  // `type` is absent -- an explicit non-object `type` (e.g. "string") that
  // also happens to carry a stray `required`/`properties` is left to that
  // type's own branch below, not reinterpreted as an object.
  const isImplicitObjectSchema = type === undefined && (schema.required !== undefined || schema.properties !== undefined);

  if (type === "object" || isImplicitObjectSchema) {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      return { ok: false, error: `${path}: expected an object, got ${describeType(value)}` };
    }
    const obj = value as Record<string, unknown>;

    if (Array.isArray(schema.required)) {
      for (const key of schema.required) {
        if (typeof key === "string" && !(key in obj)) {
          return { ok: false, error: `${path}: missing required field '${key}'` };
        }
      }
    }

    if (schema.properties !== null && typeof schema.properties === "object" && !Array.isArray(schema.properties)) {
      for (const [key, subschema] of Object.entries(schema.properties as Record<string, unknown>)) {
        // Only validate properties actually present on `obj` -- absence of
        // a non-required property isn't a validation failure, and absence
        // of a required one was already caught above.
        if (key in obj && subschema !== null && typeof subschema === "object") {
          const nested = validateAgainstSchema(subschema as JsonSchema, obj[key], `${path}.${key}`, depth + 1);
          if (!nested.ok) {
            return nested;
          }
        }
      }
    }
  } else if (type === "array") {
    if (!Array.isArray(value)) {
      return { ok: false, error: `${path}: expected an array, got ${describeType(value)}` };
    }
    if (schema.items !== null && typeof schema.items === "object" && !Array.isArray(schema.items)) {
      for (let i = 0; i < value.length; i++) {
        const nested = validateAgainstSchema(schema.items as JsonSchema, value[i], `${path}[${i}]`, depth + 1);
        if (!nested.ok) {
          return nested;
        }
      }
    }
  } else if (type === "string") {
    if (typeof value !== "string") {
      return { ok: false, error: `${path}: expected a string, got ${describeType(value)}` };
    }
  } else if (type === "number" || type === "integer") {
    if (typeof value !== "number" || Number.isNaN(value)) {
      return { ok: false, error: `${path}: expected a number, got ${describeType(value)}` };
    }
    if (type === "integer" && !Number.isInteger(value)) {
      return { ok: false, error: `${path}: expected an integer, got ${value}` };
    }
  } else if (type === "boolean") {
    if (typeof value !== "boolean") {
      return { ok: false, error: `${path}: expected a boolean, got ${describeType(value)}` };
    }
  }
  // else: unrecognized, unsupported, or absent (and not implying an object
  // per above) `type` -- nothing more this validator knows how to check
  // structurally; see the doc comment above.

  // `enum` is checked generically here, for whatever `type` (or lack of
  // one) preceded it, rather than only inside the `string` branch --
  // review finding: a numeric/boolean `enum` (e.g. `{ type: "number", enum:
  // [1, 2, 3] }`) must be enforced the same as a string one.
  if (Array.isArray(schema.enum) && !schema.enum.includes(value)) {
    return { ok: false, error: `${path}: ${JSON.stringify(value)} is not one of ${JSON.stringify(schema.enum)}` };
  }

  return { ok: true };
}

export type StructuredParseResult =
  | { ok: true; value: Record<string, unknown> }
  | { ok: false; error: string };

/**
 * Parses `text` (a model's raw response) as JSON and validates it against
 * `schema` via `validateAgainstSchema` -- this is the replacement for the
 * pre-claude-r30.5 `parseJsonObject`, which only checked "is it JSON, is it
 * an object" and never looked at the schema's actual shape at all. Returns
 * `ok: false` with a message describing exactly what was wrong (invalid
 * JSON, a specific missing/mistyped field) on either a parse failure or a
 * structural mismatch -- callers use this to decide whether to retry (see
 * `generateStructured` in `index.ts`).
 */
export function parseAndValidateJson(text: string, schema: JsonSchema): StructuredParseResult {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return { ok: false, error: `model did not return valid JSON: ${truncateForError(text)}` };
  }

  const structural = validateAgainstSchema(schema, value);
  if (!structural.ok) {
    return {
      ok: false,
      error: `model response did not match the expected schema (${structural.error}): ${truncateForError(text)}`,
    };
  }

  // Every tool that calls this (summarize_file, extract, classify) builds
  // its result from an object (`summary`/`data`/`label`), regardless of
  // what the root `type` in `schema` happens to declare -- so this is
  // enforced independently of `validateAgainstSchema`, same as the
  // pre-claude-r30.5 `parseJsonObject` this replaces.
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, error: `model returned JSON that is not an object: ${truncateForError(text)}` };
  }
  return { ok: true, value: value as Record<string, unknown> };
}

/** Caps an error-message excerpt of a (potentially large, malformed) model
 * response so a bad response can't itself blow up the result size. */
export function truncateForError(text: string): string {
  const limit = 200;
  return text.length > limit ? `${text.slice(0, limit)}...` : text;
}

/**
 * Unit tests for the pure schema-validation logic in `validate.ts` (bead
 * claude-r30.5). Uses Node's built-in test runner (`node:test`, available
 * since Node 18 -- this repo's floor is Node 20, see package.json's
 * `engines`) rather than adding a new devDependency (jest/vitest/etc.) for a
 * project this small. Run via `npm test` (compiles then `node --test dist`).
 *
 * These exercise `validateAgainstSchema`/`parseAndValidateJson` directly
 * against hand-constructed good/bad payloads -- they do not, and cannot in
 * this sandbox, exercise the live-Ollama retry path in `index.ts`'s
 * `generateStructured` (no reachable Ollama sidecar here; see this repo's
 * claude-r30.5 close notes for what was and wasn't verified).
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAndValidateJson, validateAgainstSchema } from "./validate.js";

const summarizeSchema = {
  type: "object",
  properties: { summary: { type: "string" } },
  required: ["summary"],
};

const classifySchema = {
  type: "object",
  properties: { label: { type: "string", enum: ["bug", "feature", "chore"] } },
  required: ["label"],
};

const extractSchema = {
  type: "object",
  properties: {
    title: { type: "string" },
    count: { type: "number" },
    tags: { type: "array", items: { type: "string" } },
    active: { type: "boolean" },
  },
  required: ["title", "count"],
};

test("validateAgainstSchema: accepts a well-formed flat object", () => {
  const result = validateAgainstSchema(summarizeSchema, { summary: "a short summary" });
  assert.deepEqual(result, { ok: true });
});

test("validateAgainstSchema: rejects a missing required field", () => {
  const result = validateAgainstSchema(summarizeSchema, {});
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /missing required field 'summary'/);
  }
});

test("validateAgainstSchema: rejects a wrong-typed field", () => {
  const result = validateAgainstSchema(summarizeSchema, { summary: 42 });
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /expected a string, got number/);
  }
});

test("validateAgainstSchema: rejects a non-object when type is object", () => {
  const result = validateAgainstSchema(summarizeSchema, "not an object");
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /expected an object, got string/);
  }
});

test("validateAgainstSchema: rejects an array when type is object (JSON.parse'd array)", () => {
  const result = validateAgainstSchema(summarizeSchema, ["oops"]);
  assert.equal(result.ok, false);
});

test("validateAgainstSchema: enum accepts a listed label", () => {
  const result = validateAgainstSchema(classifySchema, { label: "bug" });
  assert.deepEqual(result, { ok: true });
});

test("validateAgainstSchema: enum rejects a label outside the list", () => {
  const result = validateAgainstSchema(classifySchema, { label: "not-a-real-label" });
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /is not one of/);
  }
});

test("validateAgainstSchema: validates nested properties (string/number/array/boolean)", () => {
  const result = validateAgainstSchema(extractSchema, {
    title: "hello",
    count: 3,
    tags: ["a", "b"],
    active: true,
  });
  assert.deepEqual(result, { ok: true });
});

test("validateAgainstSchema: rejects a wrong-typed array item", () => {
  const result = validateAgainstSchema(extractSchema, {
    title: "hello",
    count: 3,
    tags: ["a", 2],
  });
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /\$\.tags\[1\]: expected a string, got number/);
  }
});

test("validateAgainstSchema: tolerates unsupported/absent schema.type by accepting", () => {
  const result = validateAgainstSchema({}, { anything: "goes" });
  assert.deepEqual(result, { ok: true });
});

test("validateAgainstSchema: treats a root schema with required/properties but no `type` as an object schema", () => {
  const implicitObjectSchema = {
    properties: { title: { type: "string" } },
    required: ["title"],
  };
  const missing = validateAgainstSchema(implicitObjectSchema, {});
  assert.equal(missing.ok, false);
  if (!missing.ok) {
    assert.match(missing.error, /missing required field 'title'/);
  }

  const present = validateAgainstSchema(implicitObjectSchema, { title: "hello" });
  assert.deepEqual(present, { ok: true });

  const wrongType = validateAgainstSchema(implicitObjectSchema, { title: 5 });
  assert.equal(wrongType.ok, false);
});

test("validateAgainstSchema: enum is enforced for non-string types too", () => {
  const numericEnumSchema = { type: "number", enum: [1, 2, 3] };
  assert.deepEqual(validateAgainstSchema(numericEnumSchema, 2), { ok: true });

  const result = validateAgainstSchema(numericEnumSchema, 42);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /is not one of/);
  }
});

test("validateAgainstSchema: a schema nested past the depth cap returns ok:false, not a stack overflow", () => {
  // Build `{ type: "object", properties: { a: { type: "object", properties: { a: ... } } } }`
  // nested well past MAX_SCHEMA_DEPTH, with a matching deeply-nested value
  // (`{ a: { a: { a: ... } } }`) -- exercises the actual recursive path
  // rather than failing for some unrelated shape mismatch first.
  const depth = 100;
  let schema: Record<string, unknown> = { type: "string" };
  let value: unknown = "leaf";
  for (let i = 0; i < depth; i++) {
    schema = { type: "object", properties: { a: schema }, required: ["a"] };
    value = { a: value };
  }

  const result = validateAgainstSchema(schema, value);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /nested too deeply/);
  }
});

test("parseAndValidateJson: accepts valid JSON matching the schema", () => {
  const result = parseAndValidateJson('{"summary": "ok"}', summarizeSchema);
  assert.deepEqual(result, { ok: true, value: { summary: "ok" } });
});

test("parseAndValidateJson: rejects non-JSON text", () => {
  const result = parseAndValidateJson("not json at all", summarizeSchema);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /did not return valid JSON/);
  }
});

test("parseAndValidateJson: rejects JSON that parses but fails schema validation", () => {
  const result = parseAndValidateJson('{"summary": 123}', summarizeSchema);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.match(result.error, /did not match the expected schema/);
  }
});

test("parseAndValidateJson: rejects a top-level JSON array even if schema.type is object", () => {
  const result = parseAndValidateJson("[1, 2, 3]", summarizeSchema);
  assert.equal(result.ok, false);
});

test("parseAndValidateJson: rejects a bare JSON scalar", () => {
  const result = parseAndValidateJson("42", summarizeSchema);
  assert.equal(result.ok, false);
});

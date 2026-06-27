---
paths:
  - "**/*.{ts,mts,cts,tsx}"
---

# Global Claude Instructions

## TypeScript Code Quality Rules

When writing, reviewing, or modifying TypeScript code, enforce the following rules derived from the [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html). Point out violations and suggest corrections.

---

### Source Files

- **Encoding & whitespace**: UTF-8; the only non-string whitespace is the ASCII space. Escape any other whitespace in strings.
- **Escapes**: Use named escape sequences, not numeric ones; use real Unicode characters, with a hex/Unicode escape plus a comment for non-printable ones.
- **File structure order**: license/copyright → `@fileoverview` JSDoc → imports → implementation, with exactly one blank line between sections.

---

### Imports & Exports

- **Import forms**: `import {X} from '...'` for named imports; `import * as foo from '...'` when pulling many symbols from a large API; default import only when external code requires it; `import '...'` only for side effects.
- **Paths**: Use module paths (prefer relative `./foo`); limit `../` traversal depth.
- **Named exports only**: No default exports. Never `export let` (no mutable exports). Minimize the exported surface; don't create container classes just for namespacing.
- **Type-only**: Use `import type` / `export type` for types you only reference in type position.
- **ES modules only**: No `namespace Foo {}`, no `/// <reference>` directives, no `import x = require(...)`.

---

### Variables

- **`const`/`let`, never `var`**: Default to `const`; use `let` only when reassigned. One variable per declaration; never use before declaration.

---

### Types & the Type System

- **Lean on inference**: Omit annotations for trivially inferred types (literals, `new` expressions). Annotate empty collections (`const x: Foo[] = []`, `new Map<K, V>()`). Add annotations where they aid readability of complex expressions.
- **Return types**: Optional — author's call; reviewers or project policy may require them for clarity.
- **`null` vs `undefined`**: Either is acceptable per context. Prefer optional `?` over `|undefined`. Don't bake `|null`/`|undefined` into a type alias — add nullability at the use site.
- **Interfaces vs aliases**: Prefer `interface` for object types; use `type` aliases for unions, tuples, and primitives.
- **Array types**: `T[]` / `readonly T[]` for simple element types; `Array<T>` for complex ones; apply the rule at each nesting level.
- **Index signatures**: Prefer `Record<Keys, V>` or ES `Map`/`Set`; give the key a meaningful label.
- **No `any`**: Use `unknown` (and narrow before dereferencing), a specific type, or a documented lint suppression. `any` only in tests (with `@ts-ignore` and a reason).
- **`{}` discouraged**: Prefer `unknown` for opaque values, `object` for non-primitives, `Record<…>` for dictionaries.
- **Tuples** over Pair-like interfaces.
- **Avoid return-type-only generics**; when consuming such an API, specify the generic explicitly.

---

### Classes

- **Semicolons**: No semicolon after a class declaration; class *expressions* end with `;`; no semicolons between methods.
- **Constructors**: Omit empty ones; keep a constructor that has parameter properties, visibility modifiers, or decorators. Constructor calls always use parentheses.
- **No `#private`**: Use TypeScript's `private`. Never bypass visibility via `obj['field']`.
- **`readonly` & parameter properties**: Mark never-reassigned properties `readonly`; prefer parameter properties; initialize fields at their declaration where possible.
- **Visibility**: Limit it as much as possible. Members are `public` by default — don't write `public` (except on non-`readonly` parameter properties). Members used outside the class's lexical scope must be `protected`/`public`, not `private`.
- **Accessors**: Getters must be pure (no observable side effects); don't define accessors via `Object.defineProperty`. Computed property names only for Symbols.
- **Statics**: Prefer module-local functions to private static methods; never use `this` in a static context; don't rely on dynamic dispatch of statics.
- **No prototype manipulation** (except framework code).

---

### Functions

- **Declarations vs expressions**: Prefer function declarations for named functions. Don't use function expressions — use arrow functions (exception: dynamic `this` rebinding or generators).
- **Arrow bodies**: Concise body only when the return value is used; otherwise a block body (use the `void` operator to discard a value).
- **Prefer arrows** over `f.bind(this)` / `const self = this`; prefer arrow callbacks to avoid unintentionally forwarded arguments.
- **Parameters**: Default initializers stay simple and side-effect-free; destructure when there are many optional params. Use rest params instead of `arguments` (and never name anything `arguments`); prefer spread over `apply`.

---

### Control Flow

- **Braces**: All control-flow statements use braced blocks (a single-line `if` may elide them). Avoid assignments inside conditions; parenthesize if genuinely intended.
- **Iteration**: `for...of` for arrays; never an unfiltered `for...in` (filter with `hasOwnProperty`, or use `Object.keys/values/entries`).
- **Equality**: `===` / `!==` only — except `== null` to cover both `null` and `undefined`.
- **Switch**: A `default` group is required, placed last (even if empty); every non-empty group ends with `break`/`return`/`throw` — no fall-through from non-empty groups.
- **Exceptions**: `throw new Error(...)` (or a subclass), never a bare value; treat caught values as `Error`; an empty `catch` needs an explanatory comment; keep `try` blocks to only the code that can throw.
- **No redundant parentheses** after `delete`, `typeof`, `void`, `return`, `throw`, `case`, `in`, `of`, `yield`.

---

### Type Assertions & Coercion

- **Assertions**: Avoid `as Type` and the non-null `!`; prefer runtime checks (`instanceof`, truthiness). When you must assert, add a comment explaining why it's safe, use `as` (not angle brackets), and do double assertions only as `x as unknown as T`.
- **Coercion**: `String()`, `Boolean()`, `!!` are fine. Parse numbers with `Number()` and check for `NaN`; don't use unary `+`, and avoid `parseInt`/`parseFloat` except for non-base-10. Don't combine implicit and explicit coercion; compare enum values explicitly rather than coercing them.

---

### Decorators

- **Framework decorators only**: Don't author new decorators — use those provided by your framework. A decorator immediately precedes the decorated symbol, with no blank line between.

---

### Disallowed

- **No wrapper types** `String`/`Boolean`/`Number` (use `string`/`boolean`/`number`); never call them as constructors.
- **No reliance on ASI** — terminate every statement.
- **No `const enum`** (use a plain `enum`); **no `debugger`** in production; **no `with`**; **no `eval` / `Function(string)`**.
- **No non-standard or unfinalized** ECMAScript features; **never modify builtins** or their prototypes.

---

### Naming

- **General**: ASCII, descriptive, no type info encoded in the name; short names only in scopes ≤10 lines.
- **`UpperCamelCase`**: classes, interfaces, types, enums, decorators, type parameters, component functions.
- **`lowerCamelCase`**: variables, parameters, functions, methods, properties, module aliases.
- **`CONSTANT_CASE`**: module-level constants and enum values (not locals or nested static fields).
- **No `_` prefix or suffix** (the only exception is `_` separators in xUnit-style test method names). Treat abbreviations as whole words (`loadHttpUrl`). Avoid `$` except the `Observable` convention or third-party requirements.

---

### Comments & Documentation

- **JSDoc vs line comments**: Use `/** … */` for user-facing documentation (document all top-level exports); use `//` for implementation notes.
- **Multi-line comments**: Stack `//` lines rather than `/* */`; no boxes of asterisks.
- **JSDoc content**: Written in Markdown, each tag on its own line. Don't restate types that the TypeScript annotations already encode (no `@param`/`@return` *types* in JSDoc — TS already has them).

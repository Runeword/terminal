---
paths:
  - "**/*.{js,mjs,cjs,jsx}"
---

# Global Claude Instructions

## JavaScript Code Quality Rules

When writing, reviewing, or modifying JavaScript code, enforce the following rules derived from the [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html). Point out violations and suggest corrections. (Google no longer updates this guide and recommends new code be written in TypeScript — see `typescript.md`.)

---

### Source Files

- **File names**: All lowercase, `.js` extension; underscores or dashes only as separators.
- **Encoding & whitespace**: UTF-8. Outside string literals, the only whitespace is the ASCII space (0x20) — never tabs for indentation.
- **Escapes**: Use named escape sequences (`\n`, `\t`, `\'`, …), never legacy octal escapes. For non-ASCII, use the actual Unicode character or a hex/Unicode escape, whichever reads better.
- **File structure order**: license/copyright → `@fileoverview` JSDoc → imports (`goog.module`/`goog.require` or ES `import`) → implementation, with exactly one blank line between sections.

---

### Modules & Imports

- **ES modules**: Use `import`/`export`. Include the `.js` extension in import paths, keep `import` statements on one line (no wrapping), and never create circular dependencies.
- **Named imports**: Keep the original exported name; alias only to disambiguate or to avoid masking a native type.
- **No default exports**: Export named symbols (or assign to the `exports` object); don't annotate exports with `@const`.
- **Closure (`goog.module`)**: One `goog.module` per file on a single line. `goog.require`/`goog.requireType` form one contiguous block, sorted alphabetically, each bound to an alias matching the final namespace component.

---

### Formatting

- **Braces always**: All control structures use braces, even single statements. K&R ("Egyptian") brace style; empty blocks may be `{}`.
- **Indentation**: +2 spaces per block level; never tabs.
- **Semicolons**: One statement per line, every statement terminated with a semicolon — relying on automatic semicolon insertion is forbidden.
- **Column limit**: 80 characters (exceptions: `goog.module`/`goog.require`, ES `import`/`export`, URLs, long string literals).
- **Line wrapping**: Break at the highest syntactic level; operators go at the start of the continuation; indent continuations +4. Never break between `return` and its value.
- **Trailing commas**: Include a trailing comma whenever the closing bracket is on its own line.
- **Vertical whitespace**: One blank line between methods; no blank line at the start or end of a block.
- **Mechanical formatting** (spacing, alignment) is enforced by `clang-format` — don't hand-align tokens.

---

### Variables

- **`const`/`let`, never `var`**: Default to `const`; use `let` only when the binding is reassigned.
- **One per declaration**: No `let a = 1, b = 2;`. Declare close to first use and initialize immediately.

---

### Language Features

- **Arrays**: Use literals, never `new Array()`. No non-numeric properties (use `Map`/`Object`). Prefer spread over `Array.prototype` methods; destructuring (incl. trailing rest) is allowed.
- **Objects**: Use literals, never `new Object()`. Don't mix quoted and unquoted keys in one literal. Method and property shorthand are fine; computed keys allowed (symbols are dict-style).
- **Classes**: Define all fields in the constructor; subclasses call `super()` before accessing `this`. Mark never-reassigned fields `@const`; set visibility with `@private`/`@protected`/`@package`. No getters/setters (except data-binding frameworks), no prototype manipulation, no static "namespace" container classes, no nested namespaces.
- **Functions**: Prefer arrow functions for nested functions and callbacks. Optional parameters come after required ones, must have defaults, and must be side-effect-free. Rest parameters are last, written `...name` with no space. Prefer spread over `Function.prototype.apply`.
- **Strings**: Single quotes only — double quotes are forbidden. Use template literals for concatenation or multi-line strings; no backslash line continuations.
- **Numbers**: Lowercase `0x`/`0o`/`0b` prefixes; no leading-zero octal.
- **Control structures**: Prefer `for`-`of`; use `for`-`in` only on dict-style objects and filter with `hasOwnProperty`. A `switch` needs a `default` (last), each group ends with `break`/`return`/`throw`, and intentional fall-through is marked with a comment.
- **Exceptions**: Always `throw new Error(...)` (or a subclass); justify any empty `catch` with a comment.
- **Equality**: Use `===`/`!==` — except `== null` to test for both `null` and `undefined`.
- **`this`**: Only in class constructors/methods, arrow functions nested in them, or functions with an explicit `@this`. Never use it to refer to the global object.

---

### Disallowed

- **No `with`.**
- **No `eval` / `Function(string)`** (except dedicated code loaders).
- **No primitive wrapper objects**: never `new Boolean/Number/String/Symbol` (calling them as plain functions for coercion is fine).
- **Never modify builtins** or their prototypes.
- **Always invoke constructors with parentheses**: `new Foo()`, not `new Foo`.

---

### Naming

- **General**: ASCII, descriptive; don't abbreviate by deleting letters. Single-letter names only in scopes ≤10 lines.
- **Classes / interfaces / records / typedefs**: `UpperCamelCase`.
- **Methods / fields / parameters / locals**: `lowerCamelCase`; private members may take a trailing underscore.
- **Constants** (deeply-immutable `@const` statics or module-local `const`): `CONSTANT_CASE`.
- **Enums**: `UpperCamelCase` type name, `CONSTANT_CASE` members.
- **Abbreviations**: treat as words when casing (`loadHttpUrl`, not `loadHTTPURL`).

---

### JSDoc

- **Form**: `/** … */` blocks written in Markdown.
- **Methods/functions**: Document `@param` and `@return` types; add `@override` when overriding.
- **Classes**: Use a class comment; don't use `@constructor`/`@extends` together with the `class` keyword.
- **Type annotations**: Always in braces. Reference types are nullable-by-default — mark `!` (non-null) or `?` (nullable) explicitly; primitives are non-nullable by default. Use `@enum`/`@typedef` for enums and typedefs.
- **Properties**: A type annotation is required.

- Never delete comments describing unobvious logic when refactoring. Move or update them to match the new code, but preserve their intent.

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.
- Finish every plan by running tests.

## ReScript

- When using `Utils.magic` for type casting, always add explicit type annotations: `value->(Utils.magic: inputType => outputType)`
- `end` is a reserved keyword. Use `~end_` for labeled arguments (e.g., `Js.Array2.slice(~start=0, ~end_=n)`).

pub const DEFAULT_CONFIRMED_BLOCK_THRESHOLD: i32 = 200;

pub mod project_paths {
    pub const DEFAULT_PROJECT_ROOT_PATH: &str = ".";
    /// Project-root-relative directory holding ephemeral codegen output
    /// (`types.d.ts`, build artifacts, cache). The user-facing
    /// `envio-env.d.ts` glue file lives at the project root, not here.
    pub const ENVIO_DIR: &str = ".envio";
    /// User-facing TypeScript glue file generated at the project root.
    /// References `<project>/.envio/types.d.ts` so the augmented `envio`
    /// module surface is visible to user code without a "generated" package.
    pub const ENVIO_ENV_DTS_FILE: &str = "envio-env.d.ts";
    /// Codegen-emitted module-augmentation file under `.envio/`. Always
    /// regenerated; git-ignored via `.envio/.gitignore`.
    pub const ENVIO_TYPES_FILE: &str = "types.d.ts";
    pub const DEFAULT_CONFIG_PATH: &str = "config.yaml";
    pub const DEFAULT_SCHEMA_PATH: &str = "schema.graphql";
}

pub mod links {
    pub const DOC_CONFIGURATION_FILE: &str = "https://docs.envio.dev/docs/configuration-file";
    pub const DOC_CONFIGURATION_SCHEMA_HYPERSYNC_CONFIG: &str =
        "https://docs.envio.dev/docs/HyperIndex/config-schema-reference#hypersyncconfig";
}

pub mod reserved_keywords {
    pub const JAVASCRIPT_RESERVED_WORDS: &[&str] = &[
        "abstract",
        "arguments",
        "await",
        "boolean",
        "break",
        "byte",
        "case",
        "catch",
        "char",
        "class",
        "const",
        "continue",
        "debugger",
        "default",
        "delete",
        "do",
        "double",
        "else",
        "enum",
        "eval",
        "export",
        "extends",
        "false",
        "final",
        "finally",
        "float",
        "for",
        "function",
        "goto",
        "if",
        "implements",
        "import",
        "in",
        "instanceof",
        "int",
        "interface",
        "let",
        "long",
        "native",
        "new",
        "null",
        "package",
        "private",
        "protected",
        "public",
        "return",
        "short",
        "static",
        "super",
        "switch",
        "synchronized",
        "this",
        "throw",
        "throws",
        "transient",
        "true",
        "try",
        "typeof",
        "var",
        "void",
        "volatile",
        "while",
        "with",
        "yield",
    ];

    pub const TYPESCRIPT_RESERVED_WORDS: &[&str] = &[
        "any",
        "as",
        "boolean",
        "break",
        "case",
        "catch",
        "class",
        "const",
        "constructor",
        "continue",
        "declare",
        "default",
        "delete",
        "do",
        "else",
        "enum",
        "export",
        "extends",
        "false",
        "finally",
        "for",
        "from",
        "function",
        "get",
        "if",
        "implements",
        "import",
        "in",
        "instanceof",
        "interface",
        "let",
        "module",
        "new",
        "null",
        "number",
        "of",
        "package",
        "private",
        "protected",
        "public",
        "require",
        "return",
        "set",
        "static",
        "string",
        "super",
        "switch",
        "symbol",
        "this",
        "throw",
        "true",
        "try",
        "type",
        "typeof",
        "var",
        "void",
        "while",
        "with",
        "yield",
    ];

    pub const RESCRIPT_RESERVED_WORDS: &[&str] = &[
        "and",
        "as",
        "assert",
        "constraint",
        "else",
        "exception",
        "external",
        "false",
        "for",
        "if",
        "in",
        "include",
        "lazy",
        "let",
        "module",
        "mutable",
        "of",
        "open",
        "rec",
        "switch",
        "true",
        "try",
        "type",
        "when",
        "while",
        "with",
    ];

    pub const ENVIO_INTERNAL_RESERVED_POSTGRES_TYPES: &[&str] = &[];
}

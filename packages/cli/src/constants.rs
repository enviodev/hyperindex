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

    /// Names a config or schema may not use. Every other identifier codegen
    /// emits is capitalized first, which is why a keyword of the generated
    /// languages is not on this list — only names that stay broken after that.
    pub const RESERVED_NAMES: &[&str] = &[
        // Generated code indexes plain objects by these names, and an object
        // answers a prototype key from its prototype rather than from what was
        // stored — so the lookup resolves to a bogus value instead of the one
        // assigned to it. `constructor` is neutralized wherever a name is
        // capitalized; `__proto__` starts with an underscore and survives
        // capitalization untouched, which also makes it an illegal ReScript
        // module name and variant constructor.
        "__proto__",
        "constructor",
        // Every entity is re-exported from the `envio` module under its
        // capitalized name, where `Enum` is already taken.
        "enum",
    ];
}

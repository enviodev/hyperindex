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
        // Every own property of `Object.prototype`. Generated code indexes
        // plain objects by these names, and an object answers a prototype key
        // from its prototype rather than from what was stored, so the lookup
        // resolves to a bogus value instead of the one assigned to it — an
        // entity named `toString` reaches the test indexer's per-entity change
        // bucket as `Object.prototype.toString` and the write throws on its
        // missing `sets` array. The whole family, not the subset that happens
        // to read like a keyword: the failure is the prototype lookup, not the
        // spelling. `__proto__` additionally survives capitalization untouched,
        // which makes it an illegal ReScript module name and variant
        // constructor on top of the lookup problem.
        "__defineGetter__",
        "__defineSetter__",
        "__lookupGetter__",
        "__lookupSetter__",
        "__proto__",
        "constructor",
        "hasOwnProperty",
        "isPrototypeOf",
        "propertyIsEnumerable",
        "toLocaleString",
        "toString",
        "valueOf",
    ];

    /// The capitalized names `packages/envio/index.d.ts` exports. An entity
    /// alias is declared inside `declare module "envio"`, where a second
    /// `export type Hex` is a duplicate identifier rather than a merge, so an
    /// entity named like one of these gets no alias. A codegen test keeps the
    /// list in sync with the file.
    pub const ENVIO_TYPE_EXPORTS: &[&str] = &[
        "Address",
        "BigDecimal",
        "Effect",
        "EffectArgs",
        "EffectCaller",
        "EffectChain",
        "EffectContext",
        "EffectOptions",
        "Entity",
        "EntityName",
        "Enum",
        "EnumName",
        "EvmAllBlockFields",
        "EvmAllTransactionFields",
        "EvmBlockFieldName",
        "EvmChainId",
        "EvmChainName",
        "EvmContractName",
        "EvmContractRegisterContext",
        "EvmContractRegisterHandler",
        "EvmContractRegisterOptions",
        "EvmEvent",
        "EvmEventWithFields",
        "EvmFieldsMustBeLiteral",
        "EvmFieldsSelection",
        "EvmOnBlockContext",
        "EvmOnBlockFilter",
        "EvmOnBlockHandler",
        "EvmOnBlockHandlerArgs",
        "EvmOnBlockOptions",
        "EvmOnBlockWhereArgs",
        "EvmOnBlockWhereResult",
        "EvmOnEvent",
        "EvmOnEventContext",
        "EvmOnEventHandler",
        "EvmOnEventOptions",
        "EvmOnEventWhere",
        "EvmOnEventWhereArgs",
        "EvmOnEventWhereChain",
        "EvmOnEventWhereFilter",
        "EvmTransactionFieldName",
        "FieldNotSelected",
        "FuelChainId",
        "FuelChainName",
        "FuelContractName",
        "FuelContractRegisterContext",
        "FuelContractRegisterHandler",
        "FuelContractRegisterOptions",
        "FuelEvent",
        "FuelOnBlockContext",
        "FuelOnBlockFilter",
        "FuelOnBlockHandler",
        "FuelOnBlockHandlerArgs",
        "FuelOnBlockOptions",
        "FuelOnBlockWhereArgs",
        "FuelOnBlockWhereResult",
        "FuelOnEvent",
        "FuelOnEventContext",
        "FuelOnEventHandler",
        "FuelOnEventOptions",
        "FuelOnEventWhere",
        "FuelOnEventWhereArgs",
        "FuelOnEventWhereChain",
        "FuelOnEventWhereFilter",
        "GetWhereFilter",
        "GetWhereOperator",
        "Global",
        "Hex",
        "Indexer",
        "IndexerFromConfig",
        "JSON",
        "Logger",
        "Prettify",
        "RateLimit",
        "RateLimitDuration",
        "S",
        "SingleOrMultiple",
        "StrictHex",
        "SvmAccountActivity",
        "SvmAccountActivityFieldName",
        "SvmAccountLamports",
        "SvmAccountTokenActivity",
        "SvmAccountsFilter",
        "SvmAllAccountActivityFields",
        "SvmAllAccountLamportsFields",
        "SvmAllAccountTokenActivityFields",
        "SvmAllBlockFields",
        "SvmAllFieldsSelection",
        "SvmAllLogFields",
        "SvmAllTransactionFields",
        "SvmBlock",
        "SvmBlockFieldName",
        "SvmChainId",
        "SvmChainName",
        "SvmFieldsSelection",
        "SvmInstruction",
        "SvmInstructionAccount",
        "SvmInstructionFieldName",
        "SvmLog",
        "SvmLogFieldName",
        "SvmLogKind",
        "SvmOnInstructionHandler",
        "SvmOnInstructionHandlerArgs",
        "SvmOnInstructionOptions",
        "SvmOnInstructionWhere",
        "SvmOnSlotContext",
        "SvmOnSlotFilter",
        "SvmOnSlotHandler",
        "SvmOnSlotHandlerArgs",
        "SvmOnSlotOptions",
        "SvmOnSlotWhereArgs",
        "SvmOnSlotWhereResult",
        "SvmTransaction",
        "SvmTransactionFieldName",
        "TestHelpers",
        "TestIndexer",
        "TestIndexerFromConfig",
        "TestIndexerProcessConfig",
    ];
}

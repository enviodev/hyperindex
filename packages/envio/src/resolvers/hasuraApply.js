// Puts the resolver metadata into Hasura, and keeps it there.
//
// Applying is a read then, only if something differs, one write. The write
// reloads Hasura's schema cache, so a re-assert that fired every minute
// regardless would disrupt a busy Hasura sixty times an hour to change nothing.
//
// Re-asserting at all is not defensive. `Hasura.trackDatabase` opens with a
// wholesale `clear_metadata`, so any re-initialised indexer silently deletes
// these actions while this service keeps running and Hasura keeps answering
// that the field does not exist.

// Hasura's own defaults, applied when reading its metadata back: `export_metadata`
// omits whatever matches them, so a comparison against what we sent has to put
// them back or every read reports drift.
const DEFAULT_TIMEOUT_SECONDS = 30;

const byName = (a, b) => a.name.localeCompare(b.name);

function normaliseAction(action) {
  const definition = action.definition ?? {};
  return {
    comment: action.comment ?? null,
    // Absent means mutation, which is never what a resolver wants -- so an
    // action missing it is drift, not a match.
    type: definition.type ?? "mutation",
    kind: definition.kind ?? "synchronous",
    handler: definition.handler ?? null,
    output_type: definition.output_type ?? null,
    timeout: definition.timeout ?? DEFAULT_TIMEOUT_SECONDS,
    arguments: (definition.arguments ?? []).map((argument) => ({
      name: argument.name,
      type: argument.type,
    })),
  };
}

const normaliseFields = (types = []) =>
  types
    .map((type) => ({
      name: type.name,
      fields: (type.fields ?? []).map((field) => ({ name: field.name, type: field.type })),
    }))
    .sort(byName);

function normaliseCustomTypes(customTypes = {}) {
  return {
    scalars: (customTypes.scalars ?? []).map(({ name }) => ({ name })).sort(byName),
    enums: (customTypes.enums ?? [])
      .map((type) => ({
        name: type.name,
        // Hasura hands enum values back with a null description and
        // is_deprecated it was never given.
        values: (type.values ?? []).map(({ value }) => value),
      }))
      .sort(byName),
    input_objects: normaliseFields(customTypes.input_objects),
    objects: normaliseFields(customTypes.objects),
  };
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const actionArgs = (action) => ({
  name: action.name,
  ...(action.comment === undefined ? {} : { comment: action.comment }),
  definition: action.definition,
});

/**
 * The single metadata call that moves Hasura from `exported` to `metadata`,
 * and the reasons it is needed. `bulk` is null when nothing differs.
 */
export function planApply(metadata, exported) {
  const current = new Map((exported?.actions ?? []).map((action) => [action.name, action]));
  const desired = new Map(metadata.actions.map((action) => [action.name, action]));
  const desiredRoles = new Map(metadata.actions.map((action) => [action.name, new Set()]));
  for (const permission of metadata.permissions) {
    desiredRoles.get(permission.action)?.add(permission.role);
  }

  const reasons = [];
  const drops = [];
  const writes = [];
  const permissionDrops = [];
  const permissionCreates = [];

  for (const [name, action] of current) {
    if (!desired.has(name)) {
      // Left in place, Hasura keeps publishing a field whose handler no longer
      // knows the name -- every call to it fails at the resolver instead of
      // being absent from the schema. This service is the only thing that
      // creates actions on an indexer's Hasura, so an action it does not
      // declare is one it removed.
      reasons.push(`action '${name}' is no longer declared`);
      drops.push({ type: "drop_action", args: { name } });
    }
  }

  for (const [name, action] of desired) {
    const existing = current.get(name);
    if (existing === undefined) {
      reasons.push(`action '${name}' is missing`);
      writes.push({ type: "create_action", args: actionArgs(action) });
    } else if (!same(normaliseAction(existing), normaliseAction(action))) {
      reasons.push(`action '${name}' differs`);
      writes.push({ type: "update_action", args: actionArgs(action) });
    }

    const wanted = desiredRoles.get(name) ?? new Set();
    const held = new Set((existing?.permissions ?? []).map((permission) => permission.role));
    for (const role of held) {
      if (!wanted.has(role)) {
        reasons.push(`action '${name}' should not be readable by '${role}'`);
        // Asymmetric with create_action_permission, which calls it `action`.
        permissionDrops.push({ type: "drop_action_permission", args: { name, role } });
      }
    }
    for (const role of wanted) {
      if (!held.has(role)) {
        reasons.push(`action '${name}' is not readable by '${role}'`);
        permissionCreates.push({
          type: "create_action_permission",
          args: { action: name, role },
        });
      }
    }
  }

  const desiredTypes = metadata.customTypes;
  const currentTypes = exported?.custom_types ?? {};
  const typesDiffer = !same(
    normaliseCustomTypes(currentTypes),
    normaliseCustomTypes(desiredTypes)
  );
  if (typesDiffer) {
    reasons.push("custom types differ");
  }

  if (reasons.length === 0) {
    return { bulk: null, reasons };
  }

  // `set_custom_types` replaces the whole block and is validated the moment it
  // runs, not at the end of the bulk. A type being added has to exist before
  // the action that names it, and a type being removed has to outlive the
  // action that named it -- opposite orders. The union satisfies both: it is
  // asserted first, so it adds everything new while keeping everything old,
  // and the desired set follows the actions only when something is dropped.
  const union = unionCustomTypes(currentTypes, desiredTypes);
  const args = [];
  if (typesDiffer) {
    args.push({ type: "set_custom_types", args: union });
  }
  args.push(...drops, ...writes, ...permissionDrops, ...permissionCreates);
  if (typesDiffer && !same(normaliseCustomTypes(union), normaliseCustomTypes(desiredTypes))) {
    args.push({ type: "set_custom_types", args: desiredTypes });
  }

  return { bulk: { type: "bulk", args }, reasons };
}

function unionCustomTypes(current, desired) {
  const merge = (key) => {
    const wanted = desired[key] ?? [];
    const names = new Set(wanted.map((type) => type.name));
    const kept = (current[key] ?? []).filter((type) => !names.has(type.name));
    return [...wanted, ...kept];
  };
  return {
    scalars: merge("scalars"),
    enums: merge("enums"),
    input_objects: merge("input_objects"),
    objects: merge("objects"),
  };
}

async function metadataCall({ endpoint, adminSecret, role = "admin" }, body) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-hasura-role": role,
      "x-hasura-admin-secret": adminSecret,
    },
    body: JSON.stringify(body),
  });
  const answer = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(
      `Hasura metadata call '${body.type}' failed with ${response.status}: ${JSON.stringify(answer)}`
    );
  }
  return answer;
}

/**
 * Brings Hasura's metadata in line with the manifest.
 *
 * Idempotent by construction: what to write is decided from what Hasura reports
 * it already has, so applying twice makes one call the second time and changes
 * nothing.
 */
export async function applyResolverMetadata({ endpoint, adminSecret, role, metadata }) {
  const connection = { endpoint, adminSecret, role };
  const exported = await metadataCall(connection, { type: "export_metadata", args: {} });
  const { bulk, reasons } = planApply(metadata, exported);
  if (bulk === null) {
    return { applied: false, reasons };
  }
  await metadataCall(connection, bulk);
  return { applied: true, reasons };
}

/**
 * Re-asserts the metadata on an interval, returning a function that stops it.
 *
 * `intervalMs: 0` disables it, for a deployment where something else owns the
 * metadata.
 */
export function startMetadataReassert({
  endpoint,
  adminSecret,
  role,
  metadata,
  intervalMs,
  onApplied,
  onError,
}) {
  if (!intervalMs || intervalMs <= 0) {
    return () => {};
  }
  let running = false;
  const timer = setInterval(async () => {
    // A slow Hasura must not stack up overlapping applies.
    if (running) return;
    running = true;
    try {
      const { applied, reasons } = await applyResolverMetadata({
        endpoint,
        adminSecret,
        role,
        metadata,
      });
      if (applied) onApplied?.(reasons);
    } catch (error) {
      onError?.(error);
    } finally {
      running = false;
    }
  }, intervalMs);
  // The loop must never be the reason the process stays alive.
  timer.unref?.();
  return () => clearInterval(timer);
}

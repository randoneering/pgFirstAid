# Agent remediation prompts

Every CRITICAL, HIGH, MEDIUM, and LOW finding includes a copyable `agent_prompt`.
Each prompt names the affected objects and includes observed values and check-specific guidance.
INFO rows keep a `NULL` prompt.
pgFirstAid generates text only; it never sends prompts or applies remediation.

## Upgrade an existing installation

**Run the latest matching SQL file again.**
The same file handles a new installation or an upgrade.
You do not need to drop the old function, run Python, or use a separate upgrader.

| Your installation | File to run |
|---|---|
| `pg_firstAid()` function | `pgFirstAid.sql` |
| Self-hosted `v_pgfirstaid` view | `view_pgFirstAid.sql` |
| Managed `v_pgfirstaid` view | `view_pgFirstAid_managed.sql` |

Use the same database and schema as the existing installation, as its owner or a database administrator.
Use a writable connection.
Each installer executes as one atomic SQL statement, including on transaction-pooled connections.

### SQL editor

Open the matching file and **execute the entire script**, with stop-on-error enabled.
Do not execute only the first statement or a selected function definition.

### psql

From the directory containing the SQL files, run **one** matching command:

```bash
# Function installation or upgrade
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f pgFirstAid.sql

# Self-hosted view installation or upgrade
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f view_pgFirstAid.sql

# Managed view installation or upgrade
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f view_pgFirstAid_managed.sql
```

Then run your usual query:

```sql
SELECT * FROM pg_firstAid();
-- Or, for either view installation:
SELECT * FROM v_pgfirstaid;
```

The results include the new `agent_prompt` column.
Function results have nine columns; view results have ten, including `severity_order`.
Update consumers that require a fixed column count.

### What the installer handles

- The known older eight-column function upgrades automatically, preserving ownership, EXECUTE grants/grantors/options, and comments.
- Compatible function and view updates retain their identities and dependent objects.
- Incompatible view layouts rebuild atomically while preserving supported permissions, comments, and security options.
- Existing function callers receive needed access to shared report helpers without widening access beyond the old caller policy.
- Each file applies its database changes in one statement; a failure rolls them back rather than leaving a partial installation.

### If the installer stops

- **Dependent objects:** an incompatible replacement uses `RESTRICT` and refuses to remove dependents.
  Have an administrator plan their migration; never force it with `CASCADE`.
- **Overlapping overloads:** defaulted or variadic routines that overlap a published call must be reconciled before upgrading.
  The installer leaves those routines untouched.
- **Custom definition or security settings:** unknown signatures and unsupported metadata require an administrator's review.
  The existing function or view remains in place.
- **Grantor permissions:** preserving delegated grants requires permission to assume their recorded grantor roles.
  Run as an appropriately authorized administrator.
- **Reserved temporary name:** reconnect with a fresh session and rerun the complete script.

Installation requires schema creation rights and database `TEMP` permission.
Readers do not need access to the temporary installation helpers.

### Permission denied for the prompt helper

View callers, or roles granted access after installation, may need an explicit helper grant when PUBLIC function execution is disabled.
Grant only to the actual authorized role; replace `monitoring_role` and the schema below as needed:

```sql
GRANT EXECUTE ON FUNCTION public.pgfirstaid_agent_prompt(
    text, text, text, text, text, text, text, text
) TO monitoring_role;
```

Keep existing permissions on the other pgFirstAid helper functions.
Do not grant PUBLIC execution just to suppress an error.

## Copy a prompt

```sql
SELECT severity, check_name, object_name, agent_prompt
FROM pg_firstAid()
WHERE severity <> 'INFO';
```

Use `FROM v_pgfirstaid` for either view installation.
Copy the complete `agent_prompt` cell using your SQL client's copy or expanded-output feature.
Each finding has its own prompt, including when one check flags several objects.

Prompts include database/user identities, object names, observed values, and documentation.
Index findings include their table, and duplicate-index findings identify both indexes.
Query/session prompts distinguish the report connection from the actual target database.
Evidence is JSON-encoded and treated as untrusted data, never commands to execute.

The guidance starts with read-only diagnosis and requires approval before changes.
Supported transactional changes need an approved `BEGIN`/`ROLLBACK` rehearsal in staging.
Nontransactional operations need a separate supported staging test and recovery plan.

Review prompts before sharing them externally.
Object names, session details, and captured SQL can contain sensitive information.
An agent can still make mistakes; review its evidence and proposed commands yourself.

## Edit shared SQL helpers

Contributors maintain prompt guidance in `data/agent_prompt.sql` and migration logic in `data/function_installer.sql` and `data/view_installer.sql`.
Generate the embedded copies instead of editing each installer:

```bash
uv run python tools/sync_sql_helpers.py
uv run python tools/sync_sql_helpers.py --check
```

PR Safe Checks rejects stale copies.
The function installer uses private staging names; the generator changes declarations only, keeping the maintained prompt body shared.
Users still run a single SQL file with no generator or external SQL dependency.

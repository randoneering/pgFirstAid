# Agent remediation prompts

Every CRITICAL, HIGH, MEDIUM, and LOW finding includes an `agent_prompt` column.
Copy one finding's prompt into your agent to investigate that specific issue.
INFO findings remain in the results with a `NULL` prompt.
pgFirstAid generates text only; it never sends prompts to an agent or applies changes.

## Copy a prompt

```sql
-- Function installation
SELECT severity, check_name, object_name, agent_prompt
FROM pg_firstAid()
WHERE severity <> 'INFO';

-- Either view installation
SELECT severity, check_name, object_name, agent_prompt
FROM v_pgfirstaid
WHERE severity <> 'INFO';
```

Use your SQL client's cell-copy or expanded-output feature to copy the complete `agent_prompt` value.
Each row has its own prompt, including when the same check flags several objects.
For a specific finding, filter by its `check_name` and `object_name`.

Each prompt includes:

- The current database, PostgreSQL version, severity, and check name.
- The actual affected objects and observed values, encoded as JSON strings to preserve quotes and newlines.
- Check-specific diagnosis and remediation guidance, plus documentation links.
- Read-only verification, staging tests, explicit approval before changes, finite timeouts, and recovery steps.

Index findings include the owning table.
Duplicate-index findings identify both indexes, and foreign-key findings identify the constraint and columns.
Session and query findings include the available PID or query ID and require the agent to recheck their identity before acting.
Prompts treat captured names, query text, and links as untrusted evidence, not instructions to execute.

Review the prompt before sharing it with an external agent.
Database names, object names, session information, and captured SQL can contain sensitive information.
The prompt does not grant access to your database or authorize changes.
An agent can still make mistakes; review its evidence and proposed commands yourself.

## Upgrade an existing installation

The new column is appended after the existing output columns.
Function results now have nine columns.
View results now have ten columns, retaining `severity_order` in its original position.
Update consumers that require a fixed column count or use positional inserts and `SELECT *`.

### Caller permissions

The installers respect your default function privileges and do not grant extra access automatically.
The new `pgfirstaid_agent_prompt(text, text, text, text, text, text, text, text)` helper runs with the caller's privileges.
Every authorized caller of the function or either view needs `EXECUTE` on this helper, in addition to their existing permissions.
When default privileges revoke PUBLIC function execution, restoring the main function's grants or retaining view SELECT access alone is insufficient.

Grant helper execution to each approved existing caller role before committing the upgrade.
Replace `monitoring_role` with an actual role from your access inventory, and replace `public` if needed:

```sql
GRANT EXECUTE ON FUNCTION public.pgfirstaid_agent_prompt(
    text, text, text, text, text, text, text, text
) TO monitoring_role;
```

Keep existing permissions on the other pgFirstAid helper functions.
Do not grant PUBLIC execution unless public access is intended.
Test access as each monitoring role with `SET ROLE`, then `RESET ROLE`, before committing.
If calls fail with `permission denied for function pgfirstaid_agent_prompt`, check this helper grant first.

### Views

Run your existing view installer again: `view_pgFirstAid.sql` or `view_pgFirstAid_managed.sql`.
Both use `CREATE OR REPLACE VIEW` to append the column while preserving the view's identity, owner, grants, and dependent objects.
An existing dependent view defined with `SELECT *` retains its original columns until you explicitly update its definition.
If your deployed view has a different column layout from the previous nine-column definition, replacement may fail.
Stop and inventory its definition, dependencies, ownership, and complete grants before planning an explicit recreation with `RESTRICT` in a transaction.
Do not use `CASCADE` or discard dependent objects to force the upgrade.

### Function

PostgreSQL cannot change a function's declared return columns with `CREATE OR REPLACE FUNCTION`.
On an older installation, rerunning `pgFirstAid.sql` alone therefore fails with `cannot change return type of existing function`.
Do not automatically drop the function or use `CASCADE`.
New installations do not need these upgrade steps.

1. Rehearse in a disposable copy of the database.
2. Save a schema-only dump and record the function's owner, complete grants including grant options, comments, and dependent definitions.
   Inspect dependencies with the query below.
3. Get approval for the exact upgrade and any dependent objects that need explicit recreation.
4. In one transaction with finite timeouts, recreate the function using `DROP FUNCTION ... RESTRICT` and the new installer.
   `RESTRICT` stops the upgrade if dependencies remain; a failed transaction leaves the old installation intact after rollback.
5. Restore the recorded owner and complete privileges before committing, including the original PUBLIC privileges rather than relying on defaults.
   Grant the new helper's EXECUTE privilege to approved callers as described above.
   Restore comments and other captured metadata, and explicitly recreate approved dependent objects with their original metadata.
6. Validate results, grants, and dependent consumers before committing.

```sql
SELECT pg_describe_object(classid, objid, objsubid) AS dependent_object,
       deptype
FROM pg_depend
WHERE refclassid = 'pg_proc'::regclass
  AND refobjid = 'public.pg_firstaid()'::regprocedure;

SELECT pg_get_userbyid(proowner) AS owner, proacl,
       obj_description(oid, 'pg_proc') AS comment
FROM pg_proc
WHERE oid = 'public.pg_firstaid()'::regprocedure;
```

Replace `public` if you installed pgFirstAid in a different schema.
The following **psql rehearsal** assumes the repository root is your working directory and the installation schema is `public`.
It rolls back deliberately.

```sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path TO public, pg_catalog;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '30s';
DROP FUNCTION public.pg_firstaid() RESTRICT;
\i pgFirstAid.sql
-- Restore captured ownership, privileges, comments, and approved dependencies here.
-- Grant the new prompt helper's EXECUTE privilege to each approved caller role.
SELECT severity, check_name, object_name, agent_prompt FROM public.pg_firstaid();
ROLLBACK;
```

Commit an approved upgrade only after replaying the recorded metadata and validating dependencies and access.
If the rehearsal fails, roll it back and resolve the specific dependency or permission issue before retrying.

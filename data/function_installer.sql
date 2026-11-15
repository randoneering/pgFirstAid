-- Apply all permanent definitions together, after validating the old installation.
CREATE OR REPLACE FUNCTION pg_temp._pgfirstaid_install_function_v2(target_schema text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function_install$
DECLARE
    stage_names text[] := ARRAY[
        '_pgfirstaid_stage2_statements', '_pgfirstaid_stage2_checkpoint',
        '_pgfirstaid_stage2_prompt', '_pgfirstaid_stage2_main'
    ];
    target_names text[] := ARRAY[
        'pgfirstaid_pg_stat_statements_checks', '_pg_firstaid_checkpoint_stats',
        'pgfirstaid_agent_prompt', 'pg_firstaid'
    ];
    expected_names text[] := ARRAY[
        'severity', 'category', 'check_name', 'object_name', 'issue_description',
        'current_value', 'recommended_action', 'documentation_link'
    ];
    stages oid[] := ARRAY[]::oid[];
    existing oid[] := ARRAY[]::oid[];
    staged record;
    previous record;
    old_main oid;
    old_owner oid;
    old_comment text;
    old_acl jsonb;
    actual_acl jsonb;
    pending jsonb;
    grant_item jsonb;
    authorized oid[];
    progressed boolean;
    legacy boolean := false;
    definition text;
    prefix text;
    signature text;
    recipient text;
    saved_role text := current_setting('role');
    saved_lock_timeout text := current_setting('lock_timeout');
    metadata_keys text[] := ARRAY[
        'prosecdef', 'proleakproof', 'proisstrict', 'provolatile', 'proparallel',
        'procost', 'prorows', 'prosupport', 'protransform', 'protrftypes',
        'proconfig', 'prokind', 'proisagg', 'proiswindow',
        'pronargdefaults', 'proargdefaults', 'provariadic'
    ];
    i integer;
    key text;
BEGIN
    IF target_schema IS NULL OR NOT EXISTS (
        SELECT FROM pg_namespace WHERE nspname = target_schema
    ) THEN
        RAISE EXCEPTION 'pgFirstAid needs a creation schema; set search_path';
    END IF;
    -- Bound DDL waits without changing the caller's session settings.
    IF (SELECT setting::integer FROM pg_settings WHERE name = 'lock_timeout') = 0
        OR (SELECT setting::integer FROM pg_settings WHERE name = 'lock_timeout') > 5000
    THEN
        PERFORM set_config('lock_timeout', '5s', true);
    END IF;
    FOR i IN 1..4 LOOP
        SELECT p.* INTO STRICT staged FROM pg_proc p
        WHERE pronamespace = pg_my_temp_schema() AND proname = stage_names[i];
        -- A partial or stale stage must never pass as the new collector.
        IF i = 4 AND (staged.pronargs <> 0
            OR staged.proargnames IS DISTINCT FROM
                array_append(expected_names, 'agent_prompt')
            OR staged.proallargtypes IS DISTINCT FROM array_fill(25::oid, ARRAY[9])
            OR staged.proargmodes IS DISTINCT FROM array_fill('t'::"char", ARRAY[9])
            OR NOT staged.proretset OR staged.prorettype <> 'record'::regtype) THEN
            RAISE EXCEPTION 'Invalid private collector stage; reconnect and execute the complete pgFirstAid.sql script';
        END IF;
        stages := array_append(stages, staged.oid);
        -- Defaults and variadic expansion can collide with an exact signature.
        IF EXISTS (
            SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = target_schema AND p.proname = target_names[i]
            AND p.proargtypes <> staged.proargtypes
            AND coalesce(to_jsonb(p)->>'prokind', 'f') <> 'p'
            AND (p.pronargdefaults > 0 OR p.provariadic <> 0)
            AND staged.pronargs >= greatest(0, p.pronargs - p.pronargdefaults -
                CASE WHEN p.provariadic <> 0 THEN 1 ELSE 0 END)
            AND (p.provariadic <> 0 OR staged.pronargs <= p.pronargs)
            AND NOT EXISTS (
                SELECT FROM generate_series(0, staged.pronargs - 1) AS arg(pos)
                WHERE staged.proargtypes[arg.pos] IS DISTINCT FROM
                    CASE WHEN p.provariadic <> 0 AND arg.pos >= p.pronargs - 1
                        THEN p.provariadic ELSE p.proargtypes[arg.pos] END
            )
        ) THEN
            RAISE EXCEPTION 'Overlapping defaulted or variadic overload of %.%; installation unchanged',
                target_schema, target_names[i]
                USING ERRCODE = '42725',
                HINT = 'Reconcile custom overloads before rerunning the complete script; do not use CASCADE.';
        END IF;
        SELECT p.* INTO previous FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = target_schema AND p.proname = target_names[i]
        AND p.proargtypes = staged.proargtypes;
        existing := array_append(existing, previous.oid);
        IF previous.oid IS NOT NULL THEN
            -- SET SCHEMA takes the DDL lock, but GRANT also needs a catalog
            -- tuple lock. A no-op COST update holds both before the ACL snapshot.
            EXECUTE format('ALTER FUNCTION %I.%I(%s) SET SCHEMA %I',
                target_schema, target_names[i],
                pg_get_function_identity_arguments(previous.oid), target_schema);
            SELECT p.* INTO STRICT previous FROM pg_proc p WHERE p.oid = previous.oid;
            EXECUTE format('ALTER FUNCTION %I.%I(%s) COST %s',
                target_schema, target_names[i],
                pg_get_function_identity_arguments(previous.oid), previous.procost);
        END IF;
    END LOOP;

    old_main := existing[4];
    FOR i IN 1..4 LOOP
        IF existing[i] IS NULL THEN
            CONTINUE;
        END IF;
        SELECT p.* INTO STRICT staged FROM pg_proc p WHERE oid = stages[i];
        SELECT p.* INTO STRICT previous FROM pg_proc p WHERE oid = existing[i];
        IF i = 4 THEN
            IF previous.proargnames = expected_names
                AND previous.proallargtypes = array_fill(25::oid, ARRAY[8])
                AND previous.proargmodes = array_fill('t'::"char", ARRAY[8])
                AND previous.proretset AND previous.prorettype = 'record'::regtype
            THEN
                legacy := true;
            ELSIF previous.proargnames IS DISTINCT FROM staged.proargnames
                OR previous.proallargtypes IS DISTINCT FROM staged.proallargtypes
                OR previous.proargmodes IS DISTINCT FROM staged.proargmodes
                OR previous.proretset IS DISTINCT FROM staged.proretset
                OR previous.prorettype IS DISTINCT FROM staged.prorettype
            THEN
                RAISE EXCEPTION 'Unknown pg_firstaid() return shape; installation unchanged'
                    USING HINT = 'Inventory the custom function and its dependencies; do not use CASCADE.';
            END IF;
        ELSIF previous.proargnames IS DISTINCT FROM staged.proargnames
            OR previous.proallargtypes IS DISTINCT FROM staged.proallargtypes
            OR previous.proargmodes IS DISTINCT FROM staged.proargmodes
            OR previous.proretset IS DISTINCT FROM staged.proretset
            OR previous.prorettype IS DISTINCT FROM staged.prorettype
        THEN
            RAISE EXCEPTION 'Unknown % signature; installation unchanged', target_names[i];
        END IF;
        FOREACH key IN ARRAY metadata_keys LOOP
            IF (to_jsonb(previous) -> key) IS DISTINCT FROM
                (to_jsonb(staged) -> key) THEN
                RAISE EXCEPTION 'Unsupported custom metadata (%) on %; installation unchanged',
                    key, target_names[i];
            END IF;
        END LOOP;
        IF EXISTS (SELECT FROM pg_seclabel
            WHERE classoid = 'pg_proc'::regclass AND objoid = previous.oid)
            OR EXISTS (SELECT FROM pg_depend
                WHERE classid = 'pg_proc'::regclass AND objid = previous.oid
                AND deptype = 'e') THEN
            RAISE EXCEPTION 'Unsupported security label or extension membership on %; installation unchanged',
                target_names[i];
        END IF;
    END LOOP;
    IF old_main IS NOT NULL THEN
        SELECT proowner, obj_description(oid, 'pg_proc') INTO old_owner, old_comment
        FROM pg_proc WHERE oid = old_main;
        SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.grantor, a.grantee), '[]')
        INTO old_acl FROM pg_proc p CROSS JOIN LATERAL
            aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
        WHERE p.oid = old_main;
    END IF;
    IF legacy THEN
        IF EXISTS (SELECT FROM pg_depend
            WHERE refclassid = 'pg_proc'::regclass AND refobjid = old_main) THEN
            RAISE EXCEPTION 'Dependent objects prevent the eight-column pg_firstaid() upgrade; installation unchanged'
                USING ERRCODE = '2BP01',
                HINT = 'Migrate dependencies explicitly; do not use CASCADE.';
        END IF;
        EXECUTE format('DROP FUNCTION %I.pg_firstaid() RESTRICT', target_schema);
    END IF;

    FOR i IN 1..4 LOOP
        definition := pg_get_functiondef(stages[i]);
        SELECT format('CREATE OR REPLACE FUNCTION pg_temp.%I(', p.proname)
        INTO prefix FROM pg_proc p WHERE p.oid = stages[i];
        IF left(definition, length(prefix)) <> prefix THEN
            RAISE EXCEPTION 'Unexpected staged function header; installation unchanged';
        END IF;
        -- Replace the identifier in the header only. PostgreSQL quotes the body.
        definition := format('CREATE OR REPLACE FUNCTION %I.%I(',
            target_schema, target_names[i]) || substr(definition, length(prefix) + 1);
        EXECUTE definition;
    END LOOP;
    IF legacy THEN
        signature := format('%I.pg_firstaid()', target_schema);
        SELECT p.oid INTO STRICT old_main FROM pg_proc p JOIN pg_namespace n
            ON n.oid = p.pronamespace WHERE n.nspname = target_schema
            AND p.proname = 'pg_firstaid' AND p.pronargs = 0;
        FOR recipient IN SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC'
            ELSE quote_ident(pg_get_userbyid(a.grantee)) END
            FROM pg_proc p CROSS JOIN LATERAL
                aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
            WHERE p.oid = old_main
        LOOP
            EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s RESTRICT',
                signature, recipient);
        END LOOP;
        EXECUTE format('ALTER FUNCTION %s OWNER TO %I', signature,
            pg_get_userbyid(old_owner));
        pending := old_acl;
        authorized := ARRAY[old_owner];
        WHILE jsonb_array_length(pending) > 0 LOOP
            progressed := false;
            FOR grant_item IN SELECT value FROM jsonb_array_elements(pending) LOOP
                IF NOT ((grant_item ->> 'grantor')::oid = ANY(authorized)) THEN
                    CONTINUE;
                END IF;
                PERFORM set_config('role', pg_get_userbyid(
                    (grant_item ->> 'grantor')::oid), true);
                recipient := CASE WHEN (grant_item ->> 'grantee')::oid = 0
                    THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(
                        (grant_item ->> 'grantee')::oid)) END;
                EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s%s',
                    signature, recipient, CASE WHEN
                    (grant_item ->> 'is_grantable')::boolean
                    THEN ' WITH GRANT OPTION' ELSE '' END);
                IF (grant_item ->> 'is_grantable')::boolean THEN
                    authorized := array_append(authorized,
                        (grant_item ->> 'grantee')::oid);
                END IF;
                SELECT coalesce(jsonb_agg(value), '[]') INTO pending
                FROM jsonb_array_elements(pending) WHERE value <> grant_item;
                progressed := true;
            END LOOP;
            IF NOT progressed THEN
                RAISE EXCEPTION 'Cannot preserve the pg_firstaid() ACL grant chain; installation unchanged';
            END IF;
        END LOOP;
        PERFORM set_config('role', saved_role, true);
        SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.grantor, a.grantee), '[]')
        INTO actual_acl FROM pg_proc p CROSS JOIN LATERAL
            aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
        WHERE p.oid = old_main;
        IF actual_acl IS DISTINCT FROM old_acl THEN
            RAISE EXCEPTION 'Cannot preserve exact pg_firstaid() ACL grantors; installation unchanged';
        END IF;
        EXECUTE format('COMMENT ON FUNCTION %s IS %L', signature, old_comment);
    END IF;

    -- Keep old callers authorized for every shared routine the report now uses.
    -- Fresh installs must not widen any preexisting helper's caller policy.
    IF existing[4] IS NOT NULL THEN
        FOR i IN 1..3 LOOP
            SELECT format('%I.%I(%s)', target_schema, target_names[i],
                oidvectortypes(p.proargtypes)) INTO signature
            FROM pg_proc p WHERE p.oid = stages[i];
            IF existing[i] IS NULL THEN
                FOR recipient IN SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                    ELSE quote_ident(pg_get_userbyid(a.grantee)) END
                    FROM pg_proc p CROSS JOIN LATERAL
                        aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    WHERE p.oid = signature::regprocedure
                LOOP
                    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s RESTRICT',
                        signature, recipient);
                END LOOP;
            END IF;
            FOR grant_item IN SELECT value FROM jsonb_array_elements(old_acl) LOOP
                IF (grant_item ->> 'grantee')::oid = 0 THEN
                    IF EXISTS (SELECT FROM pg_proc p CROSS JOIN LATERAL
                        aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                        WHERE p.oid = signature::regprocedure AND a.grantee = 0) THEN
                        CONTINUE;
                    END IF;
                    recipient := 'PUBLIC';
                ELSE
                    IF has_function_privilege((grant_item ->> 'grantee')::oid,
                        signature::regprocedure, 'EXECUTE') THEN
                        CONTINUE;
                    END IF;
                    recipient := quote_ident(pg_get_userbyid(
                        (grant_item ->> 'grantee')::oid));
                END IF;
                EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', signature, recipient);
            END LOOP;
        END LOOP;
    END IF;
    PERFORM set_config('role', saved_role, true);
    PERFORM set_config('lock_timeout', saved_lock_timeout, true);
END;
$function_install$;

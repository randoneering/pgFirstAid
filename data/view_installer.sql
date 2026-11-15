-- Source: data/view_installer.sql; run uv run python tools/sync_sql_helpers.py
-- Keep this invoker helper outside the report query so readers need no EXECUTE grant.
CREATE OR REPLACE FUNCTION _pgfirstaid_install_view(staging_view regclass)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $view_install$
DECLARE
    namespace_name text := pg_catalog.current_schema();
    target_name text := pg_catalog.format('%I.v_pgfirstaid', namespace_name);
    target_oid oid;
    target_kind "char";
    definition text;
    old_owner oid;
    old_comment text;
    old_options text[];
    options_clause text;
    old_acl jsonb;
    new_acl jsonb;
    columns_json jsonb;
    pending_acl jsonb;
    next_acl jsonb;
    item jsonb;
    entry record;
    grantor_name text;
    grantee_name text;
    original_role text := pg_catalog.current_setting('role');
    previous_timeout text := pg_catalog.current_setting('lock_timeout');
    progress boolean;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class
        WHERE oid = staging_view AND relnamespace = pg_catalog.pg_my_temp_schema()
          AND relname = '_pgfirstaid_view_stage' AND relkind = 'v'
    ) THEN
        RAISE EXCEPTION 'Expected reserved temporary staging view _pgfirstaid_view_stage';
    END IF;
    definition := pg_catalog.pg_get_viewdef(staging_view, false);
    IF (SELECT setting::bigint FROM pg_catalog.pg_settings
        WHERE name = 'lock_timeout') = 0 OR
       (SELECT setting::bigint FROM pg_catalog.pg_settings
        WHERE name = 'lock_timeout') > 2000 THEN
        PERFORM pg_catalog.set_config('lock_timeout', '2s', true);
    END IF;
    target_oid := pg_catalog.to_regclass(target_name);
    IF target_oid IS NOT NULL THEN
        SELECT relkind INTO target_kind FROM pg_catalog.pg_class WHERE oid = target_oid;
        IF target_kind <> 'v' THEN
            RAISE EXCEPTION '% is not an ordinary view; manual migration required', target_name;
        END IF;
        -- A same-schema move takes only the view's DDL lock, not its input tables' locks.
        EXECUTE pg_catalog.format('ALTER VIEW %s SET SCHEMA %I', target_name, namespace_name);
        IF pg_catalog.to_regclass(target_name)::oid <> target_oid THEN
            RAISE EXCEPTION '% changed concurrently; retry installation', target_name;
        END IF;
        SELECT reloptions INTO old_options
        FROM pg_catalog.pg_class WHERE oid = target_oid;
    END IF;
    -- Keep security options in the replacement DDL, not in a later repair step.
    SELECT coalesce(' WITH (' || pg_catalog.string_agg(pg_catalog.format('%I = %L',
        pg_catalog.split_part(opt.value, '=', 1),
        pg_catalog.substr(opt.value, pg_catalog.strpos(opt.value, '=') + 1)),
        ', ' ORDER BY opt.ord) || ')', '')
    INTO options_clause
    FROM pg_catalog.unnest(old_options) WITH ORDINALITY AS opt(value, ord);
    BEGIN
        EXECUTE pg_catalog.format('CREATE OR REPLACE VIEW %s%s AS %s',
                                  target_name, options_clause, definition);
        PERFORM pg_catalog.set_config('lock_timeout', previous_timeout, true);
        RETURN;
    EXCEPTION WHEN invalid_table_definition THEN
        IF target_oid IS NULL THEN
            RAISE;
        END IF;
    END;

    -- Capture only after taking the DDL lock, so concurrent grants cannot race the snapshot.
    SELECT relowner, reloptions, pg_catalog.obj_description(oid, 'pg_class')
    INTO old_owner, old_options, old_comment
    FROM pg_catalog.pg_class WHERE oid = target_oid;
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_rewrite
               WHERE ev_class = target_oid AND rulename <> '_RETURN')
       OR EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgrelid = target_oid)
       OR EXISTS (SELECT 1 FROM pg_catalog.pg_attrdef WHERE adrelid = target_oid)
       OR EXISTS (SELECT 1 FROM pg_catalog.pg_seclabel
                  WHERE classoid = 'pg_catalog.pg_class'::regclass AND objoid = target_oid)
       OR EXISTS (
           SELECT 1 FROM pg_catalog.pg_attribute a
           WHERE a.attrelid = target_oid AND a.attnum > 0 AND NOT a.attisdropped
             AND (a.attoptions IS NOT NULL OR a.attfdwoptions IS NOT NULL
                  OR a.attstattarget <> -1 OR
                  ((a.attacl IS NOT NULL OR
                    pg_catalog.col_description(target_oid, a.attnum) IS NOT NULL)
                   AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_attribute s
                                   WHERE s.attrelid = staging_view AND s.attnum > 0
                                     AND NOT s.attisdropped AND s.attname = a.attname)))
       ) THEN
        RAISE EXCEPTION '% has unsupported rules, triggers, defaults, security labels or column metadata; manual migration required', target_name;
    END IF;
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'name', attname, 'comment', pg_catalog.col_description(target_oid, attnum))
        ORDER BY attnum), '[]'::jsonb)
    INTO columns_json FROM pg_catalog.pg_attribute
    WHERE attrelid = target_oid AND attnum > 0 AND NOT attisdropped;

    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(a)
               ORDER BY a.col, a.grantor, a.grantee, a.privilege_type), '[]'::jsonb)
    INTO old_acl FROM (
        SELECT ''::text AS col, x.* FROM pg_catalog.pg_class c
        CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(c.relacl,
            pg_catalog.acldefault('r', c.relowner))) x WHERE c.oid = target_oid
        UNION ALL
        SELECT a.attname::text, x.* FROM pg_catalog.pg_attribute a
        CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) x
        WHERE a.attrelid = target_oid AND a.attnum > 0 AND NOT a.attisdropped
    ) a;
    -- Refuse grantors the installer cannot assume rather than silently changing provenance.
    FOR entry IN SELECT DISTINCT (value->>'grantor')::oid AS role_oid
                 FROM pg_catalog.jsonb_array_elements(old_acl)
                 UNION SELECT old_owner
    LOOP
        SELECT rolname INTO STRICT grantor_name FROM pg_catalog.pg_roles
        WHERE oid = entry.role_oid;
        PERFORM pg_catalog.set_config('role', grantor_name, true);
        PERFORM pg_catalog.set_config('role', original_role, true);
    END LOOP;

    EXECUTE pg_catalog.format('DROP VIEW %s RESTRICT', target_name);
    EXECUTE pg_catalog.format('CREATE VIEW %s%s AS %s',
                              target_name, options_clause, definition);
    target_oid := pg_catalog.to_regclass(target_name);
    -- Remove creation-time default grants before restoring the previous effective ACL.
    FOR entry IN SELECT DISTINCT x.grantee FROM pg_catalog.pg_class c
                 CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(c.relacl,
                     pg_catalog.acldefault('r', c.relowner))) x WHERE c.oid = target_oid
    LOOP
        IF entry.grantee = 0 THEN
            grantee_name := 'PUBLIC';
        ELSE
            SELECT pg_catalog.quote_ident(rolname) INTO STRICT grantee_name
            FROM pg_catalog.pg_roles WHERE oid = entry.grantee;
        END IF;
        EXECUTE pg_catalog.format('REVOKE ALL ON TABLE %s FROM %s RESTRICT',
                                  target_name, grantee_name);
    END LOOP;
    SELECT rolname INTO STRICT grantor_name FROM pg_catalog.pg_roles WHERE oid = old_owner;
    EXECUTE pg_catalog.format('ALTER VIEW %s OWNER TO %I', target_name, grantor_name);
    EXECUTE pg_catalog.format('COMMENT ON VIEW %s IS %L', target_name, old_comment);
    FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(columns_json) LOOP
        IF item->>'comment' IS NOT NULL THEN
            EXECUTE pg_catalog.format('COMMENT ON COLUMN %s.%I IS %L',
                                      target_name, item->>'name', item->>'comment');
        END IF;
    END LOOP;

    pending_acl := old_acl;
    WHILE pg_catalog.jsonb_array_length(pending_acl) > 0 LOOP
        progress := false;
        next_acl := '[]'::jsonb;
        FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(pending_acl) LOOP
            IF ((item->>'col' = '' AND pg_catalog.has_table_privilege(
                    (item->>'grantor')::oid, target_oid,
                    (item->>'privilege_type') || ' WITH GRANT OPTION'))
                OR (item->>'col' <> '' AND pg_catalog.has_column_privilege(
                    (item->>'grantor')::oid, target_oid, item->>'col',
                    (item->>'privilege_type') || ' WITH GRANT OPTION'))) THEN
                SELECT rolname INTO STRICT grantor_name FROM pg_catalog.pg_roles
                WHERE oid = (item->>'grantor')::oid;
                IF (item->>'grantee')::oid = 0 THEN
                    grantee_name := 'PUBLIC';
                ELSE
                    SELECT pg_catalog.quote_ident(rolname) INTO STRICT grantee_name
                    FROM pg_catalog.pg_roles WHERE oid = (item->>'grantee')::oid;
                END IF;
                PERFORM pg_catalog.set_config('role', grantor_name, true);
                EXECUTE pg_catalog.format('GRANT %s%s ON TABLE %s TO %s%s',
                    item->>'privilege_type',
                    CASE WHEN item->>'col' = '' THEN ''
                         ELSE pg_catalog.format(' (%I)', item->>'col') END,
                    target_name, grantee_name,
                    CASE WHEN (item->>'is_grantable')::boolean
                         THEN ' WITH GRANT OPTION' ELSE '' END);
                PERFORM pg_catalog.set_config('role', original_role, true);
                progress := true;
            ELSE
                next_acl := next_acl || pg_catalog.jsonb_build_array(item);
            END IF;
        END LOOP;
        IF NOT progress THEN
            RAISE EXCEPTION 'Cannot replay original grant chain for %; manual migration required', target_name;
        END IF;
        pending_acl := next_acl;
    END LOOP;
    SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(a)
               ORDER BY a.col, a.grantor, a.grantee, a.privilege_type), '[]'::jsonb)
    INTO new_acl FROM (
        SELECT ''::text AS col, x.* FROM pg_catalog.pg_class c
        CROSS JOIN LATERAL pg_catalog.aclexplode(coalesce(c.relacl,
            pg_catalog.acldefault('r', c.relowner))) x WHERE c.oid = target_oid
        UNION ALL
        SELECT a.attname::text, x.* FROM pg_catalog.pg_attribute a
        CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) x
        WHERE a.attrelid = target_oid AND a.attnum > 0 AND NOT a.attisdropped
    ) a;
    IF new_acl <> old_acl THEN
        RAISE EXCEPTION 'Original ACL grantors could not be preserved for %; manual migration required', target_name;
    END IF;
    PERFORM pg_catalog.set_config('lock_timeout', previous_timeout, true);
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_catalog.set_config('role', original_role, true);
    PERFORM pg_catalog.set_config('lock_timeout', previous_timeout, true);
    RAISE;
END;
$view_install$;

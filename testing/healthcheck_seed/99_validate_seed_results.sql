-- Validation summary for seeded checks.

SELECT
    severity,
    check_name,
    count(*) AS findings
FROM pg_firstAid()
GROUP BY severity, check_name
ORDER BY
    CASE severity
        WHEN 'CRITICAL' THEN 1
        WHEN 'HIGH' THEN 2
        WHEN 'MEDIUM' THEN 3
        WHEN 'LOW' THEN 4
        ELSE 5
    END,
    check_name;

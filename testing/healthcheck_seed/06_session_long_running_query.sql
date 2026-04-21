-- Session D (single long-running active query)
-- Helps trigger:
--   - Long Running Queries (>5 minutes)
--   - Top 10 Expensive Active Queries (>30 seconds)

SELECT pg_sleep(360);

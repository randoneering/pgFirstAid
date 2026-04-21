BEGIN;
SELECT 1;
\prompt 'Session is idle in transaction. Press enter to rollback and exit: ' dummy
ROLLBACK;

/*
    PostgreSQL: autovacuum, HOT-обновления, долгие транзакции
    Методичка: docs/03-postgresql.md (3.3, 3.5), docs/06-obsluzhivanie-diagnostika.md (6.1)
*/

-- 1. Когда autovacuum сработает для каждой таблицы
--    порог = autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * reltuples
--    (учитываются глобальные настройки; настройки отдельных таблиц в reloptions — смотрите отдельно)
SELECT s.relname,
       s.n_live_tup,
       s.n_dead_tup,
       round(current_setting('autovacuum_vacuum_threshold')::numeric
             + current_setting('autovacuum_vacuum_scale_factor')::numeric * c.reltuples) AS vacuum_threshold,
       s.last_autovacuum,
       s.last_autoanalyze,
       s.autovacuum_count,
       c.reloptions
FROM pg_stat_user_tables AS s
JOIN pg_class AS c ON c.oid = s.relid
ORDER BY s.n_dead_tup DESC
LIMIT 30;


-- 2. Доля HOT-обновлений: низкая при большом числе UPDATE — повод проверить
--    fillfactor таблицы и лишние индексы на обновляемых колонках
SELECT relname,
       n_tup_upd,
       n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0), 1) AS hot_pct
FROM pg_stat_user_tables
WHERE n_tup_upd > 1000
ORDER BY n_tup_upd DESC
LIMIT 30;


-- 3. fillfactor таблиц и индексов, заданный явно
SELECT c.relname, c.relkind, c.reloptions
FROM pg_class AS c
WHERE c.reloptions IS NOT NULL
  AND EXISTS (SELECT 1 FROM unnest(c.reloptions) AS o WHERE o LIKE 'fillfactor=%');

-- изменить (действует на новые страницы; для существующих — VACUUM FULL / pg_repack / REINDEX):
-- ALTER TABLE public.documents SET (fillfactor = 85);
-- ALTER TABLE public.documents SET (autovacuum_vacuum_scale_factor = 0.01);


-- 4. Долгие транзакции, которые держат «горизонт» и мешают VACUUM чистить
SELECT pid,
       usename,
       state,
       now() - xact_start  AS xact_duration,
       backend_xmin,
       left(query, 200)    AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 20;

-- Защита от забытых открытых транзакций (postgresql.conf или ALTER SYSTEM):
-- idle_in_transaction_session_timeout = '10min'


-- 5. Что сейчас делает autovacuum
SELECT p.pid, p.relid::regclass AS table_name, p.phase,
       p.heap_blks_total, p.heap_blks_scanned, p.index_vacuum_count
FROM pg_stat_progress_vacuum AS p;


-- 6. Текущие настройки autovacuum
SELECT name, setting, unit
FROM pg_settings
WHERE name LIKE 'autovacuum%' OR name IN ('maintenance_work_mem', 'autovacuum_work_mem')
ORDER BY name;

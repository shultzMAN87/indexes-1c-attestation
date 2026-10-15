/*
    PostgreSQL: невалидные индексы, REINDEX и REINDEX CONCURRENTLY
    Методичка: docs/03-postgresql.md, раздел 3.5

    REINDEX                — SHARE на таблицу (запрещены INSERT/UPDATE/DELETE)
                             + ACCESS EXCLUSIVE на сам индекс (ждут и запросы, которые хотят его использовать).
    REINDEX CONCURRENTLY   — PG 12+. Чтение и запись не блокируются, но дольше,
                             нельзя внутри BEGIN ... COMMIT, при сбое остаётся INVALID-индекс (_ccnew).
*/

-- 1. Невалидные индексы (остались после неудачных CREATE INDEX CONCURRENTLY / REINDEX CONCURRENTLY)
SELECT n.nspname                 AS schema_name,
       c.relname                 AS index_name,
       i.indrelid::regclass      AS table_name,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index AS i
JOIN pg_class AS c     ON c.oid = i.indexrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE NOT i.indisvalid;

-- такой индекс удаляют и строят заново:
-- DROP INDEX CONCURRENTLY public.ix_documents_date_ccnew;
-- REINDEX INDEX CONCURRENTLY public.ix_documents_date;


-- 2. Перестроение
-- один индекс без блокировки записи:
-- REINDEX INDEX CONCURRENTLY public.ix_documents_date;
-- все индексы таблицы:
-- REINDEX TABLE CONCURRENTLY public.documents;
-- создать новый индекс без блокировки записи:
-- CREATE INDEX CONCURRENTLY ix_documents_number ON public.documents (number);


-- 3. Прогресс построения индекса (PG 12+)
SELECT p.pid, p.relid::regclass AS table_name, p.index_relid::regclass AS index_name,
       p.command, p.phase,
       p.blocks_done, p.blocks_total,
       round(100.0 * p.blocks_done / NULLIF(p.blocks_total, 0), 1) AS pct
FROM pg_stat_progress_create_index AS p;


-- 4. Кто кого блокирует (если REINDEX «завис» в ожидании)
SELECT a.pid,
       pg_blocking_pids(a.pid) AS blocked_by,
       a.wait_event_type, a.wait_event,
       now() - a.query_start   AS waiting,
       left(a.query, 200)      AS query
FROM pg_stat_activity AS a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0;

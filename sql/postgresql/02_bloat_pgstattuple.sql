/*
    PostgreSQL: раздувание (bloat) и фрагментация
    Методичка: docs/03-postgresql.md, разделы 3.3 и 3.6

    Раздувание   — мало полезных данных ВНУТРИ страниц (мёртвые версии, пустота). Таблицы и индексы.
    Фрагментация — листовые страницы B-tree идут на диске НЕ ПО ПОРЯДКУ ключей. Только индексы.

    pgstattuple() и pgstatindex() читают объект ЦЕЛИКОМ — на больших объектах это долго и даёт нагрузку.
    Для таблиц есть приближённая быстрая версия pgstattuple_approx().
*/

CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- 1. Без расширения: мёртвые строки по статистике (быстро, приблизительно)
SELECT relname,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum,
       last_vacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 30;


-- 2. Раздувание таблицы — точно (подставьте имя таблицы)
SELECT table_len, tuple_count,
       tuple_percent,          -- доля места под живыми строками; < 50–70% — таблица раздута
       dead_tuple_count,
       dead_tuple_percent,     -- доля места под мёртвыми версиями (ещё не вычищены VACUUM)
       free_percent            -- свободное место (вычищено, но файл не уменьшился)
FROM pgstattuple('public.documents');

-- 2a. Быстрая оценка без полного чтения таблицы
SELECT * FROM pgstattuple_approx('public.documents');


-- 3. Индекс B-tree: плотность листьев и фрагментация (подставьте имя индекса)
SELECT version, tree_level, index_size,
       leaf_pages, empty_pages, deleted_pages,
       avg_leaf_density,       -- свежий B-tree ~ 90 (его fillfactor); < 50–60 — индекс раздут
       leaf_fragmentation      -- % листьев не по порядку; > 20–30 — индекс фрагментирован
FROM pgstatindex('public.ix_documents_date');


-- 4. Обход всех B-tree индексов размером больше 100 МБ
--    (тяжёлый запрос: читает каждый такой индекс целиком)
SELECT i.indexrelid::regclass                          AS index_name,
       pg_size_pretty(pg_relation_size(i.indexrelid))  AS size,
       s.avg_leaf_density,
       s.leaf_fragmentation
FROM pg_index AS i
JOIN pg_class AS c  ON c.oid = i.indexrelid
JOIN pg_am    AS am ON am.oid = c.relam
CROSS JOIN LATERAL pgstatindex(i.indexrelid::regclass) AS s
WHERE am.amname = 'btree'
  AND pg_relation_size(i.indexrelid) > 100 * 1024 * 1024
ORDER BY s.avg_leaf_density;


-- 5. Лечение (выполнять осознанно):
-- индекс без блокировки записи (PG 12+), нельзя внутри BEGIN ... COMMIT:
-- REINDEX INDEX CONCURRENTLY public.ix_documents_date;
-- таблица с полной блокировкой (только в окно простоя):
-- VACUUM FULL public.documents;
-- таблица онлайн — внешняя утилита pg_repack:
-- pg_repack --table=public.documents --dbname=mydb

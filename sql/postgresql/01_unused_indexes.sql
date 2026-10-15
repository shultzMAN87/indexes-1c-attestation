/*
    PostgreSQL: неиспользуемые, дублирующиеся и самые большие индексы
    Методичка: docs/03-postgresql.md, раздел 3.7

    Важно:
    - счётчики копятся с последнего сброса статистики (pg_stat_reset / stats_reset);
      на репликах статистика своя;
    - решать по полному бизнес-циклу (закрытие месяца, отчёты);
    - уникальные индексы обеспечивают целостность — их не удаляют по idx_scan;
    - в базе 1С почти все индексы платформы уникальные, а удалять их средствами СУБД нельзя.
      Для 1С запрос полезен, чтобы найти лишние признаки «Индексировать» в конфигураторе.
*/

-- 0. С какого момента копится статистика
SELECT datname, stats_reset FROM pg_stat_database WHERE datname = current_database();


-- 1. Редко используемые неуникальные индексы, сначала самые большие
SELECT s.schemaname,
       s.relname                                      AS table_name,
       s.indexrelname                                 AS index_name,
       s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       t.n_tup_ins + t.n_tup_upd + t.n_tup_del        AS table_writes
       -- , s.last_idx_scan                           -- PostgreSQL 16+
FROM pg_stat_user_indexes AS s
JOIN pg_index            AS i ON i.indexrelid = s.indexrelid
JOIN pg_stat_user_tables AS t ON t.relid = s.relid
WHERE s.idx_scan < 50
  AND NOT i.indisunique                -- для 1С уберите это условие
  AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 50;


-- 2. Индексы, которыми не пользовались ни разу (включая уникальные — только для анализа!)
SELECT s.relname AS table_name, s.indexrelname AS index_name,
       i.indisunique, pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_stat_user_indexes AS s
JOIN pg_index AS i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 50;


-- 3. Дубликаты: несколько индексов с одинаковым набором колонок на одной таблице
SELECT indrelid::regclass                              AS table_name,
       array_agg(indexrelid::regclass)                 AS duplicate_indexes,
       pg_size_pretty(sum(pg_relation_size(indexrelid))) AS total_size
FROM pg_index
GROUP BY indrelid, indkey, indclass, indexprs::text, indpred::text
HAVING count(*) > 1;


-- 4. Индексы, которые являются префиксом другого индекса той же таблицы
--    (индекс (a) обычно не нужен, если есть (a, b) — кроме уникальных и особых случаев)
SELECT a.indrelid::regclass  AS table_name,
       a.indexrelid::regclass AS shorter_index,
       b.indexrelid::regclass AS longer_index
FROM pg_index AS a
JOIN pg_index AS b
  ON a.indrelid = b.indrelid
 AND a.indexrelid <> b.indexrelid
 AND a.indnatts < b.indnatts
 AND (b.indkey::int2[])[0:a.indnatts - 1] = (a.indkey::int2[])[0:a.indnatts - 1]
WHERE NOT a.indisunique
  AND a.indexprs IS NULL AND b.indexprs IS NULL
  AND a.indpred IS NULL  AND b.indpred IS NULL;


-- 5. Размер таблиц и их индексов: где индексы весят больше данных
SELECT c.relname                                         AS table_name,
       pg_size_pretty(pg_table_size(c.oid))              AS table_size,
       pg_size_pretty(pg_indexes_size(c.oid))            AS indexes_size,
       round(pg_indexes_size(c.oid)::numeric / NULLIF(pg_table_size(c.oid), 0), 2) AS index_to_table
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_indexes_size(c.oid) DESC
LIMIT 30;

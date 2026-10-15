/*
    PostgreSQL: тяжёлые запросы
    Методичка: docs/03-postgresql.md (3.7), docs/06-obsluzhivanie-diagnostika.md (6.2)

    Подключение pg_stat_statements (нужен перезапуск сервера):
        postgresql.conf:  shared_preload_libraries = 'pg_stat_statements'
        затем в базе:     CREATE EXTENSION pg_stat_statements;

    ВНИМАНИЕ: с PostgreSQL 13 колонки называются total_exec_time / mean_exec_time.
    Старые total_time / mean_time (PG 12 и ниже) на новых версиях дадут ошибку.
*/

-- 1. Топ-20 по суммарному времени выполнения
SELECT round(total_exec_time::numeric / 1000, 1)                AS total_sec,
       calls,
       round(mean_exec_time::numeric, 1)                         AS avg_ms,
       rows,
       shared_blks_hit,
       shared_blks_read,                                         -- чтения не из кэша
       temp_blks_written,                                        -- сброс на диск (Sort/Hash)
       round(100.0 * shared_blks_hit
             / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
       left(query, 300)                                          AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 20;


-- 2. Топ по среднему времени (редкие, но очень медленные)
SELECT round(mean_exec_time::numeric, 1) AS avg_ms, calls, left(query, 300) AS query
FROM pg_stat_statements
WHERE calls >= 5
ORDER BY mean_exec_time DESC
LIMIT 20;


-- 3. Что выполняется прямо сейчас дольше 5 секунд
SELECT pid,
       now() - query_start AS duration,
       state,
       wait_event_type, wait_event,
       left(query, 300)    AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND now() - query_start > interval '5 seconds'
ORDER BY duration DESC;


-- 4. Сбросить накопленную статистику запросов (например, перед замером)
-- SELECT pg_stat_statements_reset();


/*
    Лог медленных запросов и их планов (postgresql.conf):

    log_min_duration_statement = 1000          # запросы дольше 1 с — в лог

    shared_preload_libraries = 'pg_stat_statements, auto_explain'
    auto_explain.log_min_duration = '3s'       # план запросов дольше 3 с
    auto_explain.log_analyze = on              # фактические строки и время (дороже)
    auto_explain.log_buffers = on
*/


-- 5. Разбор плана конкретного запроса
--    ANALYZE выполняет запрос по-настоящему: DML оборачивайте в транзакцию с откатом
-- BEGIN;
-- EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- ROLLBACK;

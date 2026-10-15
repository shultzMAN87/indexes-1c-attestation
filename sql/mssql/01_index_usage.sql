/*
    MS SQL Server: как используются существующие индексы
    Методичка: docs/02-mssql.md, раздел 2.4

    Важно:
    - sys.dm_db_index_usage_stats хранится в памяти и обнуляется при перезапуске экземпляра,
      отключении/закрытии базы. Сначала посмотрите, сколько времени копится статистика (запрос 0).
    - Решение "удалить индекс" принимают по статистике за полный бизнес-цикл
      (закрытие месяца, квартальные и годовые отчёты).
    - В базе 1С индексы удаляют не средствами СУБД, а снятием признака "Индексировать" в конфигураторе.
    Выполнять в контексте нужной базы: USE [ИмяБазы];
*/

-- 0. С какого момента копится статистика
SELECT sqlserver_start_time,
       DATEDIFF(DAY, sqlserver_start_time, SYSDATETIME()) AS days_collected
FROM sys.dm_os_sys_info;


-- 1. Все индексы пользовательских таблиц: чтения, записи, размер
SELECT
    OBJECT_SCHEMA_NAME(i.object_id)                         AS schema_name,
    OBJECT_NAME(i.object_id)                                AS table_name,
    i.name                                                  AS index_name,
    i.type_desc,
    i.is_unique,
    ISNULL(s.user_seeks, 0)                                 AS user_seeks,
    ISNULL(s.user_scans, 0)                                 AS user_scans,
    ISNULL(s.user_lookups, 0)                               AS user_lookups,
    ISNULL(s.user_updates, 0)                               AS user_updates,
    s.last_user_seek,
    s.last_user_scan,
    s.last_user_update,
    sz.size_mb
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS s
       ON s.object_id = i.object_id
      AND s.index_id = i.index_id
      AND s.database_id = DB_ID()
OUTER APPLY (
    SELECT CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18, 1)) AS size_mb
    FROM sys.dm_db_partition_stats AS ps
    WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id
) AS sz
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND i.index_id > 0                                        -- без куч
ORDER BY table_name, i.index_id;


-- 2. Кандидаты на удаление: некластерные, много записей, мало чтений
--    (уникальные и первичные ключи исключены — они обеспечивают целостность)
SELECT TOP (50)
    OBJECT_NAME(i.object_id)                                AS table_name,
    i.name                                                  AS index_name,
    ISNULL(s.user_seeks + s.user_scans + s.user_lookups, 0) AS reads,
    ISNULL(s.user_updates, 0)                               AS writes,
    sz.size_mb
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS s
       ON s.object_id = i.object_id
      AND s.index_id = i.index_id
      AND s.database_id = DB_ID()
OUTER APPLY (
    SELECT CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS decimal(18, 1)) AS size_mb
    FROM sys.dm_db_partition_stats AS ps
    WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id
) AS sz
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND i.type_desc = 'NONCLUSTERED'
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0
  AND i.is_unique = 0            -- в базе 1С большинство индексов уникальные: уберите условие, чтобы увидеть их
ORDER BY reads ASC, writes DESC;


-- 3. Индексы, к которым не было НИ ОДНОГО обращения с момента запуска
--    (строки в usage stats нет вообще)
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name                   AS index_name,
    i.type_desc
FROM sys.indexes AS i
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND i.index_id > 1                                        -- только некластерные
  AND NOT EXISTS (
        SELECT 1
        FROM sys.dm_db_index_usage_stats AS s
        WHERE s.database_id = DB_ID()
          AND s.object_id = i.object_id
          AND s.index_id = i.index_id)
ORDER BY table_name, index_name;


-- 4. Операционная статистика: блокировки, ожидания и признаки расщеплений страниц
--    leaf_allocation_count растёт при выделении новых листовых страниц (в т.ч. page split)
SELECT TOP (30)
    OBJECT_NAME(os.object_id)        AS table_name,
    i.name                           AS index_name,
    os.leaf_insert_count,
    os.leaf_allocation_count,        -- новые листовые страницы
    os.row_lock_wait_count,
    os.row_lock_wait_in_ms,
    os.page_latch_wait_count,
    os.page_latch_wait_in_ms,
    os.index_lock_promotion_count    -- сколько раз была эскалация блокировок
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) AS os
JOIN sys.indexes AS i
  ON i.object_id = os.object_id AND i.index_id = os.index_id
WHERE OBJECTPROPERTY(os.object_id, 'IsUserTable') = 1
ORDER BY os.leaf_allocation_count DESC;

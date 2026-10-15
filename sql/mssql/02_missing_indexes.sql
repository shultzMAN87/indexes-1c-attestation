/*
    MS SQL Server: недостающие индексы (missing indexes)
    Методичка: docs/02-mssql.md, раздел 2.4

    Ограничения рекомендаций — обязательно учитывать:
    1. Не учитывается цена записи (INSERT/UPDATE/DELETE), рост базы и обслуживания.
    2. Колонки перечислены в порядке следования в таблице, а не по селективности.
       Порядок ключа: сначала equality_columns, затем inequality_columns — и его выбирает человек.
    3. Предлагаются только обычные некластерные rowstore-индексы
       (никаких фильтруемых, уникальных, кластерных, columnstore, DESC).
    4. Данные в памяти, сбрасываются при перезапуске.
    5. Хранится не больше 600 групп рекомендаций.
    6. Рекомендации по похожим запросам дублируют друг друга — консолидируйте,
       часто достаточно расширить существующий индекс (INCLUDE).
    В базе 1С: используйте как подсказку, ГДЕ проблема. Решение — через метаданные или текст запроса.
*/

SELECT TOP (25)
    CAST(gs.avg_total_user_cost * (gs.avg_user_impact / 100.0)
         * (gs.user_seeks + gs.user_scans) AS decimal(18, 1))   AS improvement_measure,
    DB_NAME(d.database_id)                                       AS database_name,
    d.statement                                                  AS table_name,
    d.equality_columns,
    d.inequality_columns,
    d.included_columns,
    gs.user_seeks,
    gs.user_scans,
    CAST(gs.avg_total_user_cost AS decimal(18, 2))               AS avg_query_cost,
    gs.avg_user_impact                                           AS avg_impact_pct,
    gs.last_user_seek,
    -- черновик команды: имя и порядок колонок нужно продумать самостоятельно
    'CREATE INDEX IX_' + OBJECT_NAME(d.object_id, d.database_id) + '_missing_'
        + CAST(d.index_handle AS varchar(10))
        + ' ON ' + d.statement
        + ' (' + ISNULL(d.equality_columns, '')
        + CASE WHEN d.equality_columns IS NOT NULL AND d.inequality_columns IS NOT NULL
               THEN ', ' ELSE '' END
        + ISNULL(d.inequality_columns, '') + ')'
        + ISNULL(' INCLUDE (' + d.included_columns + ')', '')   AS draft_create_statement
FROM sys.dm_db_missing_index_group_stats AS gs
JOIN sys.dm_db_missing_index_groups      AS g ON g.index_group_handle = gs.group_handle
JOIN sys.dm_db_missing_index_details     AS d ON d.index_handle = g.index_handle
WHERE d.database_id = DB_ID()
ORDER BY improvement_measure DESC;


-- SQL Server 2019+: какие запросы просили индекс (текст запроса)
/*
SELECT TOP (25)
    gsq.avg_total_user_cost * gsq.avg_user_impact * (gsq.user_seeks + gsq.user_scans) AS score,
    SUBSTRING(st.text, gsq.last_statement_start_offset / 2 + 1,
              (CASE gsq.last_statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                    ELSE gsq.last_statement_end_offset END
               - gsq.last_statement_start_offset) / 2 + 1)                             AS query_text,
    d.statement, d.equality_columns, d.inequality_columns, d.included_columns
FROM sys.dm_db_missing_index_group_stats_query AS gsq
JOIN sys.dm_db_missing_index_groups  AS g ON g.index_group_handle = gsq.group_handle
JOIN sys.dm_db_missing_index_details AS d ON d.index_handle = g.index_handle
CROSS APPLY sys.dm_exec_sql_text(gsq.last_sql_handle) AS st
WHERE d.database_id = DB_ID()
ORDER BY score DESC;
*/

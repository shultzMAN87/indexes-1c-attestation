/*
    MS SQL Server: тяжёлые запросы и их планы (без трассировки)
    Методичка: docs/06-obsluzhivanie-diagnostika.md, раздел 6.2

    sys.dm_exec_query_stats — статистика по запросам, чьи планы сейчас в кэше.
    После DBCC FREEPROCCACHE или перезапуска она пустеет.
    Для истории используйте Query Store (SQL Server 2016+).
*/

-- 1. Топ-20 по суммарному времени выполнения
SELECT TOP (20)
    qs.execution_count,
    CAST(qs.total_elapsed_time / 1000000.0 AS decimal(18, 1))               AS total_sec,
    CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS decimal(18, 1)) AS avg_ms,
    qs.total_logical_reads / qs.execution_count                             AS avg_logical_reads,
    CAST(qs.total_worker_time / 1000000.0 AS decimal(18, 1))                AS total_cpu_sec,
    DB_NAME(st.dbid)                                                        AS database_name,
    SUBSTRING(st.text, qs.statement_start_offset / 2 + 1,
              (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                    ELSE qs.statement_end_offset END
               - qs.statement_start_offset) / 2 + 1)                        AS statement_text,
    qp.query_plan                                                           -- щёлкнуть в SSMS: графический план
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_elapsed_time DESC;


-- 2. Планы, в которых есть сканирование конкретной таблицы
--    (подставьте физическое имя таблицы 1С, например _AccumRgT1234)
DECLARE @table sysname = N'_AccumRgT1234';

SELECT TOP (20)
    qs.execution_count,
    qs.total_logical_reads,
    SUBSTRING(st.text, 1, 500) AS query_start,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE CAST(qp.query_plan AS nvarchar(max)) LIKE N'%' + @table + N'%'
  AND (   CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Clustered Index Scan"%'
       OR CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Table Scan"%'
       OR CAST(qp.query_plan AS nvarchar(max)) LIKE N'%PhysicalOp="Index Scan"%')
ORDER BY qs.total_logical_reads DESC;


-- 3. Query Store: запросы с наибольшим средним временем за последние сутки
/*
SELECT TOP (20)
    q.query_id,
    qt.query_sql_text,
    rs.count_executions,
    CAST(rs.avg_duration / 1000.0 AS decimal(18, 1)) AS avg_ms,
    p.plan_id
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_plan          AS p  ON p.plan_id = rs.plan_id
JOIN sys.query_store_query         AS q  ON q.query_id = p.query_id
JOIN sys.query_store_query_text    AS qt ON qt.query_text_id = q.query_text_id
WHERE rs.last_execution_time > DATEADD(DAY, -1, SYSUTCDATETIME())
ORDER BY rs.avg_duration DESC;
*/


-- 4. Extended Events: сессия для медленных запросов (> 1 с)
/*
CREATE EVENT SESSION slow_queries ON SERVER
ADD EVENT sqlserver.rpc_completed (
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.client_app_name, sqlserver.plan_handle)
    WHERE duration > 1000000),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.sql_text, sqlserver.database_name, sqlserver.client_app_name, sqlserver.plan_handle)
    WHERE duration > 1000000)
ADD TARGET package0.event_file (SET filename = N'slow_queries.xel', max_file_size = 100)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS);

ALTER EVENT SESSION slow_queries ON SERVER STATE = START;
-- ...
ALTER EVENT SESSION slow_queries ON SERVER STATE = STOP;

SELECT CAST(event_data AS xml) AS ev
FROM sys.fn_xe_file_target_read_file(N'slow_queries*.xel', NULL, NULL, NULL);
*/

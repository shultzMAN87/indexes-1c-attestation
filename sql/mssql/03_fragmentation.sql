/*
    MS SQL Server: фрагментация и плотность страниц
    Методичка: docs/02-mssql.md, разделы 2.2 и 2.3

    avg_fragmentation_in_percent   — логическая фрагментация (страницы не по порядку)
    avg_page_space_used_in_percent — плотность страниц (NULL в режиме LIMITED!)

    Режимы sys.dm_db_index_physical_stats:
      LIMITED  — быстро, только верхние уровни; плотность не считает
      SAMPLED  — выборка страниц; плотность считает (для больших баз — разумный выбор)
      DETAILED — все страницы; точно, но долго и с нагрузкой на IO
    На большой рабочей базе запускать в период низкой нагрузки.
*/

DECLARE @min_pages int = 1000;   -- маленькие индексы не обслуживают: эффекта нет

SELECT
    OBJECT_SCHEMA_NAME(ips.object_id)                       AS schema_name,
    OBJECT_NAME(ips.object_id)                              AS table_name,
    i.name                                                  AS index_name,
    ips.index_type_desc,
    ips.partition_number,
    ips.page_count,
    CAST(ips.page_count * 8 / 1024.0 AS decimal(18, 1))     AS size_mb,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5, 1)) AS fragmentation_pct,
    CAST(ips.avg_page_space_used_in_percent AS decimal(5, 1)) AS page_density_pct,
    i.fill_factor,
    STATS_DATE(i.object_id, i.index_id)                     AS stats_updated
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS ips
JOIN sys.indexes AS i
  ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.index_id > 0                    -- без куч
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
  AND ips.page_count >= @min_pages
ORDER BY ips.page_count DESC;


-- Индексы с нестандартным fill factor
SELECT OBJECT_NAME(object_id) AS table_name, name AS index_name, fill_factor, is_padded
FROM sys.indexes
WHERE fill_factor NOT IN (0, 100)
  AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1;


-- Columnstore: доля удалённых строк в группах строк (аналог фрагментации)
/*
SELECT OBJECT_NAME(object_id) AS table_name, index_id, row_group_id, state_desc,
       total_rows, deleted_rows,
       CAST(100.0 * deleted_rows / NULLIF(total_rows, 0) AS decimal(5, 1)) AS deleted_pct
FROM sys.dm_db_column_store_row_group_physical_stats
ORDER BY deleted_pct DESC;
*/

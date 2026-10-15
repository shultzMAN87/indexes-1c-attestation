/*
    MS SQL Server: выборочное обслуживание индексов и статистики
    Методичка: docs/02-mssql.md (2.3), docs/06-obsluzhivanie-diagnostika.md (6.1)

    По умолчанию скрипт ТОЛЬКО ПЕЧАТАЕТ команды (@execute = 0).
    Проверьте список и только потом запускайте с @execute = 1 в технологическое окно.

    Логика (классические пороги — как отправная точка, подбирайте по измеренному эффекту):
      - индексы меньше @min_pages страниц не трогаем;
      - фрагментация >= @rebuild_pct или плотность < @min_density -> REBUILD;
      - фрагментация >= @reorg_pct -> REORGANIZE (+ отдельно обновить статистику);
      - остальное не трогаем.
    Для промышленного использования удобнее готовая процедура IndexOptimize (ola.hallengren.com).
*/

DECLARE @execute      bit     = 0;      -- 0 = только показать команды, 1 = выполнить
DECLARE @min_pages    int     = 1000;
DECLARE @reorg_pct    float   = 10.0;
DECLARE @rebuild_pct  float   = 30.0;
DECLARE @min_density  float   = 60.0;   -- плотность страниц, %, ниже которой перестраиваем
DECLARE @online       bit     = 0;      -- 1 = ONLINE = ON (только Enterprise / Developer / Azure SQL)
DECLARE @fill_factor  tinyint = NULL;   -- NULL = оставить текущий fill factor индекса

DECLARE @cmd nvarchar(max), @obj nvarchar(300), @idx sysname,
        @frag float, @dens float, @pages bigint, @kind varchar(10);

DECLARE work CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(OBJECT_SCHEMA_NAME(ips.object_id)) + '.' + QUOTENAME(OBJECT_NAME(ips.object_id)),
           i.name,
           ips.avg_fragmentation_in_percent,
           ips.avg_page_space_used_in_percent,
           ips.page_count
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS ips
    JOIN sys.indexes AS i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
    WHERE ips.index_id > 0
      AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
      AND ips.page_count >= @min_pages
      AND i.is_disabled = 0
      AND OBJECTPROPERTY(ips.object_id, 'IsUserTable') = 1
    ORDER BY ips.page_count DESC;

OPEN work;
FETCH NEXT FROM work INTO @obj, @idx, @frag, @dens, @pages;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @kind = CASE
                    WHEN @frag >= @rebuild_pct OR @dens < @min_density THEN 'REBUILD'
                    WHEN @frag >= @reorg_pct                            THEN 'REORGANIZE'
                    ELSE NULL
                END;

    IF @kind = 'REBUILD'
        SET @cmd = N'ALTER INDEX ' + QUOTENAME(@idx) + N' ON ' + @obj + N' REBUILD WITH (SORT_IN_TEMPDB = ON'
                 + CASE WHEN @online = 1 THEN N', ONLINE = ON' ELSE N'' END
                 + CASE WHEN @fill_factor IS NOT NULL THEN N', FILLFACTOR = ' + CAST(@fill_factor AS nvarchar(3)) ELSE N'' END
                 + N');';
    ELSE IF @kind = 'REORGANIZE'
        -- REORGANIZE не обновляет статистику — делаем это отдельно
        SET @cmd = N'ALTER INDEX ' + QUOTENAME(@idx) + N' ON ' + @obj + N' REORGANIZE; '
                 + N'UPDATE STATISTICS ' + @obj + N' ' + QUOTENAME(@idx) + N';';
    ELSE
        SET @cmd = NULL;

    IF @cmd IS NOT NULL
    BEGIN
        PRINT CONCAT('-- ', @obj, '.', @idx, ': фрагментация ', CAST(@frag AS decimal(5,1)),
                     '%, плотность ', CAST(@dens AS decimal(5,1)), '%, страниц ', @pages);
        PRINT @cmd;
        IF @execute = 1 EXEC sys.sp_executesql @cmd;
    END;

    FETCH NEXT FROM work INTO @obj, @idx, @frag, @dens, @pages;
END;
CLOSE work;
DEALLOCATE work;


/* ------------------------------------------------------------------------
   Обновление статистики (ежедневно)
   ------------------------------------------------------------------------ */

-- Вариант 1: только там, где были изменения, с выборкой — быстро
-- EXEC sys.sp_updatestats;

-- Вариант 2: полная выборка для конкретной большой таблицы (например, итоги регистра)
-- UPDATE STATISTICS dbo._AccumRgT1234 WITH FULLSCAN;

-- Затем, по рекомендации методики 1С, сбросить кэш планов, построенных по старой статистике:
-- DBCC FREEPROCCACHE;

-- Когда статистика обновлялась (для проверки регламента)
SELECT TOP (50)
    OBJECT_NAME(s.object_id)  AS table_name,
    s.name                    AS stats_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter   -- изменений с последнего обновления
FROM sys.stats AS s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
ORDER BY sp.modification_counter DESC;

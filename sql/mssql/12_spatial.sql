-- =============================================================================
-- 12_spatial.sql — пространственный индекс: сетка ячеек + B-tree
-- К разделу 2.5 методички (docs/02-mssql.md), подраздел «Пространственный индекс».
--
-- Что показывает:
--   1. 200 000 точек-магазинов (geography) и полигон района.
--   2. Три типичных запроса без индекса: «в радиусе», «в районе», «N ближайших».
--   3. Индекс с автоматической сеткой: те же запросы, план (первичный фильтр
--      по ячейкам + вторичный Filter), чтения.
--   4. Насколько хорош индекс: sp_help_spatial_geography_index.
--   5. Ручная сетка (GRIDS, CELLS_PER_OBJECT) и её параметры в каталоге.
--   6. Условие в «неудобной» форме — индекс не используется.
--
-- Требуется: SQL Server 2012+ (автоматическая сетка, KNN-запрос). Создаёт и
-- удаляет отдельную базу demo_spatial. Запускать по частям; в SSMS включите
-- «Include Actual Execution Plan» (Ctrl+M).
-- =============================================================================

USE master;
GO
IF DB_ID(N'demo_spatial') IS NOT NULL
BEGIN
    ALTER DATABASE demo_spatial SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_spatial;
END;
GO
CREATE DATABASE demo_spatial;
GO
USE demo_spatial;
GO

-- -----------------------------------------------------------------------------
-- 1. Данные. Пространственному индексу нужен кластерный первичный ключ.
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Shops
(
    Id   int IDENTITY NOT NULL CONSTRAINT PK_Shops PRIMARY KEY CLUSTERED,
    Name nvarchar(50) NOT NULL,
    Geo  geography    NOT NULL
);

-- Случайные точки в прямоугольнике вокруг Москвы: широта 55.55–55.95, долгота 37.35–37.85.
INSERT INTO dbo.Shops WITH (TABLOCK) (Name, Geo)
SELECT TOP (200000)
       N'Магазин ' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS nvarchar(10)),
       geography::Point(55.55 + ABS(CHECKSUM(NEWID()) % 400000) / 1000000.0,
                        37.35 + ABS(CHECKSUM(NEWID()) % 500000) / 1000000.0, 4326)
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

CREATE TABLE dbo.Districts
(
    Id   int          NOT NULL CONSTRAINT PK_Districts PRIMARY KEY CLUSTERED,
    Name nvarchar(50) NOT NULL,
    Geo  geography    NOT NULL
);
-- WKT для geography: «долгота широта». Внешнее кольцо — против часовой стрелки,
-- иначе SQL Server поймёт полигон как «вся Земля, кроме этого района».
DECLARE @d geography = geography::STGeomFromText(
    N'POLYGON((37.58 55.72, 37.68 55.71, 37.70 55.77, 37.64 55.80, 37.57 55.78, 37.58 55.72))', 4326);
IF @d.EnvelopeAngle() > 90 SET @d = @d.ReorientObject();   -- страховка от неверного обхода
INSERT INTO dbo.Districts (Id, Name, Geo) VALUES (1, N'Центр', @d);
GO

SELECT COUNT(*) AS shops FROM dbo.Shops;
SELECT Name, Geo.STArea() / 1e6 AS area_km2 FROM dbo.Districts;   -- порядка 40 км²
GO

-- -----------------------------------------------------------------------------
-- 2. Запросы БЕЗ индекса — запомните чтения и время
-- -----------------------------------------------------------------------------
SET STATISTICS IO, TIME ON;
DECLARE @p geography = geography::Point(55.7558, 37.6173, 4326);       -- точка в центре
DECLARE @d geography = (SELECT Geo FROM dbo.Districts WHERE Id = 1);

-- 2.1. В радиусе 500 м
SELECT COUNT(*) AS in_radius FROM dbo.Shops WHERE Geo.STDistance(@p) <= 500;
-- 2.2. Внутри района
SELECT COUNT(*) AS in_district FROM dbo.Shops WHERE Geo.STIntersects(@d) = 1;
-- 2.3. Пять ближайших
SELECT TOP (5) Id, Name, Geo.STDistance(@p) AS meters
FROM dbo.Shops
WHERE Geo.STDistance(@p) IS NOT NULL
ORDER BY Geo.STDistance(@p);
SET STATISTICS IO, TIME OFF;
-- Ожидаемо: везде Clustered Index Scan по всем 200 000 строк, и для каждой строки
-- вычисляется расстояние или пересечение — заметное CPU.
GO

-- -----------------------------------------------------------------------------
-- 3. Индекс с автоматической сеткой (8 уровней) — по умолчанию с SQL Server 2012
-- -----------------------------------------------------------------------------
CREATE SPATIAL INDEX SIX_Shops_Geo ON dbo.Shops (Geo)
    USING GEOGRAPHY_AUTO_GRID
    WITH (CELLS_PER_OBJECT = 12);
GO

SET STATISTICS IO, TIME ON;
DECLARE @p geography = geography::Point(55.7558, 37.6173, 4326);
DECLARE @d geography = (SELECT Geo FROM dbo.Districts WHERE Id = 1);

SELECT COUNT(*) AS in_radius FROM dbo.Shops WHERE Geo.STDistance(@p) <= 500;
SELECT COUNT(*) AS in_district FROM dbo.Shops WHERE Geo.STIntersects(@d) = 1;
SELECT TOP (5) Id, Name, Geo.STDistance(@p) AS meters
FROM dbo.Shops
WHERE Geo.STDistance(@p) IS NOT NULL
ORDER BY Geo.STDistance(@p);
SET STATISTICS IO, TIME OFF;
-- В плане:
--   Clustered Index Seek (Spatial) по внутренней таблице индекса
--     (в STATISTICS IO она видна как 'extended_index_…') — первичный фильтр по ячейкам;
--   Nested Loops → Clustered Index Seek по dbo.Shops — достать кандидатов;
--   Filter с STDistance / STIntersects — вторичный фильтр, точная проверка.
-- Если оптимизатор не взял индекс (маленькая выборка, другая оценка), добавьте
-- WITH (INDEX(SIX_Shops_Geo)) после имени таблицы и сравните.
GO

-- Внутренняя таблица индекса: это и есть B-tree «ячейка → первичный ключ».
SELECT it.name AS internal_table, it.internal_type_desc, SUM(ps.row_count) AS rows_, SUM(ps.used_page_count) * 8 AS used_kb
FROM sys.internal_tables AS it
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = it.object_id AND ps.index_id IN (0, 1)
WHERE it.parent_id = OBJECT_ID(N'dbo.Shops')
GROUP BY it.name, it.internal_type_desc;
-- Ожидаемо: EXTENDED_INDEXES, ~200 000 строк — точка всегда занимает одну ячейку.
GO

-- -----------------------------------------------------------------------------
-- 4. Насколько хорошо индекс фильтрует запрос
-- -----------------------------------------------------------------------------
DECLARE @d geography = (SELECT Geo FROM dbo.Districts WHERE Id = 1);
EXEC sp_help_spatial_geography_index
     @tabname       = N'dbo.Shops',
     @indexname     = N'SIX_Shops_Geo',
     @verboseoutput = 1,
     @query_sample  = @d;
-- Важные строки вывода:
--   Total_Primary_Index_Rows, Total_Primary_Index_Pages — размер индекса;
--   Number_Of_Rows_Selected_By_Primary_Filter     — сколько кандидатов дал первичный фильтр;
--   Number_Of_Rows_Selected_By_Internal_Filter    — сколько принято без точной проверки;
--   Number_Of_Times_Secondary_Filter_Is_Called    — сколько раз выполнялась точная проверка;
--   Primary_Filter_Efficiency                     — доля кандидатов, оказавшихся в ответе;
--   Internal_Filter_Efficiency                    — доля ответа, полученная без проверки.
GO

-- -----------------------------------------------------------------------------
-- 5. Ручная сетка: 4 уровня с явной плотностью
-- -----------------------------------------------------------------------------
CREATE SPATIAL INDEX SIX_Shops_Geo ON dbo.Shops (Geo)
    USING GEOGRAPHY_GRID
    WITH (GRIDS = (LEVEL_1 = LOW, LEVEL_2 = LOW, LEVEL_3 = MEDIUM, LEVEL_4 = HIGH),
          CELLS_PER_OBJECT = 16,
          DROP_EXISTING = ON);
GO
SELECT tessellation_scheme, level_1_grid_desc, level_2_grid_desc, level_3_grid_desc, level_4_grid_desc, cells_per_object
FROM sys.spatial_index_tessellations
WHERE object_id = OBJECT_ID(N'dbo.Shops');
-- У автоматической сетки level_*_grid пустые (NULL): уровней 8, плотность фиксирована.

DECLARE @d geography = (SELECT Geo FROM dbo.Districts WHERE Id = 1);
EXEC sp_help_spatial_geography_index N'dbo.Shops', N'SIX_Shops_Geo', 1, @d;
-- Сравните Primary_Filter_Efficiency с автоматической сеткой: при грубой сетке
-- первичный фильтр даёт больше лишних кандидатов, и вторичный фильтр работает больше.
GO

-- -----------------------------------------------------------------------------
-- 6. Условие, которое ломает использование индекса
-- -----------------------------------------------------------------------------
SET STATISTICS IO ON;
DECLARE @p geography = geography::Point(55.7558, 37.6173, 4326);
DECLARE @d geography = (SELECT Geo FROM dbo.Districts WHERE Id = 1);

SELECT COUNT(*) FROM dbo.Shops WHERE Geo.STDistance(@p) <= 500;           -- индекс работает
SELECT COUNT(*) FROM dbo.Shops WHERE Geo.STDistance(@p) / 1000.0 <= 0.5;  -- выражение поверх метода → Scan
SELECT COUNT(*) FROM dbo.Shops WHERE Geo.STIntersects(@d) = 0;            -- «НЕ пересекается» → Scan
SET STATISTICS IO OFF;
-- Индекс понимает только формы вида  колонка.Метод(@g) = 1  и  колонка.STDistance(@g) < / <= число.
GO

-- -----------------------------------------------------------------------------
-- 7. Уборка
-- -----------------------------------------------------------------------------
USE master;
GO
ALTER DATABASE demo_spatial SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE demo_spatial;
GO

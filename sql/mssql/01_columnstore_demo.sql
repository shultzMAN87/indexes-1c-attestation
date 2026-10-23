/* =====================================================================
   Columnstore vs rowstore: учебная демонстрация
   К разделу 2.5 методички (docs/02-mssql.md)

   Требуется: SQL Server 2016 SP1+ (подходят Developer и Express).
   Запускать в ОТДЕЛЬНОЙ тестовой базе, не в базе 1С.
   В SSMS перед шагом 4 включите «Include Actual Execution Plan» (Ctrl+M).
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 0. Тестовая база
-- ---------------------------------------------------------------------
-- CREATE DATABASE ColumnstoreDemo;
-- GO
-- USE ColumnstoreDemo;
-- GO

DROP TABLE IF EXISTS dbo.SalesRow;
DROP TABLE IF EXISTS dbo.SalesCol;
GO

-- ---------------------------------------------------------------------
-- 1. Две одинаковые таблицы
-- ---------------------------------------------------------------------
CREATE TABLE dbo.SalesRow (
    SaleDate  date          NOT NULL,
    ProductID int           NOT NULL,
    StoreID   int           NOT NULL,
    Amount    decimal(18,2) NOT NULL
);

CREATE TABLE dbo.SalesCol (
    SaleDate  date          NOT NULL,
    ProductID int           NOT NULL,
    StoreID   int           NOT NULL,
    Amount    decimal(18,2) NOT NULL
);
GO

-- ---------------------------------------------------------------------
-- 2. 5 млн строк: даты за 3 года, 5000 товаров, 50 складов
--    (занимает от десятков секунд до пары минут)
-- ---------------------------------------------------------------------
INSERT INTO dbo.SalesRow WITH (TABLOCK) (SaleDate, ProductID, StoreID, Amount)
SELECT TOP (5000000)
       DATEADD(day, ABS(CHECKSUM(NEWID())) % 1095, '2022-01-01'),
       ABS(CHECKSUM(NEWID())) % 5000,
       ABS(CHECKSUM(NEWID())) % 50,
       ABS(CHECKSUM(NEWID())) % 100000 / 100.0
FROM sys.all_objects AS a
CROSS JOIN sys.all_objects AS b;

INSERT INTO dbo.SalesCol WITH (TABLOCK) (SaleDate, ProductID, StoreID, Amount)
SELECT SaleDate, ProductID, StoreID, Amount FROM dbo.SalesRow;
GO

-- ---------------------------------------------------------------------
-- 3. Индексы: обычный кластерный (B-дерево) и кластерный columnstore
-- ---------------------------------------------------------------------
CREATE CLUSTERED INDEX CIX_SalesRow ON dbo.SalesRow (SaleDate);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_SalesCol ON dbo.SalesCol;
GO

-- Размер: columnstore в несколько раз меньше
EXEC sp_spaceused 'dbo.SalesRow';
EXEC sp_spaceused 'dbo.SalesCol';
GO

-- ---------------------------------------------------------------------
-- 4. Один и тот же агрегат по обеим таблицам
--    Смотреть:
--    * вкладка Messages: SalesRow — logical reads;
--      SalesCol — lob logical reads и «segment reads N, segment skipped M»;
--    * план: Clustered Index Seek/Scan против Columnstore Index Scan;
--    * свойства оператора (F4): Actual Execution Mode = Row / Batch;
--    * CPU time в STATISTICS TIME.
-- ---------------------------------------------------------------------
SET STATISTICS IO, TIME ON;

SELECT StoreID, SUM(Amount) AS Amount
FROM dbo.SalesRow
WHERE SaleDate >= '2024-06-01'
GROUP BY StoreID;

SELECT StoreID, SUM(Amount) AS Amount
FROM dbo.SalesCol
WHERE SaleDate >= '2024-06-01'
GROUP BY StoreID;

SET STATISTICS IO, TIME OFF;
GO

-- ---------------------------------------------------------------------
-- 5. Что внутри: группы строк и сегменты
-- ---------------------------------------------------------------------
-- Группы строк: состояние, число строк, удалённые строки, причина «обрезки»
SELECT row_group_id, state_desc, total_rows, deleted_rows,
       size_in_bytes, trim_reason_desc
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.SalesCol')
ORDER BY row_group_id;

-- Сегменты: по одному на колонку в каждой группе строк.
-- min_data_id / max_data_id — основа segment elimination.
-- Для части типов это не сами значения, а закодированные (или id словаря).
SELECT c.name AS column_name, s.segment_id, s.row_count,
       s.min_data_id, s.max_data_id, s.on_disk_size
FROM sys.column_store_segments AS s
JOIN sys.partitions AS p ON p.hobt_id = s.hobt_id
JOIN sys.columns    AS c ON c.object_id = p.object_id AND c.column_id = s.column_id
WHERE p.object_id = OBJECT_ID('dbo.SalesCol')
ORDER BY c.name, s.segment_id;
GO

-- ---------------------------------------------------------------------
-- 6. Segment elimination и порядок данных
--    Даты загружены вразнобой → у каждой группы min/max даты почти на весь
--    диапазон → в шаге 4 почти нет «segment skipped».
--    Пересоздаём columnstore по данным, отсортированным по дате.
-- ---------------------------------------------------------------------
-- 6.1. Превратить columnstore в обычный кластерный индекс по дате (сортировка)
CREATE CLUSTERED INDEX CCI_SalesCol ON dbo.SalesCol (SaleDate)
    WITH (DROP_EXISTING = ON);

-- 6.2. Снова сжать в columnstore, сохранив порядок (MAXDOP = 1 — один поток,
--      чтобы порядок не перемешался между потоками)
CREATE CLUSTERED COLUMNSTORE INDEX CCI_SalesCol ON dbo.SalesCol
    WITH (DROP_EXISTING = ON, MAXDOP = 1);
GO
-- SQL Server 2022+: то же короче
-- CREATE CLUSTERED COLUMNSTORE INDEX CCI_SalesCol ON dbo.SalesCol
--     ORDER (SaleDate) WITH (DROP_EXISTING = ON, MAXDOP = 1);

SET STATISTICS IO ON;
SELECT StoreID, SUM(Amount) AS Amount
FROM dbo.SalesCol
WHERE SaleDate >= '2024-06-01'
GROUP BY StoreID;          -- теперь в Messages заметное «segment skipped»
SET STATISTICS IO OFF;
GO

-- ---------------------------------------------------------------------
-- 7. Deltastore: мелкие вставки не сжимаются сразу
-- ---------------------------------------------------------------------
INSERT INTO dbo.SalesCol (SaleDate, ProductID, StoreID, Amount)
VALUES ('2024-12-31', 1, 1, 100.00),
       ('2024-12-31', 2, 1, 200.00),
       ('2024-12-31', 3, 2, 300.00);

-- Появилась группа в состоянии OPEN — это B-дерево (deltastore)
SELECT row_group_id, state_desc, total_rows, deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.SalesCol')
ORDER BY row_group_id;

-- Удаление не переписывает сжатую группу — растёт deleted_rows
DELETE FROM dbo.SalesCol WHERE SaleDate = '2022-01-01';

SELECT row_group_id, state_desc, total_rows, deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.SalesCol') AND deleted_rows > 0;

-- Принудительно сжать открытые группы и вычистить удалённые строки
ALTER INDEX CCI_SalesCol ON dbo.SalesCol
    REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

SELECT row_group_id, state_desc, total_rows, deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.SalesCol')
ORDER BY row_group_id;
GO

-- ---------------------------------------------------------------------
-- 8. Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE dbo.SalesRow;
-- DROP TABLE dbo.SalesCol;

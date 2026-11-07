/* =====================================================================
   Некластерный columnstore (NCCI) поверх обычной таблицы
   К разделу 2.5 методички (docs/02-mssql.md)

   Требуется: SQL Server 2016 SP1+ (подходят Developer и Express).
   Часть 7 (batch mode on rowstore) — SQL Server 2019+, Enterprise или
   Developer, уровень совместимости базы 150+.
   Запускать в ОТДЕЛЬНОЙ тестовой базе, не в базе 1С.
   В SSMS включите «Include Actual Execution Plan» (Ctrl+M).
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 0. Тестовая база
-- ---------------------------------------------------------------------
-- CREATE DATABASE NcciDemo;
-- GO
-- USE NcciDemo;
-- GO

DROP TABLE IF EXISTS dbo.Sales;
GO

-- ---------------------------------------------------------------------
-- 1. Обычная OLTP-таблица: кластерный B-tree по ID + индекс по дате
--    (похоже на таблицу движений регистра: ключ + период + измерения)
-- ---------------------------------------------------------------------
CREATE TABLE dbo.Sales (
    ID        bigint IDENTITY  NOT NULL,
    SaleDate  date             NOT NULL,
    StoreID   int              NOT NULL,
    ProductID int              NOT NULL,
    Qty       int              NOT NULL,
    Amount    decimal(18,2)    NOT NULL,
    Comment   nvarchar(max)    NULL,          -- (max) в NCCI включить нельзя
    CONSTRAINT PK_Sales PRIMARY KEY CLUSTERED (ID)
);

INSERT INTO dbo.Sales WITH (TABLOCK) (SaleDate, StoreID, ProductID, Qty, Amount)
SELECT TOP (3000000)
       DATEADD(day, ABS(CHECKSUM(NEWID())) % 1095, '2023-01-01'),
       ABS(CHECKSUM(NEWID())) % 50,
       ABS(CHECKSUM(NEWID())) % 5000,
       1 + ABS(CHECKSUM(NEWID())) % 10,
       ABS(CHECKSUM(NEWID())) % 100000 / 100.0
FROM sys.all_objects AS a
CROSS JOIN sys.all_objects AS b;

CREATE INDEX IX_Sales_SaleDate ON dbo.Sales (SaleDate);
GO

-- ---------------------------------------------------------------------
-- 2. Аналитический запрос ДО колоночного индекса
--    Ожидаемо: Clustered Index Scan, Actual Execution Mode = Row
--    (на 2019+ Enterprise может включиться batch mode on rowstore — см. часть 6)
-- ---------------------------------------------------------------------
SET STATISTICS IO, TIME ON;

SELECT StoreID, SUM(Amount) AS Total, COUNT(*) AS Cnt
FROM dbo.Sales
WHERE SaleDate >= '2025-01-01'
GROUP BY StoreID;

SET STATISTICS IO, TIME OFF;
GO

-- ---------------------------------------------------------------------
-- 3. Добавляем NCCI — таблицу НЕ пересоздаём, B-деревья остаются
-- ---------------------------------------------------------------------
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Sales
ON dbo.Sales (SaleDate, StoreID, ProductID, Qty, Amount);
-- ONLINE = ON — SQL Server 2017+, Enterprise/Developer:
-- CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Sales
-- ON dbo.Sales (SaleDate, StoreID, ProductID, Qty, Amount) WITH (ONLINE = ON);
GO

-- Попытка включить колонку (max) — ошибка (раскомментируйте, чтобы увидеть)
-- CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Bad ON dbo.Sales (Comment);

-- Второй columnstore-индекс на ту же таблицу создать нельзя (ошибка)
-- CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Second ON dbo.Sales (Qty);

-- Индексы таблицы: кластерный B-tree, некластерный B-tree и NCCI рядом
SELECT i.name, i.type_desc
FROM sys.indexes AS i
WHERE i.object_id = OBJECT_ID('dbo.Sales');
GO

-- ---------------------------------------------------------------------
-- 4. Оптимизатор сам выбирает структуру под запрос
-- ---------------------------------------------------------------------
SET STATISTICS IO, TIME ON;

-- 4.1. Агрегат по большому объёму → Columnstore Index Scan, режим Batch,
--      в Messages: "segment reads N, segment skipped M"
SELECT StoreID, SUM(Amount) AS Total, COUNT(*) AS Cnt
FROM dbo.Sales
WHERE SaleDate >= '2025-01-01'
GROUP BY StoreID;

-- 4.2. Точечный поиск по ключу → Clustered Index Seek (B-tree), NCCI не нужен
SELECT * FROM dbo.Sales WHERE ID = 123456;

-- 4.3. Узкий диапазон дат → Index Seek по IX_Sales_SaleDate + Key Lookup
SELECT ID, Amount FROM dbo.Sales WHERE SaleDate = '2024-03-15' AND StoreID = 7;

SET STATISTICS IO, TIME OFF;
GO

-- Сжатые группы строк NCCI
SELECT row_group_id, state_desc, total_rows, deleted_rows, trim_reason_desc
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.Sales')
ORDER BY row_group_id;
GO

-- ---------------------------------------------------------------------
-- 5. Что происходит с NCCI при INSERT / UPDATE / DELETE
-- ---------------------------------------------------------------------
-- 5.1. Мелкие вставки → deltastore (группа OPEN)
INSERT INTO dbo.Sales (SaleDate, StoreID, ProductID, Qty, Amount)
VALUES ('2025-12-31', 1, 1, 1, 10.00),
       ('2025-12-31', 2, 2, 2, 20.00);

-- 5.2. Удаление и обновление строк из СЖАТЫХ групп → delete buffer
DELETE FROM dbo.Sales WHERE ID BETWEEN 1 AND 1000;
UPDATE dbo.Sales SET Amount = Amount + 1 WHERE ID BETWEEN 2001 AND 2100;

-- Внутренние структуры NCCI: delta store, delete buffer, delete bitmap
SELECT ip.internal_object_type_desc, ip.row_group_id, ip.rows
FROM sys.internal_partitions AS ip
WHERE ip.object_id = OBJECT_ID('dbo.Sales')
ORDER BY ip.internal_object_type_desc, ip.row_group_id;
-- Ожидаемо: COLUMN_STORE_DELTA_STORE с 2 + 100 строками (вставки и новые версии
-- после UPDATE), COLUMN_STORE_DELETE_BUFFER с ~1 100 строками (удаления и старые
-- версии). Delete bitmap пополнится, когда фоновый процесс перенесёт буфер
-- (или после REORGANIZE).

-- Состояние групп: OPEN-группа deltastore рядом со сжатыми
SELECT row_group_id, state_desc, total_rows, deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('dbo.Sales')
ORDER BY row_group_id;

-- 5.3. Обслуживание: сжать OPEN-группы, перенести delete buffer в bitmap,
--      вычистить группы с большой долей удалённых строк
ALTER INDEX NCCI_Sales ON dbo.Sales
    REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

SELECT ip.internal_object_type_desc, ip.row_group_id, ip.rows
FROM sys.internal_partitions AS ip
WHERE ip.object_id = OBJECT_ID('dbo.Sales')
ORDER BY ip.internal_object_type_desc, ip.row_group_id;
GO

-- ---------------------------------------------------------------------
-- 6. Фильтрованный NCCI и COMPRESSION_DELAY — меньше влияния на OLTP
-- ---------------------------------------------------------------------
DROP INDEX NCCI_Sales ON dbo.Sales;
GO

-- Колоночная копия только «остывших» данных; изменения свежих строк её не трогают.
-- Задержка сжатия: CLOSED-группа сжимается не раньше чем через 30 минут.
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Sales_Cold
ON dbo.Sales (SaleDate, StoreID, ProductID, Qty, Amount)
WHERE SaleDate < '2025-07-01'
WITH (COMPRESSION_DELAY = 30 MINUTES);
GO

SET STATISTICS IO, TIME ON;

-- Отбор целиком в «холодной» зоне — NCCI подходит
SELECT StoreID, SUM(Amount) AS Total
FROM dbo.Sales
WHERE SaleDate < '2025-01-01'
GROUP BY StoreID;

-- Весь период — посмотрите в плане, как оптимизатор поступил: «холодная» часть
-- из NCCI + «горячая» через B-tree по дате, или обычный скан таблицы
SELECT StoreID, SUM(Amount) AS Total
FROM dbo.Sales
GROUP BY StoreID;

SET STATISTICS IO, TIME OFF;
GO

-- Свежая вставка в «горячую» зону NCCI не затрагивает вовсе
INSERT INTO dbo.Sales (SaleDate, StoreID, ProductID, Qty, Amount)
VALUES ('2025-12-31', 3, 3, 3, 30.00);

SELECT ip.internal_object_type_desc, ip.rows
FROM sys.internal_partitions AS ip
WHERE ip.object_id = OBJECT_ID('dbo.Sales');
GO

-- ---------------------------------------------------------------------
-- 7. Batch mode on rowstore (SQL Server 2019+, Enterprise/Developer,
--    уровень совместимости 150+) — пакетная обработка БЕЗ columnstore
-- ---------------------------------------------------------------------
DROP INDEX NCCI_Sales_Cold ON dbo.Sales;
GO

SELECT name, compatibility_level FROM sys.databases WHERE name = DB_NAME();
-- ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 150;

-- Свойства оператора (F4) → Actual Execution Mode = Batch при Clustered Index Scan
SELECT StoreID, ProductID % 10 AS Grp, SUM(Amount) AS Total, COUNT(*) AS Cnt
FROM dbo.Sales
GROUP BY StoreID, ProductID % 10;

-- Тот же запрос с запретом batch mode — сравните CPU в STATISTICS TIME
SET STATISTICS TIME ON;
SELECT StoreID, ProductID % 10 AS Grp, SUM(Amount) AS Total, COUNT(*) AS Cnt
FROM dbo.Sales
GROUP BY StoreID, ProductID % 10;

SELECT StoreID, ProductID % 10 AS Grp, SUM(Amount) AS Total, COUNT(*) AS Cnt
FROM dbo.Sales
GROUP BY StoreID, ProductID % 10
OPTION (USE HINT('DISALLOW_BATCH_MODE'));
SET STATISTICS TIME OFF;
GO

-- ---------------------------------------------------------------------
-- 8. Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE dbo.Sales;

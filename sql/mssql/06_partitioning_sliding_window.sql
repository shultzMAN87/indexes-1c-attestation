/*
    MS SQL Server: секционирование, выровненные индексы и скользящее окно
    Методичка: docs/04-sekcionirovanie.md, разделы 4.1–4.3

    Запускать ТОЛЬКО в тестовой базе. Скрипт создаёт и удаляет свои объекты.
    Не применять к таблицам базы 1С: платформа не поддерживает секционирование.
*/

-- 0. Очистка от прошлых запусков
IF OBJECT_ID('dbo.Orders') IS NOT NULL DROP TABLE dbo.Orders;
IF OBJECT_ID('dbo.Orders_Stage') IS NOT NULL DROP TABLE dbo.Orders_Stage;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'psOrders') DROP PARTITION SCHEME psOrders;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pfOrders') DROP PARTITION FUNCTION pfOrders;
GO

-- 1. Функция и схема секционирования: по месяцам, RANGE RIGHT
--    Секции: 1: < 01.01 (пустая) | 2: январь | 3: февраль | 4: март | 5: >= 01.04 (пустая)
CREATE PARTITION FUNCTION pfOrders (datetime2(0))
AS RANGE RIGHT FOR VALUES ('2024-01-01', '2024-02-01', '2024-03-01', '2024-04-01');
GO
CREATE PARTITION SCHEME psOrders AS PARTITION pfOrders ALL TO ([PRIMARY]);
GO

-- 2. Секционированная таблица. Колонка секционирования входит в первичный ключ —
--    иначе уникальный кластерный индекс не может быть выровненным.
CREATE TABLE dbo.Orders (
    OrderID    bigint        NOT NULL,
    OrderDate  datetime2(0)  NOT NULL,
    CustomerID int           NOT NULL,
    Amount     decimal(18,2) NULL,
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID, OrderDate)
) ON psOrders(OrderDate);
GO

-- Некластерный индекс: по умолчанию создаётся выровненным (на той же схеме)
CREATE INDEX IX_Orders_Customer ON dbo.Orders (CustomerID);
GO

-- Невыровненный (глобальный) индекс выглядел бы так — и он запретил бы SWITCH:
-- CREATE INDEX IX_Orders_Customer_Global ON dbo.Orders (CustomerID) ON [PRIMARY];

-- 3. Тестовые данные: январь–март
INSERT INTO dbo.Orders (OrderID, OrderDate, CustomerID, Amount)
SELECT TOP (90000)
       ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
       DATEADD(MINUTE, ABS(CHECKSUM(NEWID())) % (90 * 1440), '2024-01-01'),
       ABS(CHECKSUM(NEWID())) % 1000,
       ABS(CHECKSUM(NEWID())) % 100000 / 100.0
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;
GO

-- 4. Как данные легли по секциям
SELECT p.partition_number, prv.value AS lower_boundary, p.rows
FROM sys.partitions AS p
JOIN sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
LEFT JOIN sys.partition_range_values AS prv
       ON prv.function_id = (SELECT function_id FROM sys.partition_functions WHERE name = 'pfOrders')
      AND prv.boundary_id = p.partition_number - 1
WHERE p.object_id = OBJECT_ID('dbo.Orders') AND i.index_id = 1
ORDER BY p.partition_number;

-- Выровнены ли индексы: у всех должна быть одна и та же схема секционирования
SELECT i.name AS index_name, ds.name AS data_space, ds.type_desc
FROM sys.indexes AS i
JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
WHERE i.object_id = OBJECT_ID('dbo.Orders');
GO

-- 5. Отсечение секций: сравните "Actual Partition Count" в фактическом плане
--    и Scan count в STATISTICS IO
SET STATISTICS IO ON;
SELECT * FROM dbo.Orders
WHERE OrderDate >= '2024-02-01' AND OrderDate < '2024-03-01' AND OrderID = 42;   -- одна секция
SELECT * FROM dbo.Orders WHERE OrderID = 42;                                      -- все секции
SET STATISTICS IO OFF;
GO

-- 6. Stage-таблица для выгрузки: та же структура, те же индексы, та же файловая группа
CREATE TABLE dbo.Orders_Stage (
    OrderID    bigint        NOT NULL,
    OrderDate  datetime2(0)  NOT NULL,
    CustomerID int           NOT NULL,
    Amount     decimal(18,2) NULL,
    CONSTRAINT PK_Orders_Stage PRIMARY KEY CLUSTERED (OrderID, OrderDate)
) ON [PRIMARY];
CREATE INDEX IX_Orders_Stage_Customer ON dbo.Orders_Stage (CustomerID);
GO

/* 7. Скользящее окно */

-- 7.1. Выгрузить январь (секция 2) — операция над метаданными
ALTER TABLE dbo.Orders SWITCH PARTITION 2 TO dbo.Orders_Stage;
SELECT COUNT(*) AS rows_in_stage FROM dbo.Orders_Stage;
-- дальше: выгрузить Orders_Stage в архив и TRUNCATE TABLE dbo.Orders_Stage;

-- 7.2. Убрать границу 01.01: секции 1 и 2 пусты → мгновенно
ALTER PARTITION FUNCTION pfOrders() MERGE RANGE ('2024-01-01');

-- 7.3. Добавить границу для мая: правая секция (>= 01.04) пуста → мгновенно
ALTER PARTITION SCHEME psOrders NEXT USED [PRIMARY];
ALTER PARTITION FUNCTION pfOrders() SPLIT RANGE ('2024-05-01');
GO

-- 8. Обслуживание одной секции (только текущей)
ALTER INDEX PK_Orders ON dbo.Orders REBUILD PARTITION = 3;
GO

-- 9. Проверка результата
SELECT p.partition_number, prv.value AS lower_boundary, p.rows
FROM sys.partitions AS p
LEFT JOIN sys.partition_range_values AS prv
       ON prv.function_id = (SELECT function_id FROM sys.partition_functions WHERE name = 'pfOrders')
      AND prv.boundary_id = p.partition_number - 1
WHERE p.object_id = OBJECT_ID('dbo.Orders') AND p.index_id = 1
ORDER BY p.partition_number;

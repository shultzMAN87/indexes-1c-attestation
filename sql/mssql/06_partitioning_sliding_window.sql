/*
    MS SQL Server: секционирование, выровненные индексы и скользящее окно
    Методичка: docs/04-sekcionirovanie.md, разделы 4.1, 4.1a, 4.3

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

-- 5a. Номер секции для значения (раздел 4.0): 01.02 при RANGE RIGHT — начало февральской секции 3
SELECT $PARTITION.pfOrders('2024-01-31T23:59:59') AS jan,   -- 2
       $PARTITION.pfOrders('2024-02-01')          AS feb,   -- 3
       $PARTITION.pfOrders('2023-12-31')          AS before_jan;  -- 1
GO

-- 5b. Функция над колонкой ломает отсечение (раздел 4.6): сравните Actual Partition Count
SELECT COUNT(*) FROM dbo.Orders WHERE MONTH(OrderDate) = 2;                               -- все секции
SELECT COUNT(*) FROM dbo.Orders WHERE OrderDate >= '2024-02-01' AND OrderDate < '2024-03-01';  -- одна
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

-- 7.0. Кому принадлежат наборы страниц ДО SWITCH (раздел 4.1a): запомните hobt_id
--      секции 2 таблицы Orders и единственного набора Orders_Stage
SELECT OBJECT_NAME(object_id) AS table_name, partition_number, hobt_id, rows
FROM sys.partitions
WHERE object_id IN (OBJECT_ID('dbo.Orders'), OBJECT_ID('dbo.Orders_Stage')) AND index_id = 1
ORDER BY table_name, partition_number;

-- 7.1. Выгрузить январь (секция 2) — операция над метаданными.
--      WAIT_AT_LOW_PRIORITY: если таблицу держит долгий запрос, не собирать за собой очередь,
--      а через минуту отменить SWITCH (SQL Server 2014+).
ALTER TABLE dbo.Orders SWITCH PARTITION 2 TO dbo.Orders_Stage
WITH (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF));
SELECT COUNT(*) AS rows_in_stage FROM dbo.Orders_Stage;

-- ПОСЛЕ SWITCH: ожидаемо hobt_id бывшей секции 2 теперь у Orders_Stage,
-- а у секции 2 — бывший пустой набор Orders_Stage. Строки не копировались.
SELECT OBJECT_NAME(object_id) AS table_name, partition_number, hobt_id, rows
FROM sys.partitions
WHERE object_id IN (OBJECT_ID('dbo.Orders'), OBJECT_ID('dbo.Orders_Stage')) AND index_id = 1
ORDER BY table_name, partition_number;
GO

-- 7.1a. Обратное направление — загрузка таблицы в пустую секцию 2 (раздел 4.1a).
--       Без CHECK на источнике SQL Server не знает, что все строки — январские: ошибка 4972.
BEGIN TRY
    ALTER TABLE dbo.Orders_Stage SWITCH TO dbo.Orders PARTITION 2;
END TRY
BEGIN CATCH
    PRINT CONCAT('Ошибка ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;

-- Доверенный CHECK точно по границам секции 2 (RANGE RIGHT: [01.01; 01.02)) → SWITCH проходит
ALTER TABLE dbo.Orders_Stage WITH CHECK
    ADD CONSTRAINT CK_Orders_Stage_Jan CHECK (OrderDate >= '2024-01-01' AND OrderDate < '2024-02-01');
SELECT name, is_not_trusted, is_disabled FROM sys.check_constraints
WHERE parent_object_id = OBJECT_ID('dbo.Orders_Stage');            -- нужно 0 и 0

ALTER TABLE dbo.Orders_Stage SWITCH TO dbo.Orders PARTITION 2;
SELECT COUNT(*) AS rows_back_in_partition_2 FROM dbo.Orders WHERE $PARTITION.pfOrders(OrderDate) = 2;

-- И снова выгрузить январь для ротации. CHECK на приёмнике не мешает:
-- диапазон секции 2 совпадает с ним (SQL Server сверяет границы, а не строки).
ALTER TABLE dbo.Orders SWITCH PARTITION 2 TO dbo.Orders_Stage;
-- дальше: выгрузить Orders_Stage в архив и TRUNCATE TABLE dbo.Orders_Stage;
GO

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

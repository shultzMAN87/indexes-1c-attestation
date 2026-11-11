-- =============================================================================
-- 14_json_index.sql — индексация JSON: вычисляемая колонка + B-tree и JSON-индекс
-- К разделу 2.5 методички (docs/02-mssql.md), подраздел «JSON-индекс».
--
-- Что показывает:
--   Часть 1 (SQL Server 2016+): JSON в nvarchar(max), поиск по JSON_VALUE —
--     сканирование; вычисляемая колонка + обычный B-tree — Index Seek без
--     переписывания запроса.
--   Часть 2 (SQL Server 2025): тип json, CREATE JSON INDEX по нескольким путям,
--     поиск по значению, по наличию пути и по элементу массива; путь вне индекса.
--
-- Создаёт и удаляет отдельную базу demo_json. Часть 2 на версиях до 2025
-- не выполняется (SET NOEXEC ON), но SSMS покажет по ней ошибки разбора — это ожидаемо;
-- можно просто запускать часть 1 и уборку. Запускать по частям; в SSMS включите
-- «Include Actual Execution Plan» (Ctrl+M).
-- =============================================================================

USE master;
GO
IF DB_ID(N'demo_json') IS NOT NULL
BEGIN
    ALTER DATABASE demo_json SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_json;
END;
GO
CREATE DATABASE demo_json;
GO
USE demo_json;
GO

-- =============================================================================
-- ЧАСТЬ 1. Любая версия с 2016: JSON в nvarchar(max)
-- =============================================================================
CREATE TABLE dbo.OrdersText
(
    Id   int IDENTITY  NOT NULL CONSTRAINT PK_OrdersText PRIMARY KEY CLUSTERED,
    Info nvarchar(max) NOT NULL CONSTRAINT CK_OrdersText_IsJson CHECK (ISJSON(Info) = 1)
);

-- 200 000 заказов: покупатель (у каждого десятого — признак vip), статус,
-- массив тегов (у каждого пятидесятого — 'gift') и строки товаров.
INSERT INTO dbo.OrdersText WITH (TABLOCK) (Info)
SELECT TOP (200000)
       N'{"customer":{"id":' + CAST(n % 5000 AS nvarchar(10))
     + CASE WHEN n % 10 = 0 THEN N',"vip":true' ELSE N'' END + N'},'
     + N'"status":"' + CASE n % 4 WHEN 0 THEN N'new' WHEN 1 THEN N'paid' WHEN 2 THEN N'shipped' ELSE N'closed' END + N'",'
     + N'"tags":[' + CASE WHEN n % 50 = 0 THEN N'"gift",' ELSE N'' END + N'"web"],'
     + N'"items":[{"sku":"A' + CAST(n % 997 AS nvarchar(10)) + N'","qty":' + CAST(n % 5 + 1 AS nvarchar(10)) + N'}]}'
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
      FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b) AS t;
GO

SELECT TOP (3) Id, Info FROM dbo.OrdersText;
GO

-- 1.1. Без индекса: JSON разбирается в каждой строке.
SET STATISTICS IO ON;
SELECT Id FROM dbo.OrdersText WHERE CAST(JSON_VALUE(Info, '$.customer.id') AS int) = 42;
SET STATISTICS IO OFF;
-- В плане: Clustered Index Scan + Compute Scalar + Filter; logical reads — вся таблица.
GO

-- 1.2. Вычисляемая колонка с тем же выражением + обычный B-tree.
--      Колонка не хранится (не PERSISTED): значение вычисляется при записи в индекс.
ALTER TABLE dbo.OrdersText ADD CustomerId AS CAST(JSON_VALUE(Info, '$.customer.id') AS int);
CREATE INDEX IX_OrdersText_CustomerId ON dbo.OrdersText (CustomerId);
GO

SET STATISTICS IO ON;
-- Запрос НЕ переписан: оптимизатор сам сопоставил выражение с вычисляемой колонкой.
SELECT Id FROM dbo.OrdersText WHERE CAST(JSON_VALUE(Info, '$.customer.id') AS int) = 42;
-- Выражение другое (без CAST) — сопоставления нет, снова Scan.
SELECT Id FROM dbo.OrdersText WHERE JSON_VALUE(Info, '$.customer.id') = N'42';
SET STATISTICS IO OFF;
-- Ожидаемо: первый запрос — Index Seek по IX_OrdersText_CustomerId, десятки чтений;
-- второй — Clustered Index Scan. Выражение в запросе должно совпадать с колонкой.
-- Минус подхода: одна колонка — одно значение; под каждый путь нужна своя колонка и индекс.
GO

-- =============================================================================
-- ЧАСТЬ 2. SQL Server 2025: тип json и CREATE JSON INDEX
-- =============================================================================
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
BEGIN
    PRINT N'Часть 2 требует SQL Server 2025 (17.x) — пропускаем до уборки.';
    PRINT N'Сообщения о синтаксических ошибках ниже (тип json, CREATE JSON INDEX) ожидаемы — их можно не читать.';
    SET NOEXEC ON;     -- следующие пакеты только разбираются, но не выполняются
END;
GO

-- Если CREATE JSON INDEX ниже завершится ошибкой о preview-возможности, включите:
-- ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;

-- JSON-индексу нужен кластерный первичный ключ и колонка типа json.
CREATE TABLE dbo.OrdersJson
(
    Id   int  NOT NULL CONSTRAINT PK_OrdersJson PRIMARY KEY CLUSTERED,
    Info json NOT NULL
);
INSERT INTO dbo.OrdersJson WITH (TABLOCK) (Id, Info)
SELECT Id, CAST(Info AS json) FROM dbo.OrdersText;
GO

-- 2.1. Те же запросы без индекса — для сравнения.
SET STATISTICS IO ON;
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_VALUE(Info, '$.customer.id' RETURNING int) = 42;
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_PATH_EXISTS(Info, '$.customer.vip') = 1;
SET STATISTICS IO OFF;
GO

-- 2.2. Один индекс на несколько путей. Пути индексируются рекурсивно вниз
--      и не должны перекрываться ('$.customer' и '$.customer.id' вместе нельзя).
--      Создание только офлайн: на время построения таблица заблокирована (Sch-M).
CREATE JSON INDEX JX_OrdersJson_Info ON dbo.OrdersJson (Info)
    FOR ('$.customer', '$.status', '$.tags')
    WITH (OPTIMIZE_FOR_ARRAY_SEARCH = ON);      -- для поиска по элементам массивов
GO

SELECT * FROM sys.json_indexes WHERE object_id = OBJECT_ID(N'dbo.OrdersJson');
-- Внутренняя таблица индекса (пути и значения → ключ строки):
SELECT it.name, it.internal_type_desc FROM sys.internal_tables AS it WHERE it.parent_id = OBJECT_ID(N'dbo.OrdersJson');
GO

SET STATISTICS IO ON;
-- 2.3. Равенство по значению на пути
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_VALUE(Info, '$.customer.id' RETURNING int) = 42;
-- 2.4. Наличие пути (vip есть у каждого десятого)
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_PATH_EXISTS(Info, '$.customer.vip') = 1;
-- 2.5. Значение строки
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_VALUE(Info, '$.status') = 'paid';
-- 2.6. Элемент массива: теги содержат 'gift'
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_CONTAINS(Info, 'gift', '$.tags') = 1;
-- 2.7. Путь, которого нет в индексе ('$.items' не перечислен в FOR) — индекс не поможет
SELECT COUNT(*) FROM dbo.OrdersJson WHERE JSON_VALUE(Info, '$.items[0].sku') = 'A17';
SET STATISTICS IO OFF;
-- Сравните планы и logical reads с 2.1. Индекс поддерживает «=» (а также IN и диапазон
-- с RETURNING числового типа) в JSON_VALUE, JSON_PATH_EXISTS(...) = 1 и JSON_CONTAINS.
-- LIKE и IS NULL по JSON_VALUE индекс не использует. Синтаксис ещё развивается —
-- сверяйтесь с документацией CREATE JSON INDEX под свою сборку.
GO

SET NOEXEC OFF;
GO

-- -----------------------------------------------------------------------------
-- Уборка
-- -----------------------------------------------------------------------------
USE master;
GO
ALTER DATABASE demo_json SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE demo_json;
GO

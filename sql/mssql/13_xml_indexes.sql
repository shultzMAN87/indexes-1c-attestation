-- =============================================================================
-- 13_xml_indexes.sql — XML-индексы: таблица узлов, PATH / VALUE / PROPERTY, selective
-- К разделу 2.5 методички (docs/02-mssql.md), подраздел «XML-индексы».
--
-- Что показывает:
--   1. 50 000 заказов в колонке xml; запросы XQuery без индексов.
--   2. Primary XML index — скрытая таблица узлов: сколько в ней строк и места.
--   3. Вторичные PATH и VALUE: какой под какой запрос; планы.
--   4. Selective XML index по двум путям — во сколько раз меньше primary.
--
-- Требуется: SQL Server 2012 SP1+ (selective XML index; в 2012 SP1 его надо было
-- включать процедурой sp_db_selective_xml_index, с 2014 — включён).
-- Создаёт и удаляет отдельную базу demo_xml. Запускать по частям; в SSMS
-- включите «Include Actual Execution Plan» (Ctrl+M).
-- =============================================================================

USE master;
GO
IF DB_ID(N'demo_xml') IS NOT NULL
BEGIN
    ALTER DATABASE demo_xml SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_xml;
END;
GO
CREATE DATABASE demo_xml;
GO
USE demo_xml;
GO

-- -----------------------------------------------------------------------------
-- 1. Данные. XML-индексам нужен кластерный первичный ключ.
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Orders
(
    Id  int IDENTITY NOT NULL CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED,
    Doc xml          NOT NULL
);

-- Заказ: покупатель, статус и три строки товаров.
INSERT INTO dbo.Orders WITH (TABLOCK) (Doc)
SELECT TOP (50000)
       CAST(N'<order id="' + CAST(n AS nvarchar(10)) + N'" status="' + CASE n % 4 WHEN 0 THEN N'new' WHEN 1 THEN N'paid' WHEN 2 THEN N'shipped' ELSE N'closed' END + N'">'
          + N'<customer>Клиент ' + CAST(n % 3000 AS nvarchar(10)) + N'</customer>'
          + N'<item sku="A' + CAST(n % 997 AS nvarchar(10)) + N'" qty="' + CAST(n % 5 + 1 AS nvarchar(10)) + N'"/>'
          + N'<item sku="B' + CAST(n % 991 AS nvarchar(10)) + N'" qty="1"/>'
          + N'<item sku="C' + CAST(n % 983 AS nvarchar(10)) + N'" qty="2"/>'
          + N'</order>' AS xml)
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
      FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b) AS t;
GO

-- Процедура замера: размер таблицы и скрытых таблиц XML-индексов.
CREATE OR ALTER PROCEDURE dbo.ShowXmlSizes @step nvarchar(100)
AS
SELECT @step AS step, N'dbo.Orders (сами XML)' AS object_, SUM(ps.row_count) AS rows_, SUM(ps.used_page_count) * 8 AS used_kb
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = OBJECT_ID(N'dbo.Orders')
UNION ALL
SELECT @step, i.name + N' → ' + it.name, SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count END), SUM(ps.used_page_count) * 8
FROM sys.internal_tables AS it
JOIN sys.indexes AS i ON i.object_id = it.parent_id AND i.index_id = it.parent_minor_id
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = it.object_id
WHERE it.parent_id = OBJECT_ID(N'dbo.Orders')
GROUP BY i.name, it.name;
GO
EXEC dbo.ShowXmlSizes N'1. Без XML-индексов';
GO

-- -----------------------------------------------------------------------------
-- 2. Запросы без индексов: XML разбирается заново для каждой строки
-- -----------------------------------------------------------------------------
SET STATISTICS TIME ON;
-- Q1. Известен путь: заказы, где есть товар A17.
SELECT COUNT(*) AS q1 FROM dbo.Orders WHERE Doc.exist(N'/order/item[@sku="A17"]') = 1;
-- Q2. Известно значение, путь — с «//»: где угодно атрибут sku = A17.
SELECT COUNT(*) AS q2 FROM dbo.Orders WHERE Doc.exist(N'//*[@sku="A17"]') = 1;
-- Q3. Значения из одной известной строки.
SELECT Doc.value(N'(/order/customer)[1]', N'nvarchar(50)') AS customer,
       Doc.value(N'(/order/@status)[1]', N'nvarchar(20)')  AS status
FROM dbo.Orders WHERE Id = 4242;
SET STATISTICS TIME OFF;
-- В плане Q1 и Q2: Clustered Index Scan + Table Valued Function [XML Reader with XPath filter]
-- для каждой строки — XML читается и разбирается на лету.
GO

-- -----------------------------------------------------------------------------
-- 3. Primary XML index: таблица узлов
-- -----------------------------------------------------------------------------
CREATE PRIMARY XML INDEX PXML_Orders_Doc ON dbo.Orders (Doc);
GO
EXEC dbo.ShowXmlSizes N'3. Primary XML index';
-- Ожидаемо: во внутренней таблице (xml_index_nodes_…) около 14 строк на заказ:
-- элементы, атрибуты, текстовые узлы. Размер — того же порядка, что сами XML, или больше.

SELECT internal_type_desc, name FROM sys.internal_tables WHERE parent_id = OBJECT_ID(N'dbo.Orders');
GO

SET STATISTICS TIME ON;
SELECT COUNT(*) AS q1 FROM dbo.Orders WHERE Doc.exist(N'/order/item[@sku="A17"]') = 1;
SET STATISTICS TIME OFF;
-- В плане: Clustered Index Scan / Seek по таблице узлов (PXML_Orders_Doc) вместо разбора XML.
-- Сканирование таблицы узлов всё равно идёт — для поиска по пути нужен вторичный PATH.
GO

-- -----------------------------------------------------------------------------
-- 4. Вторичные XML-индексы
-- -----------------------------------------------------------------------------
-- PATH: B-tree по (путь, значение) — для запросов с известным путём (Q1).
CREATE XML INDEX IXML_Orders_Path ON dbo.Orders (Doc) USING XML INDEX PXML_Orders_Doc FOR PATH;
-- VALUE: B-tree по (значение, путь) — для «//» и «*», когда известно значение (Q2).
CREATE XML INDEX IXML_Orders_Value ON dbo.Orders (Doc) USING XML INDEX PXML_Orders_Doc FOR VALUE;
-- PROPERTY: B-tree по (PK, путь, значение) — достать значения из известной строки (Q3).
CREATE XML INDEX IXML_Orders_Property ON dbo.Orders (Doc) USING XML INDEX PXML_Orders_Doc FOR PROPERTY;
GO
EXEC dbo.ShowXmlSizes N'4. Primary + PATH + VALUE + PROPERTY';
-- Вторичные индексы лежат на той же внутренней таблице — её размер вырос ещё.
GO

SET STATISTICS TIME ON;
SELECT COUNT(*) AS q1 FROM dbo.Orders WHERE Doc.exist(N'/order/item[@sku="A17"]') = 1;   -- ищите Index Seek по IXML_Orders_Path
SELECT COUNT(*) AS q2 FROM dbo.Orders WHERE Doc.exist(N'//*[@sku="A17"]') = 1;           -- ищите Index Seek по IXML_Orders_Value
SELECT Doc.value(N'(/order/customer)[1]', N'nvarchar(50)') AS customer
FROM dbo.Orders WHERE Id = 4242;                                                          -- PROPERTY или Seek по primary
SET STATISTICS TIME OFF;
-- Какой вторичный индекс возьмёт оптимизатор, решает он сам по оценке;
-- важно увидеть Index Seek по таблице узлов вместо разбора каждого документа.
GO

-- -----------------------------------------------------------------------------
-- 5. Selective XML index: только нужные пути
-- -----------------------------------------------------------------------------
-- Сначала убираем обычные XML-индексы (вторичные удалятся вместе с primary).
DROP INDEX PXML_Orders_Doc ON dbo.Orders;
GO
CREATE SELECTIVE XML INDEX SXI_Orders_Doc ON dbo.Orders (Doc)
FOR
(
    sku    = '/order/item/@sku'  AS SQL nvarchar(20),
    status = '/order/@status'    AS SQL nvarchar(20) SINGLETON   -- SINGLETON: одно значение на документ
);
-- Вторичный selective-индекс по одному из путей — для поиска по значению.
CREATE XML INDEX SXI_Orders_Doc_Sku ON dbo.Orders (Doc) USING XML INDEX SXI_Orders_Doc FOR (sku);
GO
EXEC dbo.ShowXmlSizes N'5. Selective XML index (2 пути)';
-- Ожидаемо: в разы меньше primary — хранятся только 2 пути из ~15 узлов заказа,
-- и значения уже типизированы (nvarchar), а не как текст узлов.

SET STATISTICS TIME ON;
SELECT COUNT(*) AS q1 FROM dbo.Orders WHERE Doc.exist(N'/order/item[@sku="A17"]') = 1;
SELECT COUNT(*) AS by_status FROM dbo.Orders WHERE Doc.exist(N'/order[@status="paid"]') = 1;
SET STATISTICS TIME OFF;
-- Путь, которого нет в selective-индексе (например, /order/customer), индекс не ускорит.
GO

-- -----------------------------------------------------------------------------
-- 6. Уборка
-- -----------------------------------------------------------------------------
USE master;
GO
ALTER DATABASE demo_xml SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE demo_xml;
GO

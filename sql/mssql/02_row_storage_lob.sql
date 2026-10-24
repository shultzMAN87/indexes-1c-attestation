/* =====================================================================
   Как MS SQL хранит строки: страница, IN_ROW / ROW_OVERFLOW / LOB
   К разделу 2.9 методички (docs/02-mssql.md) и 5.11 (docs/05-1c.md)

   Требуется: SQL Server 2016+ (sys.dm_db_database_page_allocations — 2012+,
   недокументированная, но широко используемая функция).
   Запускать в ОТДЕЛЬНОЙ тестовой базе, не в базе 1С.
   ===================================================================== */

-- CREATE DATABASE StorageDemo;
-- GO
-- USE StorageDemo;
-- GO

DROP TABLE IF EXISTS dbo.DemoRow;
DROP TABLE IF EXISTS dbo.DemoLob;
DROP TABLE IF EXISTS dbo.DemoLegacy;
GO

-- =====================================================================
-- Часть 1. Обычная строка: как она лежит на странице
-- =====================================================================
CREATE TABLE dbo.DemoRow (
    ID    int           NOT NULL PRIMARY KEY CLUSTERED,
    Code  nvarchar(20)  NOT NULL,
    Price decimal(12,2) NOT NULL
);
INSERT INTO dbo.DemoRow (ID, Code, Price)
SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
       N'CODE-' + CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS nvarchar(10)),
       10.5
FROM sys.all_objects;
GO

-- Средний размер записи, сколько записей на странице, заполненность страниц
SELECT index_level, page_count, record_count,
       avg_record_size_in_bytes, min_record_size_in_bytes, max_record_size_in_bytes,
       avg_page_space_used_in_percent
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoRow'), 1, NULL, 'DETAILED');

-- Заглянуть в страницу: сначала найти номер листовой страницы
SELECT allocated_page_file_id AS file_id, allocated_page_page_id AS page_id,
       page_type_desc, page_level
FROM sys.dm_db_database_page_allocations(DB_ID(), OBJECT_ID('dbo.DemoRow'), 1, NULL, 'DETAILED')
WHERE is_allocated = 1 AND page_type_desc = 'DATA_PAGE'
ORDER BY allocated_page_page_id;

-- Подставьте file_id и page_id из результата выше:
-- DBCC TRACEON(3604);                    -- вывод DBCC PAGE в окно сообщений
-- DBCC PAGE ('StorageDemo', 1, 312, 3);  -- режим 3: заголовок + каждая запись по колонкам
-- В выводе: m_slotCnt — число записей, m_freeCnt — свободные байты,
-- «OFFSET TABLE» в конце — массив смещений записей (2 байта на запись)
GO

-- =====================================================================
-- Часть 2. Длинные значения: ROW_OVERFLOW_DATA и LOB_DATA
-- =====================================================================
CREATE TABLE dbo.DemoLob (
    ID     int            NOT NULL PRIMARY KEY CLUSTERED,
    Title  nvarchar(100)  NULL,
    Text1  nvarchar(4000) NULL,   -- до 8000 байт: «обычная» переменная колонка
    Text2  nvarchar(4000) NULL,
    Note   nvarchar(max)  NULL,   -- как строка неограниченной длины 1С (современные версии)
    Blob   varbinary(max) NULL    -- как ХранилищеЗначения 1С (современные версии)
);
GO

-- Строка 1: всё короткое — всё в строке (IN_ROW_DATA)
INSERT INTO dbo.DemoLob (ID, Title, Text1, Text2, Note, Blob)
VALUES (1, N'Короткая', N'abc', N'def', N'короткий текст', 0x0102);

-- Строка 2: Text1 + Text2 = 2 × 7000 байт > 8060 — строка не помещается на страницу.
-- Одна из колонок уходит на страницы ROW_OVERFLOW_DATA, в строке — указатель 24 байта
INSERT INTO dbo.DemoLob (ID, Title, Text1, Text2)
VALUES (2, N'Переполнение', REPLICATE(N'a', 3500), REPLICATE(N'b', 3500));

-- Строка 3: текст 200 КБ в nvarchar(max) — LOB_DATA
-- (REPLICATE возвращает максимум 8000 байт, если аргумент не (max) — поэтому CAST)
INSERT INTO dbo.DemoLob (ID, Title, Note)
VALUES (3, N'Текст 200 КБ', REPLICATE(CAST(N'Индексы ускоряют чтение. ' AS nvarchar(max)), 4096));

-- Строка 4: ДВЕ большие колонки — текст 200 КБ и двоичные данные 500 КБ
INSERT INTO dbo.DemoLob (ID, Title, Note, Blob)
VALUES (4, N'Две большие колонки',
        REPLICATE(CAST(N'Индексы ускоряют чтение. ' AS nvarchar(max)), 4096),
        CAST(REPLICATE(CAST(CONVERT(varchar(36), NEWID()) AS varchar(max)), 14223) AS varbinary(max)));

-- Строка 5: nvarchar(max) размером 6 000 байт — меньше 8000, поместится в строке
INSERT INTO dbo.DemoLob (ID, Title, Note)
VALUES (5, N'Средний max', REPLICATE(CAST(N'x' AS nvarchar(max)), 3000));
GO

-- Логические размеры значений
SELECT ID, Title,
       DATALENGTH(Text1) AS text1_bytes, DATALENGTH(Text2) AS text2_bytes,
       DATALENGTH(Note)  AS note_bytes,  DATALENGTH(Blob)  AS blob_bytes
FROM dbo.DemoLob ORDER BY ID;

-- Три единицы распределения (allocation units) одной таблицы и их страницы
SELECT au.type_desc        AS allocation_unit,
       au.total_pages, au.used_pages, au.data_pages
FROM sys.partitions AS p
JOIN sys.allocation_units AS au
  ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
WHERE p.object_id = OBJECT_ID('dbo.DemoLob') AND p.index_id = 1;
-- IN_ROW_DATA       — сами строки (листья кластерного индекса)
-- ROW_OVERFLOW_DATA — вытесненные колонки varchar(n)/nvarchar(n)/varbinary(n)
-- LOB_DATA          — значения (max), text, ntext, image, xml

-- То же по страницам: тип страницы TEXT_MIX_PAGE / TEXT_TREE_PAGE — страницы LOB
SELECT allocation_unit_type_desc, page_type_desc, COUNT(*) AS pages
FROM sys.dm_db_database_page_allocations(DB_ID(), OBJECT_ID('dbo.DemoLob'), 1, NULL, 'DETAILED')
WHERE is_allocated = 1
GROUP BY allocation_unit_type_desc, page_type_desc
ORDER BY allocation_unit_type_desc, page_type_desc;

-- Размер записей в строке: у строк 3 и 4 запись маленькая — вместо значений указатели
SELECT index_level, alloc_unit_type_desc, page_count, record_count,
       min_record_size_in_bytes, max_record_size_in_bytes, avg_record_size_in_bytes
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoLob'), 1, NULL, 'DETAILED')
WHERE index_level = 0;

-- Где физически лежит каждая строка: «файл:страница:слот»
-- (%%physloc%% и fn_PhysLocFormatter — недокументированные, но стабильные с SQL Server 2008)
SELECT sys.fn_PhysLocFormatter(%%physloc%%) AS [file:page:slot], ID, Title
FROM dbo.DemoLob
ORDER BY ID;
-- Все строки лежат на одной-двух страницах IN_ROW_DATA, несмотря на 700 КБ данных в строке 4

-- Посмотреть указатель в записи (подставьте страницу из [file:page:slot]):
-- DBCC TRACEON(3604);
-- DBCC PAGE ('StorageDemo', 1, <page_id>, 3);
-- В выводе для вытесненных колонок вместо значения — ссылка вида
-- RowId = (файл:страница:слот) на страницу ROW_OVERFLOW или LOB.
-- Для (max) это «inline root» размером 24–72 байта (до 5 ссылок на фрагменты);
-- если фрагментов больше — одна ссылка на страницу TEXT_TREE со списком фрагментов.
GO

-- =====================================================================
-- Часть 3. Что читается при запросе: смотрим «lob logical reads»
-- =====================================================================
SET STATISTICS IO ON;

-- 3.1. Большие колонки не нужны — LOB-страницы не читаются (lob logical reads 0)
SELECT ID, Title FROM dbo.DemoLob;

-- 3.2. Нужны большие колонки — читаются все их LOB-страницы
SELECT ID, Note, Blob FROM dbo.DemoLob WHERE ID = 4;

-- 3.3. LIKE '%...%' по nvarchar(max): значение каждой строки читается целиком
--      (совпадения нет — значит, для каждой строки прочитаны все фрагменты)
SELECT ID FROM dbo.DemoLob WHERE Note LIKE N'%zzzz%';

-- 3.4. Только начало значения: SUBSTRING по (max) может прочитать лишь
--      нужные фрагменты LOB — сравните lob logical reads с 3.2
SELECT ID, SUBSTRING(Note, 1, 100) AS note_start FROM dbo.DemoLob WHERE ID = 3;

SET STATISTICS IO OFF;
GO

-- =====================================================================
-- Часть 4. Устаревшие типы ntext / image (так 1С хранит данные в старых базах):
--          по умолчанию значение ВСЕГДА вне строки, даже маленькое
-- =====================================================================
CREATE TABLE dbo.DemoLegacy (
    ID    int    NOT NULL PRIMARY KEY CLUSTERED,
    Note  ntext  NULL,
    Blob  image  NULL
);
INSERT INTO dbo.DemoLegacy (ID, Note, Blob) VALUES (1, N'короткий текст', 0x0102);
GO

-- Даже 28 байт текста и 2 байта картинки лежат на LOB-страницах (text in row = OFF)
SELECT au.type_desc AS allocation_unit, au.used_pages
FROM sys.partitions AS p
JOIN sys.allocation_units AS au
  ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
WHERE p.object_id = OBJECT_ID('dbo.DemoLegacy') AND p.index_id = 1;

SET STATISTICS IO ON;
SELECT ID, Note FROM dbo.DemoLegacy;     -- lob logical reads > 0 даже для короткого текста
SET STATISTICS IO OFF;

-- Настройки размещения
SELECT name, text_in_row_limit, large_value_types_out_of_row
FROM sys.tables WHERE name IN ('DemoLob', 'DemoLegacy');
-- text_in_row_limit = 0 → ntext/image всегда вне строки.
-- EXEC sp_tableoption 'dbo.DemoLegacy', 'text in row', '7000';   -- хранить в строке до 7000 байт
-- large_value_types_out_of_row = 0 → (max) в строке, если ≤ 8000 байт и помещается.
-- EXEC sp_tableoption 'dbo.DemoLob', 'large value types out of row', 1;  -- всегда вне строки
GO

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE dbo.DemoRow; DROP TABLE dbo.DemoLob; DROP TABLE dbo.DemoLegacy;

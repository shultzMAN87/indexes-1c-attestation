-- =============================================================================
-- 10_inmemory_hash_bwtree.sql — hash-индекс и Bw-tree у memory-optimized таблиц
-- К разделу 2.5 методички (docs/02-mssql.md), подразделы «Hash» и «Bw-tree».
--
-- Что показывает:
--   1. Файловая группа MEMORY_OPTIMIZED_DATA и две одинаковые таблицы:
--      первичный ключ hash-индексом и первичный ключ Bw-tree (NONCLUSTERED).
--   2. Планы: «=» — обоим хорошо; диапазон и ORDER BY — hash не помогает;
--      ORDER BY DESC — Bw-tree однонаправленный, в плане Sort.
--   3. Состояние бакетов (sys.dm_db_xtp_hash_index_stats) при нормальном
--      и заниженном BUCKET_COUNT, REBUILD с новым числом бакетов.
--   4. Hash по колонке с повторами — длинные цепочки; Bw-tree там лучше.
--   5. Составной hash-ключ и условие только по первой колонке — индекс не берётся.
--
-- Требуется: SQL Server 2016+ (In-Memory OLTP во всех редакциях — с 2016 SP1;
-- в Express объём memory-optimized данных ограничен). Создаёт и удаляет
-- отдельную базу demo_inmem. Запускать по частям; в SSMS включите
-- «Include Actual Execution Plan» (Ctrl+M).
-- =============================================================================

USE master;
GO
IF DB_ID(N'demo_inmem') IS NOT NULL
BEGIN
    ALTER DATABASE demo_inmem SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_inmem;
END;
GO
CREATE DATABASE demo_inmem;
GO

-- -----------------------------------------------------------------------------
-- 0. Файловая группа для In-Memory: без неё memory-optimized таблицу не создать.
--    Контейнер — это КАТАЛОГ (не файл), кладём рядом с файлами данных по умолчанию.
-- -----------------------------------------------------------------------------
ALTER DATABASE demo_inmem ADD FILEGROUP demo_inmem_mod CONTAINS MEMORY_OPTIMIZED_DATA;
DECLARE @path nvarchar(400) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)) + N'demo_inmem_mod';
DECLARE @sql nvarchar(max) = N'ALTER DATABASE demo_inmem ADD FILE (NAME = N''demo_inmem_mod'', FILENAME = N''' + @path + N''') TO FILEGROUP demo_inmem_mod;';
EXEC (@sql);
GO
-- Без этой настройки в интероп-запросах к memory-optimized таблицам на уровнях
-- изоляции ниже SNAPSHOT понадобился бы хинт WITH (SNAPSHOT).
ALTER DATABASE demo_inmem SET MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT = ON;
GO
USE demo_inmem;
GO

-- -----------------------------------------------------------------------------
-- 1. Две одинаковые таблицы, отличие — тип индекса первичного ключа
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.SessionHash
(
    SessionId int           NOT NULL,
    UserId    int           NOT NULL,
    CreatedAt datetime2(0)  NOT NULL,
    Payload   nvarchar(100) NULL,
    -- 100 000 уникальных ключей → BUCKET_COUNT 131 072 (округлится до степени двойки)
    CONSTRAINT PK_SessionHash PRIMARY KEY NONCLUSTERED HASH (SessionId) WITH (BUCKET_COUNT = 131072)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);

CREATE TABLE dbo.SessionBw
(
    SessionId int           NOT NULL,
    UserId    int           NOT NULL,
    CreatedAt datetime2(0)  NOT NULL,
    Payload   nvarchar(100) NULL,
    CONSTRAINT PK_SessionBw PRIMARY KEY NONCLUSTERED (SessionId)     -- это и есть Bw-tree
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);
GO

INSERT INTO dbo.SessionHash (SessionId, UserId, CreatedAt, Payload)
SELECT TOP (100000)
       n, n % 500, DATEADD(second, CAST(n AS int), '2026-01-01'), N'payload'
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
      FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b) AS t;

INSERT INTO dbo.SessionBw (SessionId, UserId, CreatedAt, Payload)
SELECT SessionId, UserId, CreatedAt, Payload FROM dbo.SessionHash;
GO

-- Какие индексы получились. type_desc: NONCLUSTERED HASH — hash; NONCLUSTERED — Bw-tree.
SELECT OBJECT_NAME(i.object_id) AS table_name, i.name, i.type_desc
FROM sys.indexes AS i
WHERE i.object_id IN (OBJECT_ID(N'dbo.SessionHash'), OBJECT_ID(N'dbo.SessionBw'));

-- Сколько памяти занимают таблица и индексы.
SELECT OBJECT_NAME(object_id) AS table_name,
       memory_allocated_for_table_kb, memory_used_by_table_kb,
       memory_allocated_for_indexes_kb, memory_used_by_indexes_kb
FROM sys.dm_db_xtp_table_memory_stats
WHERE object_id IN (OBJECT_ID(N'dbo.SessionHash'), OBJECT_ID(N'dbo.SessionBw'));
-- Ожидаемо: у SessionHash индекс ≈ 131 072 × 8 байт = 1 МБ — массив бакетов
-- выделяется сразу, независимо от числа строк.
GO

-- -----------------------------------------------------------------------------
-- 2. Планы запросов. Смотрите оператор в плане:
--    Index Seek (NonClusteredHash) — поиск по бакету,
--    Index Seek (NonClustered)     — спуск по Bw-tree,
--    Index Scan / Table Scan       — полный обход.
--    STATISTICS IO для memory-optimized таблиц ничего не показывает: страниц нет.
-- -----------------------------------------------------------------------------

-- 2.1. Равенство — оба индекса работают.
SELECT * FROM dbo.SessionHash WHERE SessionId = 4242;   -- Index Seek (NonClusteredHash)
SELECT * FROM dbo.SessionBw   WHERE SessionId = 4242;   -- Index Seek (NonClustered)

-- 2.2. Диапазон — hash не помогает.
SELECT * FROM dbo.SessionHash WHERE SessionId BETWEEN 4000 AND 4100;  -- Index Scan + Filter: обход всех бакетов
SELECT * FROM dbo.SessionBw   WHERE SessionId BETWEEN 4000 AND 4100;  -- Index Seek: диапазон по листьям

-- 2.3. Сортировка.
SELECT TOP (10) * FROM dbo.SessionHash ORDER BY SessionId;        -- Scan + Sort (Top N Sort)
SELECT TOP (10) * FROM dbo.SessionBw   ORDER BY SessionId;        -- Index Scan по порядку, без Sort

-- 2.4. Сортировка в обратную сторону: Bw-tree однонаправленный.
SELECT TOP (10) * FROM dbo.SessionBw ORDER BY SessionId DESC;     -- Scan + Sort
-- (У дискового B-дерева MS SQL здесь был бы Backward Scan без Sort.)
GO

-- -----------------------------------------------------------------------------
-- 3. Состояние бакетов hash-индекса
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ShowBuckets @step nvarchar(100)
AS
SELECT @step                                             AS step,
       OBJECT_NAME(hs.object_id)                         AS table_name,
       i.name                                            AS index_name,
       hs.total_bucket_count,
       hs.empty_bucket_count,
       CAST(100.0 * hs.empty_bucket_count / hs.total_bucket_count AS decimal(5,1)) AS empty_pct,
       hs.avg_chain_length,
       hs.max_chain_length
FROM sys.dm_db_xtp_hash_index_stats AS hs
JOIN sys.indexes AS i ON i.object_id = hs.object_id AND i.index_id = hs.index_id
WHERE hs.object_id = OBJECT_ID(N'dbo.SessionHash');
GO

EXEC dbo.ShowBuckets N'3.1. BUCKET_COUNT = 131072 на 100 000 ключей';
-- Ожидаемо: пустых бакетов ~45%, средняя цепочка ~1,5, максимальная — единицы.
-- Это нормально: пустых бакетов около трети и больше, цепочки короткие.

-- 3.2. Заниженное число бакетов (в 100 раз меньше числа ключей).
ALTER TABLE dbo.SessionHash ALTER INDEX PK_SessionHash REBUILD WITH (BUCKET_COUNT = 1024);
EXEC dbo.ShowBuckets N'3.2. BUCKET_COUNT = 1024';
-- Ожидаемо: пустых бакетов 0%, средняя цепочка ~100.
-- Каждый поиск по «=» теперь проходит ~100 строк цепочки.

SELECT * FROM dbo.SessionHash WHERE SessionId = 4242;  -- план тот же, но работы в 100 раз больше

-- 3.3. Возвращаем нормальное значение: в 1–2 раза больше числа уникальных ключей.
ALTER TABLE dbo.SessionHash ALTER INDEX PK_SessionHash REBUILD WITH (BUCKET_COUNT = 200000);
EXEC dbo.ShowBuckets N'3.3. BUCKET_COUNT = 200000 (станет 262144)';
GO

-- -----------------------------------------------------------------------------
-- 4. Hash по колонке с повторами: UserId — всего 500 разных значений
-- -----------------------------------------------------------------------------
ALTER TABLE dbo.SessionHash ADD INDEX IX_SessionHash_User HASH (UserId) WITH (BUCKET_COUNT = 1024);
ALTER TABLE dbo.SessionBw   ADD INDEX IX_SessionBw_User NONCLUSTERED (UserId);
GO
SELECT i.name, hs.total_bucket_count, hs.empty_bucket_count, hs.avg_chain_length, hs.max_chain_length
FROM sys.dm_db_xtp_hash_index_stats AS hs
JOIN sys.indexes AS i ON i.object_id = hs.object_id AND i.index_id = hs.index_id
WHERE i.name = N'IX_SessionHash_User';
-- Ожидаемо: пустых бакетов больше половины (значений всего 500 на 1024 бакета),
-- а средняя цепочка — сотни строк: все строки одного UserId лежат в одной цепочке.
-- Сочетание «много пустых бакетов + длинные цепочки» = много повторов ключа.
-- Увеличение BUCKET_COUNT не поможет — нужен Bw-tree.

SELECT COUNT(*) FROM dbo.SessionHash WHERE UserId = 42;   -- Seek по hash: проход цепочки из сотен строк
SELECT COUNT(*) FROM dbo.SessionBw   WHERE UserId = 42;   -- Seek по Bw-tree: диапазон одинаковых ключей
GO

-- -----------------------------------------------------------------------------
-- 5. Составной hash-ключ: нужен ВЕСЬ ключ в условии
-- -----------------------------------------------------------------------------
ALTER TABLE dbo.SessionHash DROP INDEX IX_SessionHash_User;
ALTER TABLE dbo.SessionHash ADD INDEX IX_SessionHash_User_Created HASH (UserId, CreatedAt) WITH (BUCKET_COUNT = 131072);
GO
SELECT * FROM dbo.SessionHash WHERE UserId = 42 AND CreatedAt = '2026-01-01T00:00:42';  -- Seek: есть обе колонки
SELECT * FROM dbo.SessionHash WHERE UserId = 42;                                           -- Scan: хеш считается от пары
-- Bw-tree по (UserId, CreatedAt) в таком случае работал бы по левому префиксу.
GO

-- -----------------------------------------------------------------------------
-- 6. Уборка
-- -----------------------------------------------------------------------------
USE master;
GO
ALTER DATABASE demo_inmem SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE demo_inmem;
GO

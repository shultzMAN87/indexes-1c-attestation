-- =============================================================================
-- 15_vector_index.sql — векторный индекс DiskANN: точный и приближённый поиск
-- К разделу 2.5 методички (docs/02-mssql.md), подраздел «Векторный индекс».
--
-- Что показывает:
--   1. Тип vector(n) и 50 000 синтетических векторов (20 «тем» = 20 облаков точек).
--   2. Точный поиск ближайших: VECTOR_DISTANCE + TOP + ORDER BY — полный перебор.
--   3. CREATE VECTOR INDEX … TYPE = 'diskann' и приближённый поиск VECTOR_SEARCH.
--   4. Recall: сколько из настоящих 10 ближайших нашёл индекс.
--   5. Фильтр WHERE вместе с приближённым поиском.
--   6. Можно ли менять таблицу с векторным индексом.
--
-- Требуется: SQL Server 2025 (17.x) или Azure SQL Database. В SQL Server 2025
-- векторный индекс — preview: нужен PREVIEW_FEATURES = ON. Синтаксис VECTOR_SEARCH
-- различается по версиям индекса — в части 3 два варианта, запустите подходящий.
-- Создаёт и удаляет отдельную базу demo_vector (в Azure SQL Database запускайте
-- в своей базе, пропустив создание и удаление базы). Запускать по частям.
-- =============================================================================

IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) < 17
   AND CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5   -- 5 = Azure SQL Database
BEGIN
    PRINT N'Нужен SQL Server 2025 или Azure SQL Database. Скрипт не выполняется;';
    PRINT N'сообщения об ошибках разбора ниже (тип vector и т.п.) ожидаемы.';
    SET NOEXEC ON;
END;
GO

USE master;
GO
IF DB_ID(N'demo_vector') IS NOT NULL
BEGIN
    ALTER DATABASE demo_vector SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_vector;
END;
GO
CREATE DATABASE demo_vector;
GO
USE demo_vector;
GO
-- Включаем preview-возможности (в Azure SQL Database не нужно).
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- -----------------------------------------------------------------------------
-- 1. Данные: 20 центров («тем») в 16-мерном пространстве и по 2 500 векторов вокруг каждого.
--    В жизни векторы — эмбеддинги из модели (сотни измерений), здесь — синтетика.
-- -----------------------------------------------------------------------------
-- Детерминированное «случайное» число в диапазоне [-1; 1) по строке-затравке.
CREATE OR ALTER FUNCTION dbo.Rnd (@seed nvarchar(50)) RETURNS float
WITH SCHEMABINDING
AS BEGIN
    RETURN ABS(CAST(CAST(HASHBYTES('MD5', @seed) AS binary(4)) AS int) % 20000) / 10000.0 - 1.0;
END;
GO

CREATE TABLE dbo.Centroids (Grp int NOT NULL, Dim int NOT NULL, V float NOT NULL, PRIMARY KEY (Grp, Dim));
INSERT INTO dbo.Centroids (Grp, Dim, V)
SELECT g.value, d.value, dbo.Rnd(CONCAT(N'c', g.value, N':', d.value))
FROM GENERATE_SERIES(0, 19) AS g CROSS JOIN GENERATE_SERIES(1, 16) AS d;

-- Векторному индексу нужен кластерный первичный ключ из одной целочисленной колонки.
CREATE TABLE dbo.Docs
(
    Id        int        NOT NULL CONSTRAINT PK_Docs PRIMARY KEY CLUSTERED,
    Grp       int        NOT NULL,
    Embedding vector(16) NOT NULL
);

INSERT INTO dbo.Docs WITH (TABLOCK) (Id, Grp, Embedding)
SELECT n.value, n.value % 20,
       CAST((SELECT N'[' + STRING_AGG(CONVERT(nvarchar(20), CAST(c.V + 0.15 * dbo.Rnd(CONCAT(n.value, N':', c.Dim)) AS decimal(9, 6))), N',')
                          WITHIN GROUP (ORDER BY c.Dim) + N']'
             FROM dbo.Centroids AS c
             WHERE c.Grp = n.value % 20) AS vector(16))
FROM GENERATE_SERIES(1, 50000) AS n;
GO

SELECT TOP (3) Id, Grp, Embedding FROM dbo.Docs;   -- вектор хранится в бинарном виде, показывается как JSON-массив

-- Вектор запроса: возьмём вектор документа 777 (тема 17) и сохраним его в таблицу,
-- чтобы использовать в разных пакетах.
CREATE TABLE dbo.Q (q vector(16) NOT NULL);
INSERT INTO dbo.Q (q) SELECT Embedding FROM dbo.Docs WHERE Id = 777;
GO

-- -----------------------------------------------------------------------------
-- 2. Точный поиск: расстояние до КАЖДОЙ строки, сортировка, TOP. Индекс не нужен.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS #exact;
SET STATISTICS IO, TIME ON;
DECLARE @q vector(16) = (SELECT q FROM dbo.Q);
SELECT TOP (10) Id, Grp, VECTOR_DISTANCE('cosine', Embedding, @q) AS distance
INTO #exact
FROM dbo.Docs
ORDER BY distance;
SET STATISTICS IO, TIME OFF;
SELECT * FROM #exact ORDER BY distance;
-- В плане: Clustered Index Scan по всем 50 000 строк + Top N Sort.
-- Ответ точный; первая строка — сам документ 777 (расстояние 0).
GO

-- -----------------------------------------------------------------------------
-- 3. Векторный индекс DiskANN и приближённый поиск
-- -----------------------------------------------------------------------------
CREATE VECTOR INDEX VX_Docs_Embedding ON dbo.Docs (Embedding)
WITH (METRIC = 'cosine', TYPE = 'diskann');
GO

-- Метаданные индекса (если представление есть в вашей сборке).
IF OBJECT_ID(N'sys.vector_indexes') IS NOT NULL
    EXEC (N'SELECT * FROM sys.vector_indexes WHERE object_id = OBJECT_ID(N''dbo.Docs'');');
GO

-- 3A. Синтаксис SQL Server 2025 (ранняя версия индекса): число соседей — параметр TOP_N.
--     Если получите ошибку 42274 («…does not support explicit TOP_N…») — у вас новая
--     версия индекса, запускайте 3B.
DROP TABLE IF EXISTS #approx;
SET STATISTICS IO, TIME ON;
DECLARE @q vector(16) = (SELECT q FROM dbo.Q);
SELECT t.Id, t.Grp, s.distance
INTO #approx
FROM VECTOR_SEARCH(TABLE = dbo.Docs AS t, COLUMN = Embedding, SIMILAR_TO = @q,
                   METRIC = 'cosine', TOP_N = 10) AS s
ORDER BY s.distance;
SET STATISTICS IO, TIME OFF;
SELECT * FROM #approx ORDER BY distance;
GO

-- 3B. Синтаксис новой версии индекса (Azure SQL Database; в SQL Server — по мере выхода):
-- DROP TABLE IF EXISTS #approx;
-- DECLARE @q vector(16) = (SELECT q FROM dbo.Q);
-- SELECT TOP (10) WITH APPROXIMATE t.Id, t.Grp, s.distance
-- INTO #approx
-- FROM VECTOR_SEARCH(TABLE = dbo.Docs AS t, COLUMN = Embedding, SIMILAR_TO = @q,
--                    METRIC = 'cosine') AS s
-- ORDER BY s.distance;
-- SELECT * FROM #approx ORDER BY distance;
-- GO

-- В плане приближённого поиска нет сканирования всех 50 000 строк — индекс обходит граф
-- и читает небольшую часть вершин. METRIC в запросе должна совпадать с METRIC индекса,
-- иначе индекс не используется (будет предупреждение и полный перебор).

-- -----------------------------------------------------------------------------
-- 4. Recall: доля настоящих ближайших, которую нашёл индекс
-- -----------------------------------------------------------------------------
SELECT COUNT(*)               AS found_of_10,
       COUNT(*) / 10.0        AS recall
FROM #approx AS a
JOIN #exact  AS e ON e.Id = a.Id;
-- Обычно 9–10 из 10. Меньше 10 — не ошибка: так работает приближённый поиск.
GO

-- -----------------------------------------------------------------------------
-- 5. Фильтр WHERE вместе с приближённым поиском
-- -----------------------------------------------------------------------------
-- Похожие на документ 777 (тема 17), но только среди темы 3.
-- (Если работает только синтаксис 3B — перепишите запрос по образцу 3B, добавив WHERE.)
DECLARE @q vector(16) = (SELECT q FROM dbo.Q);
SELECT t.Id, t.Grp, s.distance
FROM VECTOR_SEARCH(TABLE = dbo.Docs AS t, COLUMN = Embedding, SIMILAR_TO = @q,
                   METRIC = 'cosine', TOP_N = 10) AS s
WHERE t.Grp = 3
ORDER BY s.distance;
-- В ранней версии индекса фильтр применяется ПОСЛЕ поиска: из 10 найденных соседей
-- (все — тема 17) условию не подошёл ни один → пусто, хотя в теме 3 есть 2 500 строк.
-- Новая версия индекса фильтрует во время обхода графа (синтаксис 3B + WHERE).
-- Точный перебор с WHERE всегда вернёт 10 строк темы 3:
SELECT TOP (10) Id, Grp, VECTOR_DISTANCE('cosine', Embedding, @q) AS distance
FROM dbo.Docs WHERE Grp = 3 ORDER BY distance;
GO

-- -----------------------------------------------------------------------------
-- 6. Можно ли менять таблицу с векторным индексом
-- -----------------------------------------------------------------------------
BEGIN TRY
    UPDATE dbo.Docs SET Grp = Grp WHERE Id = 1;
    PRINT N'UPDATE прошёл: версия индекса поддерживает изменения (индекс обслуживается автоматически).';
END TRY
BEGIN CATCH
    PRINT N'UPDATE запрещён: ' + ERROR_MESSAGE();
    PRINT N'Ранняя версия векторного индекса делает таблицу только для чтения.';
    PRINT N'Обход: удалить индекс → изменить данные → создать индекс заново.';
END CATCH;
GO

-- -----------------------------------------------------------------------------
-- 7. Уборка
-- -----------------------------------------------------------------------------
SET NOEXEC OFF;
GO
USE master;
GO
IF DB_ID(N'demo_vector') IS NOT NULL
BEGIN
    ALTER DATABASE demo_vector SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_vector;
END;
GO

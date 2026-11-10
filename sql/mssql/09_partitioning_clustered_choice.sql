/*
    MS SQL Server: ключ секционирования — дата, а поиск — по пользователю.
    Четыре варианта расположения индексов и как они отрабатывают три запроса.
    Методичка: docs/04-sekcionirovanie.md, раздел 4.2a

    Запускать ТОЛЬКО в тестовой базе. Скрипт создаёт и удаляет свои объекты.
    Не применять к таблицам базы 1С.

    Как смотреть результат:
      - включите фактический план (Ctrl+M в SSMS) и смотрите в свойствах оператора
        Actual Partition Count и Actual Partitions Accessed;
      - во вкладке Messages смотрите Scan count и logical reads (SET STATISTICS IO ON).
*/

-- 0. Очистка
DROP TABLE IF EXISTS dbo.Visits_A, dbo.Visits_B, dbo.Visits_C, dbo.Visits_D,
                     dbo.Visits_C_Stage, dbo.Visits_D_Stage;
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = 'psVisits') DROP PARTITION SCHEME psVisits;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pfVisits') DROP PARTITION FUNCTION pfVisits;
GO

-- 1. Секции по месяцам 2026 года: 12 границ → 13 секций
--    1: < 01.01 (пустая) | 2: январь | 3: февраль | … | 13: декабрь и позже
CREATE PARTITION FUNCTION pfVisits (date)
AS RANGE RIGHT FOR VALUES ('2026-01-01', '2026-02-01', '2026-03-01', '2026-04-01',
                           '2026-05-01', '2026-06-01', '2026-07-01', '2026-08-01',
                           '2026-09-01', '2026-10-01', '2026-11-01', '2026-12-01');
CREATE PARTITION SCHEME psVisits AS PARTITION pfVisits ALL TO ([PRIMARY]);
GO

-- 2. Четыре одинаковые таблицы
CREATE TABLE dbo.Visits_A (VisitID bigint NOT NULL, UserID int NOT NULL, VisitDate date NOT NULL, Payload char(100) NOT NULL);
CREATE TABLE dbo.Visits_B (VisitID bigint NOT NULL, UserID int NOT NULL, VisitDate date NOT NULL, Payload char(100) NOT NULL);
CREATE TABLE dbo.Visits_C (VisitID bigint NOT NULL, UserID int NOT NULL, VisitDate date NOT NULL, Payload char(100) NOT NULL);
CREATE TABLE dbo.Visits_D (VisitID bigint NOT NULL, UserID int NOT NULL, VisitDate date NOT NULL, Payload char(100) NOT NULL);
GO

-- Вариант 1. Кластерный по UserID, ВЫРОВНЕННЫЙ: данные секционированы по дате.
-- Индекс неуникальный → SQL Server сам добавит VisitDate в ключ.
CREATE CLUSTERED INDEX CX_A ON dbo.Visits_A (UserID) ON psVisits (VisitDate);

-- Уникальный так создать нельзя — Msg 1908: колонка секционирования обязана входить в ключ:
-- CREATE UNIQUE CLUSTERED INDEX CX_A_bad ON dbo.Visits_A (VisitID) ON psVisits (VisitDate);

-- Вариант 2. Кластерный по UserID, НЕВЫРОВНЕННЫЙ: таблица целиком в [PRIMARY], секций нет.
CREATE CLUSTERED INDEX CX_B ON dbo.Visits_B (UserID) ON [PRIMARY];

-- Вариант 3а. Кластерный по дате + некластерный по UserID, выровненный (по умолчанию).
CREATE CLUSTERED INDEX CX_C ON dbo.Visits_C (VisitDate, UserID) ON psVisits (VisitDate);
CREATE INDEX IX_C_User ON dbo.Visits_C (UserID);

-- Вариант 3б. То же, но некластерный по UserID — НЕВЫРОВНЕННЫЙ (одно общее дерево).
CREATE CLUSTERED INDEX CX_D ON dbo.Visits_D (VisitDate, UserID) ON psVisits (VisitDate);
CREATE INDEX IX_D_User ON dbo.Visits_D (UserID) ON [PRIMARY];
GO

-- 3. Данные: 1,2 млн визитов за 2026 год, 10 000 пользователей (≈120 визитов на пользователя)
DROP TABLE IF EXISTS #src;
SELECT TOP (1200000)
       ROW_NUMBER() OVER (ORDER BY (SELECT NULL))               AS VisitID,
       ABS(CHECKSUM(NEWID())) % 10000 + 1                      AS UserID,
       DATEADD(DAY, ABS(CHECKSUM(NEWID())) % 365, '2026-01-01') AS VisitDate,
       REPLICATE('x', 100)                                      AS Payload
INTO #src
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

INSERT INTO dbo.Visits_A WITH (TABLOCK) SELECT * FROM #src;
INSERT INTO dbo.Visits_B WITH (TABLOCK) SELECT * FROM #src;
INSERT INTO dbo.Visits_C WITH (TABLOCK) SELECT * FROM #src;
INSERT INTO dbo.Visits_D WITH (TABLOCK) SELECT * FROM #src;
GO

-- 4. Что получилось: где лежит каждый индекс и на сколько частей он разбит
--    PARTITION_SCHEME = выровненный (секционирован), ROWS_FILEGROUP = одно дерево
SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name, i.type_desc,
       ds.type_desc AS stored_on, ds.name AS data_space,
       (SELECT COUNT(*) FROM sys.partitions AS p
         WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS partitions
FROM sys.indexes AS i
JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
WHERE i.object_id IN (OBJECT_ID('dbo.Visits_A'), OBJECT_ID('dbo.Visits_B'),
                      OBJECT_ID('dbo.Visits_C'), OBJECT_ID('dbo.Visits_D'))
ORDER BY table_name, i.index_id;

-- Колонки ключа CX_A: VisitDate в ключе не указывали, но она там есть (partition_ordinal = 1)
SELECT c.name AS column_name, ic.key_ordinal, ic.partition_ordinal
FROM sys.index_columns AS ic
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE ic.object_id = OBJECT_ID('dbo.Visits_A') AND ic.index_id = 1;
GO

/* 5. Три запроса к четырём таблицам.
   Ожидаемо (Actual Partition Count в плане / Scan count в Messages):

                                   Q1: один день     Q2: UserID + февраль   Q3: UserID без даты
   A  CX(UserID) выровненный      1 секция, Scan     1 секция, Seek         13 секций, 13 Seek
   B  CX(UserID) ON [PRIMARY]     вся таблица, Scan  1 Seek                 1 Seek
   C  CX(дата) + NC выровненный   1 секция, Seek     1 секция, Seek         13 секций, 13 Seek
   D  CX(дата) + NC глобальный    1 секция, Seek     1 Seek (общее дерево)  1 Seek (общее дерево)

   Сравнивайте logical reads внутри одного столбца.
*/
SET STATISTICS IO ON;

PRINT '=== Q1: VisitDate = 15.02 ===';
SELECT COUNT(*) FROM dbo.Visits_A WHERE VisitDate = '2026-02-15';
SELECT COUNT(*) FROM dbo.Visits_B WHERE VisitDate = '2026-02-15';
SELECT COUNT(*) FROM dbo.Visits_C WHERE VisitDate = '2026-02-15';
SELECT COUNT(*) FROM dbo.Visits_D WHERE VisitDate = '2026-02-15';

PRINT '=== Q2: UserID = 42 и февраль ===';
SELECT COUNT(*) FROM dbo.Visits_A WHERE UserID = 42 AND VisitDate >= '2026-02-01' AND VisitDate < '2026-03-01';
SELECT COUNT(*) FROM dbo.Visits_B WHERE UserID = 42 AND VisitDate >= '2026-02-01' AND VisitDate < '2026-03-01';
SELECT COUNT(*) FROM dbo.Visits_C WHERE UserID = 42 AND VisitDate >= '2026-02-01' AND VisitDate < '2026-03-01';
SELECT COUNT(*) FROM dbo.Visits_D WHERE UserID = 42 AND VisitDate >= '2026-02-01' AND VisitDate < '2026-03-01';

PRINT '=== Q3: UserID = 42 без даты ===';
SELECT COUNT(*) FROM dbo.Visits_A WHERE UserID = 42;
SELECT COUNT(*) FROM dbo.Visits_B WHERE UserID = 42;
SELECT COUNT(*) FROM dbo.Visits_C WHERE UserID = 42;
SELECT COUNT(*) FROM dbo.Visits_D WHERE UserID = 42;

SET STATISTICS IO OFF;
GO

-- 6. SWITCH: выгрузить январь (секция 2) в stage-таблицу
--    Stage: та же структура и те же индексы, та же файловая группа.
CREATE TABLE dbo.Visits_C_Stage (VisitID bigint NOT NULL, UserID int NOT NULL, VisitDate date NOT NULL, Payload char(100) NOT NULL);
CREATE CLUSTERED INDEX CX_C_Stage ON dbo.Visits_C_Stage (VisitDate, UserID) ON [PRIMARY];
CREATE INDEX IX_C_Stage_User ON dbo.Visits_C_Stage (UserID) ON [PRIMARY];

CREATE TABLE dbo.Visits_D_Stage (VisitID bigint NOT NULL, UserID int NOT NULL, VisitDate date NOT NULL, Payload char(100) NOT NULL);
CREATE CLUSTERED INDEX CX_D_Stage ON dbo.Visits_D_Stage (VisitDate, UserID) ON [PRIMARY];
CREATE INDEX IX_D_Stage_User ON dbo.Visits_D_Stage (UserID) ON [PRIMARY];
GO

-- 6.1. Вариант 3а: все индексы выровнены → мгновенно
ALTER TABLE dbo.Visits_C SWITCH PARTITION 2 TO dbo.Visits_C_Stage;
SELECT COUNT(*) AS c_stage_rows FROM dbo.Visits_C_Stage;
GO

-- 6.2. Вариант 3б: невыровненный индекс → ошибка 7733
--      (table is partitioned while index 'IX_D_User' is not partitioned)
BEGIN TRY
    ALTER TABLE dbo.Visits_D SWITCH PARTITION 2 TO dbo.Visits_D_Stage;
END TRY
BEGIN CATCH
    PRINT CONCAT('Ошибка ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
GO

-- 6.3. Обход: убрать глобальный индекс, переключить, построить индекс заново.
--      CREATE INDEX строит дерево по ВСЕЙ таблице — на больших объёмах это часы,
--      то есть вся выгода «мгновенного» SWITCH пропадает.
DROP INDEX IX_D_User ON dbo.Visits_D;
DROP INDEX IX_D_Stage_User ON dbo.Visits_D_Stage;
ALTER TABLE dbo.Visits_D SWITCH PARTITION 2 TO dbo.Visits_D_Stage;
CREATE INDEX IX_D_User ON dbo.Visits_D (UserID) ON [PRIMARY];
SELECT COUNT(*) AS d_stage_rows FROM dbo.Visits_D_Stage;
GO

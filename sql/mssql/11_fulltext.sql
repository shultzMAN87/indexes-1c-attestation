-- =============================================================================
-- 11_fulltext.sql — полнотекстовый индекс: слово → документы и позиции
-- К разделу 2.5 методички (docs/02-mssql.md), подраздел «Полнотекстовый индекс».
--
-- Что показывает:
--   1. Установлен ли компонент Full-Text Search.
--   2. Как word breaker и стеммер разбирают русский текст (sys.dm_fts_parser).
--   3. Каталог и индекс; CONTAINS со словоформами, префиксом, NEAR; FREETEXT;
--      ранг через CONTAINSTABLE.
--   4. Что лежит в индексе: слова и число документов (sys.dm_fts_index_keywords).
--   5. Асинхронное заполнение: только что вставленная строка находится не сразу.
--   6. Стоп-слова.
--   7. CONTAINS против LIKE '%…%' по числу чтений.
--
-- Требуется: компонент Full-Text Search (ставится отдельно при установке SQL Server;
-- для Express — сборка with Advanced Services; на Linux — пакет mssql-server-fts).
-- Создаёт и удаляет отдельную базу demo_fts. Запускать по частям.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Компонент установлен?
-- -----------------------------------------------------------------------------
SELECT FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') AS is_fulltext_installed;  -- 1 — да
-- Есть ли русский word breaker (LCID 1049):
SELECT lcid, name FROM sys.fulltext_languages WHERE lcid IN (1049, 1033);
GO

USE master;
GO
IF DB_ID(N'demo_fts') IS NOT NULL
BEGIN
    ALTER DATABASE demo_fts SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_fts;
END;
GO
CREATE DATABASE demo_fts;
GO
USE demo_fts;
GO

-- -----------------------------------------------------------------------------
-- 1. Как разбирается текст — ещё до создания индекса
-- -----------------------------------------------------------------------------
-- Каждое слово фразы и его позиция (occurrence). Стоп-слова помечены special_term = 'Noise Word'.
SELECT display_term, occurrence, special_term
FROM sys.dm_fts_parser(N'"Индексы на таблице ускоряют поиск строк"', 1049, 0, 0);

-- Какие словоформы найдёт FORMSOF(INFLECTIONAL, …): стеммер разворачивает слово.
SELECT display_term
FROM sys.dm_fts_parser(N'FORMSOF(INFLECTIONAL, индекс)', 1049, 0, 0);
-- Ожидаемо: индекс, индекса, индексу, индексом, индексе, индексы, индексов, индексам, …
GO

-- -----------------------------------------------------------------------------
-- 2. Таблица: десяток осмысленных строк + 100 000 «шумовых» для сравнения с LIKE
-- -----------------------------------------------------------------------------
CREATE TABLE dbo.Docs
(
    Id    int IDENTITY   NOT NULL CONSTRAINT PK_Docs PRIMARY KEY,  -- KEY INDEX: уникальный, одна колонка, не NULL
    Title nvarchar(200)  NOT NULL,
    Body  nvarchar(max)  NOT NULL
);

INSERT INTO dbo.Docs (Title, Body) VALUES
(N'Индекс и поиск',        N'Индекс ускоряет поиск строк в большой таблице.'),
(N'Быстрый поиск',         N'Быстрый поиск по индексам: B-дерево и хеш.'),
(N'Таблицы',               N'Индексы на таблице замедляют вставку и обновление.'),
(N'Columnstore',           N'Колоночный индекс сжимает данные и ускоряет отчёты.'),
(N'Полнотекстовый поиск',  N'Полнотекстовый индекс хранит слова и их позиции в документах.'),
(N'Статистика',            N'Оптимизатор выбирает индекс по статистике распределения значений.'),
(N'Фрагментация',          N'После вставок страницы индекса расщепляются, растёт фрагментация.'),
(N'Блокировки',            N'Без подходящего индекса запрос сканирует таблицу и держит больше блокировок.'),
(N'Секционирование',       N'Секционированная таблица и выровненный индекс позволяют быстро переключать секции.'),
(N'Хранилище',             N'Отчёты в хранилище данных строятся по колоночным индексам.');

-- Шум: 100 000 строк из случайных «служебных» слов, искомых слов в них нет.
WITH w AS (SELECT v, ROW_NUMBER() OVER (ORDER BY v) - 1 AS n
           FROM (VALUES (N'склад'), (N'отгрузка'), (N'контрагент'), (N'договор'), (N'накладная'),
                        (N'остаток'), (N'партия'), (N'номенклатура'), (N'сумма'), (N'период')) AS t(v)),
     n AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
           FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b)
INSERT INTO dbo.Docs (Title, Body)
SELECT N'Документ ' + CAST(n.i AS nvarchar(10)),
       w1.v + N' ' + w2.v + N' ' + w3.v + N' ' + w1.v + N' номер ' + CAST(n.i AS nvarchar(10))
FROM n
JOIN w AS w1 ON w1.n = n.i % 10
JOIN w AS w2 ON w2.n = (n.i / 10) % 10
JOIN w AS w3 ON w3.n = (n.i / 100) % 10;
GO

-- -----------------------------------------------------------------------------
-- 3. Каталог и полнотекстовый индекс
-- -----------------------------------------------------------------------------
CREATE FULLTEXT CATALOG FT_Demo;
CREATE FULLTEXT INDEX ON dbo.Docs (Title LANGUAGE 1049, Body LANGUAGE 1049)
    KEY INDEX PK_Docs ON FT_Demo
    WITH CHANGE_TRACKING AUTO;     -- изменения подхватываются фоном
GO

-- Полное заполнение идёт асинхронно — ждём окончания.
WHILE FULLTEXTCATALOGPROPERTY(N'FT_Demo', 'PopulateStatus') <> 0
    WAITFOR DELAY '00:00:01';
SELECT FULLTEXTCATALOGPROPERTY(N'FT_Demo', 'ItemCount')       AS documents_in_index,
       FULLTEXTCATALOGPROPERTY(N'FT_Demo', 'UniqueKeyCount')  AS unique_words;
GO

-- -----------------------------------------------------------------------------
-- 4. Запросы. В плане ищите Table Valued Function [FulltextMatch].
-- -----------------------------------------------------------------------------
-- 4.1. Слово как есть.
SELECT Id, Body FROM dbo.Docs WHERE CONTAINS(Body, N'поиск');

-- 4.2. Все словоформы: индекс, индексы, индексам, индексу…
SELECT Id, Body FROM dbo.Docs WHERE CONTAINS(Body, N'FORMSOF(INFLECTIONAL, индекс)');

-- 4.3. Префикс (в двойных кавычках со звёздочкой): колоночный, колоночным…
SELECT Id, Body FROM dbo.Docs WHERE CONTAINS(Body, N'"колоночн*"');

-- 4.4. Слова рядом: не дальше 3 слов друг от друга (позиции хранятся в индексе).
SELECT Id, Body FROM dbo.Docs WHERE CONTAINS(Body, N'NEAR((индекс, поиск), 3)');

-- 4.5. «По смыслу»: словоформы всех слов фразы + тезаурус, слова через ИЛИ.
SELECT Id, Body FROM dbo.Docs WHERE FREETEXT(Body, N'как ускорить отчёты');

-- 4.6. Ранг релевантности: CONTAINSTABLE возвращает KEY (значение PK) и RANK.
SELECT d.Id, k.[RANK], d.Body
FROM CONTAINSTABLE(dbo.Docs, Body, N'ISABOUT(индекс WEIGHT(0.8), таблица WEIGHT(0.2))') AS k
JOIN dbo.Docs AS d ON d.Id = k.[KEY]
ORDER BY k.[RANK] DESC;

-- 4.7. Поиск сразу по двум колонкам индекса.
SELECT Id, Title FROM dbo.Docs WHERE CONTAINS((Title, Body), N'статистика OR секции');
GO

-- -----------------------------------------------------------------------------
-- 5. Что лежит в индексе: слово → число документов
-- -----------------------------------------------------------------------------
SELECT TOP (30) display_term, column_id, document_count
FROM sys.dm_fts_index_keywords(DB_ID(), OBJECT_ID(N'dbo.Docs'))
ORDER BY document_count DESC;
-- Ожидаемо: наверху «шумовые» слова (склад, отгрузка… — в десятках тысяч документов),
-- ниже — слова из осмысленных строк. Слова хранятся приведёнными к нижнему регистру.

-- В каких документах и сколько раз встречается слово:
SELECT k.display_term, k.document_id, k.occurrence_count
FROM sys.dm_fts_index_keywords_by_document(DB_ID(), OBJECT_ID(N'dbo.Docs')) AS k
WHERE k.display_term IN (N'индекс', N'индексы', N'поиск')
ORDER BY k.display_term, k.document_id;
GO

-- -----------------------------------------------------------------------------
-- 6. Асинхронность: вставили — и сразу ищем
-- -----------------------------------------------------------------------------
INSERT INTO dbo.Docs (Title, Body) VALUES (N'Новый', N'Слово абракадабра появилось только что.');
SELECT Id, Body FROM dbo.Docs WHERE CONTAINS(Body, N'абракадабра');   -- часто ещё пусто
WAITFOR DELAY '00:00:05';
SELECT Id, Body FROM dbo.Docs WHERE CONTAINS(Body, N'абракадабра');   -- теперь найдено
-- Обычный B-tree-индекс виден в той же транзакции; полнотекстовый — с задержкой.
GO

-- -----------------------------------------------------------------------------
-- 7. Стоп-слова: не индексируются
-- -----------------------------------------------------------------------------
SELECT TOP (20) stopword FROM sys.fulltext_system_stopwords WHERE language_id = 1049;
SELECT Id FROM dbo.Docs WHERE CONTAINS(Body, N'"на"');
-- Ожидаемо: пусто и информационное сообщение о том, что запрос содержит
-- только стоп-слова (noise words).
GO

-- -----------------------------------------------------------------------------
-- 8. CONTAINS против LIKE '%…%'
-- -----------------------------------------------------------------------------
SET STATISTICS IO, TIME ON;
SELECT COUNT(*) FROM dbo.Docs WHERE Body LIKE N'%фрагментац%';           -- сканирование всех 100 000 строк
SELECT COUNT(*) FROM dbo.Docs WHERE CONTAINS(Body, N'"фрагментац*"');    -- указатель → одна строка
SET STATISTICS IO, TIME OFF;
-- Сравните logical reads (и lob logical reads) по dbo.Docs: у LIKE — вся таблица,
-- у CONTAINS — несколько страниц. Важно: CONTAINS ищет СЛОВА и префиксы;
-- подстроку из середины слова ('%агмент%') полнотекстовый индекс не найдёт.
GO

-- -----------------------------------------------------------------------------
-- 9. Уборка
-- -----------------------------------------------------------------------------
USE master;
GO
ALTER DATABASE demo_fts SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE demo_fts;
GO

/* =====================================================================
   GiST в PostgreSQL: дерево ограничивающих областей, KNN, EXCLUDE,
   опорные функции, деградация после удалений, RD-дерево для tsvector,
   лексемы и стеммер (поиск слова «мир»)
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе, не в базе 1С.
   Нужны расширения pageinspect (функции GiST — с PostgreSQL 14)
   и btree_gist (оба — contrib, входят в стандартную поставку).
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =====================================================================
-- Часть 1. Точки на плоскости: магазины на карте 100 × 100 км
-- =====================================================================
DROP TABLE IF EXISTS demo_shops;
CREATE TABLE demo_shops (
    id    int GENERATED ALWAYS AS IDENTITY,
    name  text,
    pos   point                      -- координаты (x, y) в км
);

INSERT INTO demo_shops (name, pos)
SELECT 'Магазин ' || g, point(random() * 100, random() * 100)
FROM generate_series(1, 200000) AS g;

CREATE INDEX demo_shops_pos ON demo_shops USING gist (pos);
ANALYZE demo_shops;

-- ---------------------------------------------------------------------
-- 1. Что внутри: каждая запись внутреннего узла — ПРЯМОУГОЛЬНИК,
--    в который вписаны все точки его поддерева. Прямоугольники соседних
--    записей могут ПЕРЕКРЫВАТЬСЯ — в отличие от диапазонов B-tree.
-- ---------------------------------------------------------------------
-- Корень (блок 0): ограничивающие прямоугольники дочерних страниц
SELECT itemoffset, ctid AS child_page, keys AS bounding_box
FROM gist_page_items(get_raw_page('demo_shops_pos', 0), 'demo_shops_pos')
LIMIT 10;

SELECT count(*) AS entries_in_root
FROM gist_page_items(get_raw_page('demo_shops_pos', 0), 'demo_shops_pos');

-- Дочерняя страница первой записи корня. ctid вида (N,65535) — ссылка на страницу
-- следующего уровня: здесь опять прямоугольники (внутренний уровень).
-- На листьях в keys лежат сами точки (прямоугольник нулевого размера),
-- а ctid указывает на строку таблицы (страница, позиция)
SELECT itemoffset, ctid, keys
FROM gist_page_items(
       get_raw_page('demo_shops_pos',
         (SELECT (ctid::text::point)[0]::int
          FROM gist_page_items(get_raw_page('demo_shops_pos', 0), 'demo_shops_pos')
          WHERE itemoffset = 1)),
       'demo_shops_pos')
LIMIT 5;

-- ---------------------------------------------------------------------
-- 2. Поиск «что попадает в область»: точки в квадрате 1 × 1 км
--    Спуск идёт во ВСЕ ветви, чей прямоугольник пересекает квадрат
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_shops WHERE pos <@ box '((50,50),(51,51))';

-- ---------------------------------------------------------------------
-- 3. Ближайшие соседи (KNN): 5 магазинов, ближайших к точке (30, 70).
--    Индекс сам отдаёт точки в порядке расстояния — без сортировки всей таблицы.
--    B-tree так не умеет: у точек нет порядка «больше/меньше».
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, name, pos, pos <-> point '(30,70)' AS distance_km
FROM demo_shops
ORDER BY pos <-> point '(30,70)'
LIMIT 5;

SELECT id, name, pos, round((pos <-> point '(30,70)')::numeric, 3) AS distance_km
FROM demo_shops
ORDER BY pos <-> point '(30,70)'
LIMIT 5;

-- Для сравнения — без индекса: Seq Scan по всем 200 тыс. строк + сортировка
SET enable_indexscan = off; SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_shops ORDER BY pos <-> point '(30,70)' LIMIT 5;
RESET enable_indexscan; RESET enable_bitmapscan;

-- =====================================================================
-- Часть 2. Диапазоны и ограничение исключения: бронь переговорных
-- =====================================================================
DROP TABLE IF EXISTS demo_booking;
CREATE TABLE demo_booking (
    room    int       NOT NULL,
    during  tstzrange NOT NULL,
    -- в одной комнате интервалы брони не должны пересекаться.
    -- room WITH =  требует btree_gist (равенство для int в GiST)
    -- during WITH && — «пересекается»
    CONSTRAINT demo_booking_no_overlap
        EXCLUDE USING gist (room WITH =, during WITH &&)
);

INSERT INTO demo_booking VALUES
    (1, '[2024-06-10 10:00, 2024-06-10 11:00)'),
    (1, '[2024-06-10 11:00, 2024-06-10 12:30)'),   -- вплотную — можно
    (2, '[2024-06-10 10:30, 2024-06-10 11:30)');   -- другая комната — можно

-- Пересечение в той же комнате — ошибка conflicting key value violates exclusion constraint
-- (раскомментируйте):
-- INSERT INTO demo_booking VALUES (1, '[2024-06-10 10:30, 2024-06-10 10:45)');

-- Поиск броней, пересекающихся с интервалом, — тоже через этот GiST-индекс
EXPLAIN (COSTS OFF)
SELECT * FROM demo_booking
WHERE room = 1 AND during && tstzrange('2024-06-10 10:45', '2024-06-10 11:15');

-- =====================================================================
-- Часть 3. Опорные функции классов операторов GiST
--   1 consistent, 2 union, 3 compress, 4 decompress, 5 penalty,
--   6 picksplit, 7 same, 8 distance, 9 fetch, 10 options, 11 sortsupport
-- =====================================================================
SELECT opc.opcname AS opclass,
       string_agg(p.amprocnum || ':' || p.amproc::regproc::text, ', ' ORDER BY p.amprocnum) AS support_functions
FROM pg_opclass opc
JOIN pg_am a      ON a.oid = opc.opcmethod AND a.amname = 'gist'
JOIN pg_amproc p  ON p.amprocfamily = opc.opcfamily
                 AND p.amproclefttype = opc.opcintype
                 AND p.amprocrighttype = opc.opcintype
WHERE opc.opcname IN ('point_ops', 'box_ops', 'range_ops', 'tsvector_ops')
GROUP BY opc.opcname
ORDER BY opc.opcname;
-- point_ops: есть distance (8) → KNN, fetch (9) → Index Only Scan, sortsupport (11) → быстрое построение
-- tsvector_ops: compress/decompress (3, 4) → сигнатуры, options (10) → siglen; fetch нет → без Index Only Scan

-- =====================================================================
-- Часть 4. Деградация: после DELETE ключи родителей не сужаются
-- =====================================================================
DROP TABLE IF EXISTS demo_gist_decay;
CREATE TABLE demo_gist_decay (pos point);
INSERT INTO demo_gist_decay
SELECT point(random() * 100, random() * 100) FROM generate_series(1, 200000);
CREATE INDEX demo_gist_decay_pos ON demo_gist_decay USING gist (pos);
VACUUM ANALYZE demo_gist_decay;

-- Прямоугольники корня до удаления
SELECT keys FROM gist_page_items(get_raw_page('demo_gist_decay_pos', 0), 'demo_gist_decay_pos') LIMIT 5;

-- Удалить все точки с x > 10 (около 90%)
DELETE FROM demo_gist_decay WHERE pos[0] > 10;
VACUUM demo_gist_decay;

-- После VACUUM прямоугольники корня ТЕ ЖЕ: охватывают области, где точек уже нет
SELECT keys FROM gist_page_items(get_raw_page('demo_gist_decay_pos', 0), 'demo_gist_decay_pos') LIMIT 5;

-- Поиск в опустевшей области: ничего не найдено, но прочитано ~20 страниц
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_gist_decay WHERE pos <@ box '((50,0),(100,100))';

-- Перестроение: ключи пересчитываются по оставшимся данным
REINDEX INDEX CONCURRENTLY demo_gist_decay_pos;

SELECT keys FROM gist_page_items(get_raw_page('demo_gist_decay_pos', 0), 'demo_gist_decay_pos') LIMIT 5;

-- Тот же поиск — 1 страница (корень сразу показывает, что справа от x = 10 ничего нет)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_gist_decay WHERE pos <@ box '((50,0),(100,100))';

-- =====================================================================
-- Часть 5. RD-дерево: GiST по tsvector (полнотекстовый поиск)
--   Ключ — сигнатура: лексема → бит, документ = OR битов лексем,
--   родитель = OR сигнатур потомков. siglen по умолчанию 124 байта = 992 бита
-- =====================================================================
DROP TABLE IF EXISTS demo_fts;
CREATE TABLE demo_fts (id int GENERATED ALWAYS AS IDENTITY, tsv tsvector);

-- 30 тыс. документов по 20–320 слов из словаря 20 тыс. слов (частые слова встречаются чаще)
INSERT INTO demo_fts (tsv)
SELECT to_tsvector('simple',
         (SELECT string_agg('w' || floor(power(random(), 2) * 20000)::int, ' ')
          FROM generate_series(1, 20 + (g % 300))
          WHERE g > 0))                     -- ссылка на g: подзапрос считается для каждой строки
FROM generate_series(1, 30000) AS g;

CREATE INDEX demo_fts_gist ON demo_fts USING gist (tsv);
VACUUM ANALYZE demo_fts;

SELECT pg_size_pretty(pg_relation_size('demo_fts_gist')) AS gist_size,
       pg_relation_size('demo_fts_gist') / 8192          AS gist_pages;

-- ---------------------------------------------------------------------
-- 5.1. Что лежит в узлах.
--   "N unique words"          — лист, короткий документ: массив хешей лексем (почти точно)
--   "X true bits, Y false bits" — сигнатура (лист с длинным документом или внутренний узел)
--   "0 true bits, 0 false bits" — так PG 16 показывает узел «all true»: все биты = 1,
--                                 маска не хранится, узел НИЧЕГО не отсекает
-- ---------------------------------------------------------------------
WITH pages AS (
    SELECT n, 'leaf' = ANY ((gist_page_opaque_info(get_raw_page('demo_fts_gist', n))).flags) AS is_leaf
    FROM generate_series(0, pg_relation_size('demo_fts_gist') / 8192 - 1) AS n
)
SELECT CASE WHEN is_leaf THEN 'лист' ELSE 'внутренний' END AS level,
       CASE WHEN keys LIKE '%unique words%'               THEN 'массив хешей'
            WHEN keys LIKE '%"0 true bits, 0 false bits"%' THEN 'all true'
            ELSE 'сигнатура' END                            AS key_kind,
       count(*)
FROM pages, gist_page_items(get_raw_page('demo_fts_gist', n), 'demo_fts_gist')
GROUP BY 1, 2 ORDER BY 1, 2;

-- Корень: при длинных документах все записи — «all true» (насыщение)
SELECT itemoffset, keys FROM gist_page_items(get_raw_page('demo_fts_gist', 0), 'demo_fts_gist') LIMIT 5;

-- Где граница «массив / сигнатура» в листьях (около 125 лексем при siglen = 124)
WITH leaf_items AS (
    SELECT i.ctid, i.keys
    FROM generate_series(1, pg_relation_size('demo_fts_gist') / 8192 - 1) AS n,
         gist_page_items(get_raw_page('demo_fts_gist', n), 'demo_fts_gist') AS i
    WHERE 'leaf' = ANY ((gist_page_opaque_info(get_raw_page('demo_fts_gist', n))).flags)
)
SELECT CASE WHEN keys LIKE '%unique words%' THEN 'массив хешей' ELSE 'сигнатура' END AS leaf_key,
       min(length(f.tsv)) AS min_lexemes, max(length(f.tsv)) AS max_lexemes, count(*)
FROM leaf_items li JOIN demo_fts f ON f.ctid = li.ctid
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 5.2. Поиск одного слова: смотрите Buffers у Bitmap Index Scan
--      (≈ весь индекс) и Rows Removed by Index Recheck (ложные срабатывания)
-- ---------------------------------------------------------------------
SET enable_seqscan = off; SET enable_indexscan = off;   -- чтобы был виден Bitmap и Recheck

SELECT count(*) AS real_matches FROM demo_fts WHERE tsv @@ to_tsquery('simple', 'w15000');

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_fts WHERE tsv @@ to_tsquery('simple', 'w15000');

-- ---------------------------------------------------------------------
-- 5.3. Длиннее сигнатура — меньше коллизий, но индекс больше
-- ---------------------------------------------------------------------
DROP INDEX demo_fts_gist;
CREATE INDEX demo_fts_gist_1024 ON demo_fts USING gist (tsv tsvector_ops (siglen = 1024));

SELECT pg_size_pretty(pg_relation_size('demo_fts_gist_1024')) AS gist_1024_size;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_fts WHERE tsv @@ to_tsquery('simple', 'w15000');

-- ---------------------------------------------------------------------
-- 5.4. Для сравнения — GIN: «лексема → список строк», без ложных кандидатов
-- ---------------------------------------------------------------------
DROP INDEX demo_fts_gist_1024;
CREATE INDEX demo_fts_gin ON demo_fts USING gin (tsv);

SELECT pg_size_pretty(pg_relation_size('demo_fts_gin')) AS gin_size;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_fts WHERE tsv @@ to_tsquery('simple', 'w15000');

-- ---------------------------------------------------------------------
-- 5.5. Префикс (w15000:*) RD-дерево не отсекает: из GiST выходят ВСЕ строки
--      кандидатами, отсеивает их только перепроверка (полный перебор)
-- ---------------------------------------------------------------------
DROP INDEX demo_fts_gin;
CREATE INDEX demo_fts_gist ON demo_fts USING gist (tsv);

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_fts WHERE tsv @@ to_tsquery('simple', 'w15000:*');

RESET enable_seqscan; RESET enable_indexscan;

-- =====================================================================
-- Часть 6. Лексемы и стеммер: поиск слова «мир»
-- =====================================================================
-- Разбор текста: парсер → стоп-слова («и» — пустая лексема) → стеммер russian_stem
SELECT alias, token, dictionaries, lexemes
FROM ts_debug('russian', 'Война и мир. Адмирал читал, договор подписан')
WHERE alias <> 'blank';

-- Что стеммер делает с отдельными словами
SELECT w AS word, ts_lexize('russian_stem', w) AS lexeme
FROM unnest(ARRAY[
    'мир', 'мира', 'мирах', 'мирный', 'мирными', 'Миротворец', 'Памир', 'Пальмира', 'Мираж', 'Адмирал',
    'мирить', 'мирю',                  -- склеились с «мир»
    'бежать', 'бегу', 'человек', 'люди', 'идти', 'шёл',   -- формы одного слова НЕ склеились
    'столица', 'котировка'             -- корень не принят за окончание
]) AS w;

DROP TABLE IF EXISTS demo_mir;
CREATE TABLE demo_mir (id int, body text, tsv tsvector);
INSERT INTO demo_mir (id, body) VALUES
    (1, 'Война и мир'),        (2, 'Мирный договор подписан'), (3, 'Миротворец прибыл'),
    (4, 'Горы Памира'),        (5, 'Древняя Пальмира'),        (6, 'Мираж в пустыне'),
    (7, 'Адмирал флота'),      (8, 'Жить в мире и согласии'),  (9, 'Слухи о новых мирах');
UPDATE demo_mir SET tsv = to_tsvector('russian', body);

-- Слово целиком: только 1, 8, 9
SELECT id, body, tsv FROM demo_mir WHERE tsv @@ to_tsquery('russian', 'мир') ORDER BY id;

-- Начинается на «мир»: + Мирный, Миротворец, Мираж (1, 2, 3, 6, 8, 9)
SELECT id, body FROM demo_mir WHERE tsv @@ to_tsquery('russian', 'мир:*') ORDER BY id;

-- Подстрока где угодно: все 9 — это уже не полнотекстовый поиск, а pg_trgm
SELECT id, body FROM demo_mir WHERE body ILIKE '%мир%' ORDER BY id;

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_shops; DROP TABLE demo_booking; DROP TABLE demo_gist_decay; DROP TABLE demo_fts; DROP TABLE demo_mir;

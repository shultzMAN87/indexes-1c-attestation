/* =====================================================================
   GiST в PostgreSQL: дерево ограничивающих областей, KNN, EXCLUDE,
   опорные функции, деградация после удалений
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

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_shops; DROP TABLE demo_booking; DROP TABLE demo_gist_decay;

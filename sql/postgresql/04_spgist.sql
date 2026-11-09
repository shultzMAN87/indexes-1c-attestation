/* =====================================================================
   SP-GiST в PostgreSQL: разбиение пространства, префиксное дерево
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 12+), не в базе 1С.
   Части 1–3 — без расширений; часть 4 — pageinspect (contrib).
   ===================================================================== */

-- =====================================================================
-- Часть 1. Точки: дерево квадрантов (quad-tree) и k-d дерево
-- =====================================================================
DROP TABLE IF EXISTS demo_sp_points;
CREATE TABLE demo_sp_points (id int GENERATED ALWAYS AS IDENTITY, pos point);

INSERT INTO demo_sp_points (pos)
SELECT point(random() * 100, random() * 100)
FROM generate_series(1, 200000);

-- Три индекса по одной колонке — сравним
CREATE INDEX demo_sp_points_gist ON demo_sp_points USING gist   (pos);
CREATE INDEX demo_sp_points_quad ON demo_sp_points USING spgist (pos);                 -- quad_point_ops по умолчанию
CREATE INDEX demo_sp_points_kd   ON demo_sp_points USING spgist (pos kd_point_ops);   -- k-d дерево
VACUUM ANALYZE demo_sp_points;

SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'demo_sp_points' ORDER BY indexrelname;

-- Поиск точек в квадрате. SP-GiST умеет Index Only Scan: значение точки
-- восстанавливается при спуске / лежит в листе, в кучу ходить не нужно
DROP INDEX demo_sp_points_gist; DROP INDEX demo_sp_points_kd;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT pos FROM demo_sp_points WHERE pos <@ box '((50,50),(51,51))';

-- KNN (ближайшие соседи) SP-GiST тоже поддерживает (PostgreSQL 12+)
EXPLAIN (ANALYZE, COSTS OFF)
SELECT pos FROM demo_sp_points ORDER BY pos <-> point '(30,70)' LIMIT 5;

-- =====================================================================
-- Часть 2. Строки: префиксное дерево (radix tree)
--    Общие начала строк хранятся во внутренних узлах один раз,
--    поэтому индекс по строкам с длинными общими префиксами компактен
-- =====================================================================
DROP TABLE IF EXISTS demo_sp_urls;
CREATE TABLE demo_sp_urls (id int GENERATED ALWAYS AS IDENTITY, url text);

INSERT INTO demo_sp_urls (url)
SELECT 'https://shop.example.com/' ||
       (ARRAY['catalog/electronics/','catalog/books/','catalog/clothes/','help/','news/'])[1 + g % 5] ||
       md5(g::text)
FROM generate_series(1, 300000) AS g;

CREATE INDEX demo_sp_urls_btree  ON demo_sp_urls USING btree  (url text_pattern_ops);
CREATE INDEX demo_sp_urls_spgist ON demo_sp_urls USING spgist (url);
VACUUM ANALYZE demo_sp_urls;

SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'demo_sp_urls' ORDER BY indexrelname;

DROP INDEX demo_sp_urls_btree;

-- Поиск по префиксу: оператор ^@ («начинается с») и LIKE 'префикс%'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_sp_urls WHERE url ^@ 'https://shop.example.com/help/ab';

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_sp_urls WHERE url LIKE 'https://shop.example.com/help/ab%';

-- Точное совпадение — тоже работает
EXPLAIN (COSTS OFF)
SELECT * FROM demo_sp_urls WHERE url = 'https://shop.example.com/help/' || md5('3');

-- =====================================================================
-- Часть 3. IP-адреса и подсети (inet): «адрес входит в подсеть»
-- =====================================================================
DROP TABLE IF EXISTS demo_sp_ip;
CREATE TABLE demo_sp_ip (ip inet);
INSERT INTO demo_sp_ip
SELECT ('10.' || (random()*255)::int || '.' || (random()*255)::int || '.' || (random()*255)::int)::inet
FROM generate_series(1, 200000);
CREATE INDEX demo_sp_ip_spgist ON demo_sp_ip USING spgist (ip);
VACUUM ANALYZE demo_sp_ip;

EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM demo_sp_ip WHERE ip << inet '10.20.30.0/24';   -- << «входит в подсеть»

-- =====================================================================
-- Часть 4. Что внутри: классы, опорные функции, свойства, страницы
--    Нужно расширение pageinspect (contrib) — только для get_raw_page
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- Классы операторов SP-GiST и их опорные функции (1 config, 2 choose,
-- 3 picksplit, 4 inner_consistent, 5 leaf_consistent, 6 compress, 7 options)
SELECT c.opcname, c.opcintype::regtype AS тип, c.opcdefault AS по_умолчанию,
       string_agg(p.amprocnum || ':' || p.amproc::regproc::text, ', ' ORDER BY p.amprocnum) AS функции
FROM pg_opclass c
JOIN pg_am a      ON a.oid = c.opcmethod
JOIN pg_amproc p  ON p.amprocfamily = c.opcfamily
WHERE a.amname = 'spgist'
GROUP BY 1, 2, 3 ORDER BY 1;
-- PG 16: у всех — 1..5, у poly_ops ещё 6:spg_poly_quad_compress

-- Свойства метода доступа: нет порядка, уникальности и составных ключей
SELECT p.name, pg_indexam_has_property(a.oid, p.name)
FROM pg_am a, unnest(array['can_order','can_unique','can_multi_col','can_exclude','can_include']) p(name)
WHERE a.amname = 'spgist';

-- Index Only Scan и KNN — зависят от класса
DROP TABLE IF EXISTS demo_sp_kinds;
CREATE TABLE demo_sp_kinds (p point, b box, pg polygon, r int4range, s text, ip inet);
INSERT INTO demo_sp_kinds
SELECT point(g % 100, g / 100), box(point(g % 100, g / 100), point(g % 100 + 1, g / 100 + 1)),
       polygon(box(point(g % 100, g / 100), point(g % 100 + 1, g / 100 + 1))),
       int4range(g, g + 10), 'v' || g, ('10.0.' || g % 256 || '.' || g / 256)::inet
FROM generate_series(1, 10000) g;
CREATE INDEX demo_sp_k_quad ON demo_sp_kinds USING spgist (p);
CREATE INDEX demo_sp_k_kd   ON demo_sp_kinds USING spgist (p kd_point_ops);
CREATE INDEX demo_sp_k_box  ON demo_sp_kinds USING spgist (b);
CREATE INDEX demo_sp_k_poly ON demo_sp_kinds USING spgist (pg);
CREATE INDEX demo_sp_k_rng  ON demo_sp_kinds USING spgist (r);
CREATE INDEX demo_sp_k_text ON demo_sp_kinds USING spgist (s);
CREATE INDEX demo_sp_k_inet ON demo_sp_kinds USING spgist (ip);
SELECT i AS индекс,
       pg_index_column_has_property(i, 1, 'returnable')         AS index_only_scan,
       pg_index_column_has_property(i, 1, 'distance_orderable') AS knn
FROM unnest(array['demo_sp_k_quad','demo_sp_k_kd','demo_sp_k_box','demo_sp_k_poly',
                  'demo_sp_k_rng','demo_sp_k_text','demo_sp_k_inet']::regclass[]) i;
-- poly_ops — единственный без Index Only Scan: в листе прямоугольник, а не многоугольник
-- KNN — только у точек, box и polygon

-- Страницы индекса: блок 0 — метастраница, 1 — корень, 2 — корень дерева NULL.
-- Флаги страницы — первые 2 байта специальной области:
-- 1 = META, 2 = DELETED, 4 = LEAF, 8 = NULLS
DROP TABLE IF EXISTS demo_sp_nulls;
CREATE TABLE demo_sp_nulls (s text);
INSERT INTO demo_sp_nulls
SELECT CASE WHEN g % 10 = 0 THEN NULL ELSE 'v' || g END FROM generate_series(1, 5000) g;
CREATE INDEX demo_sp_nulls_idx ON demo_sp_nulls USING spgist (s);
SELECT b AS блок,
       get_byte(pg, sp) + 256 * get_byte(pg, sp + 1) AS флаги
FROM generate_series(0, 3) b,
     LATERAL (SELECT get_raw_page('demo_sp_nulls_idx', b) AS pg) r,
     LATERAL (SELECT (page_header(r.pg)).special AS sp) h;
-- 0 → 1 (META); 1 → 0 или 4 (корень: внутренняя или листовая); 2 → 8 или 12 (NULLS)

-- Пример из методички: четыре URL, поиск по префиксу и Index Only Scan
DROP TABLE IF EXISTS demo_sp_four;
CREATE TABLE demo_sp_four (url text);
INSERT INTO demo_sp_four VALUES
  ('postgrespro.com'), ('postgrespro.ru'), ('postgresql.org'), ('planet.postgresql.org');
CREATE INDEX demo_sp_four_idx ON demo_sp_four USING spgist (url);
VACUUM ANALYZE demo_sp_four;
SET enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT url FROM demo_sp_four WHERE url ^@ 'postgres';
-- Index Only Scan, Heap Fetches: 0, найдено 3 строки — planet.postgresql.org не подходит
RESET enable_seqscan;

-- Запрет дублей точек через EXCLUDE (UNIQUE для SP-GiST нет)
DROP TABLE IF EXISTS demo_sp_excl;
CREATE TABLE demo_sp_excl (pos point, EXCLUDE USING spgist (pos WITH ~=));
INSERT INTO demo_sp_excl VALUES (point '(1,1)');
-- INSERT INTO demo_sp_excl VALUES (point '(1,1)');   -- ошибка: conflicting key value violates exclusion constraint

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_sp_points; DROP TABLE demo_sp_urls; DROP TABLE demo_sp_ip;
-- DROP TABLE demo_sp_kinds; DROP TABLE demo_sp_nulls; DROP TABLE demo_sp_four; DROP TABLE demo_sp_excl;

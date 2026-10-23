/* =====================================================================
   SP-GiST в PostgreSQL: разбиение пространства, префиксное дерево
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 12+), не в базе 1С.
   Расширений не требуется.
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

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_sp_points; DROP TABLE demo_sp_urls; DROP TABLE demo_sp_ip;

/* =====================================================================
   B-tree в PostgreSQL: что внутри и чем он отличается от MS SQL
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 13+), не в базе 1С.
   Нужно расширение pageinspect (входит в стандартную поставку, contrib).
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS demo_bt;
CREATE TABLE demo_bt (
    id      bigint GENERATED ALWAYS AS IDENTITY,
    status  text   NOT NULL,          -- 4 значения: малоселективная колонка
    amount  numeric(12,2) NOT NULL
);

INSERT INTO demo_bt (status, amount)
SELECT (ARRAY['new','paid','shipped','closed'])[1 + g % 4],
       (random() * 10000)::numeric(12,2)
FROM generate_series(1, 1000000) AS g;

CREATE INDEX demo_bt_id     ON demo_bt (id);
VACUUM ANALYZE demo_bt;       -- обновить карту видимости (нужна Index Only Scan)

-- ---------------------------------------------------------------------
-- 1. Устройство дерева: метастраница → корень → ... → листья
--    level у корня = (число уровней - 1). Для 1 млн строк — 2, т.е. 3 уровня.
-- ---------------------------------------------------------------------
SELECT root AS root_block, level AS root_level, fastroot, fastlevel
FROM bt_metap('demo_bt_id');

-- Корень: ключи-границы и ссылки на дочерние страницы (ctid = (блок, 0..))
SELECT itemoffset, ctid AS child_page, data
FROM bt_page_items('demo_bt_id', (SELECT root FROM bt_metap('demo_bt_id')))
LIMIT 5;

-- Лист (страница 1): ключ + ctid — адрес строки в куче (страница, позиция).
-- В MS SQL в этом месте лежал бы ключ кластерного индекса.
-- Первая запись на любой странице, кроме самой правой, — «high key»:
-- верхняя граница ключей этой страницы (её ctid указывает не на строку).
SELECT itemoffset, ctid AS heap_tid, data
FROM bt_page_items('demo_bt_id', 1)
LIMIT 5;

-- Связи соседних листьев (btpo_prev / btpo_next) — для диапазонов и ORDER BY
SELECT blkno, type, live_items, avg_item_size, free_size, btpo_prev, btpo_next
FROM bt_page_stats('demo_bt_id', 1);

-- ---------------------------------------------------------------------
-- 2. Дедупликация (PostgreSQL 13+): одинаковые ключи хранятся один раз
--    со списком ctid (posting list). Сравним индекс по status с ней и без.
-- ---------------------------------------------------------------------
CREATE INDEX demo_bt_status_dedup   ON demo_bt (status);
CREATE INDEX demo_bt_status_nodedup ON demo_bt (status) WITH (deduplicate_items = off);

SELECT indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'demo_bt' AND indexrelname LIKE 'demo_bt_status%';

-- Posting list в листе: в поле htid — первый ctid, tids — массив всех ctid.
-- Первая строка — high key (см. выше), у неё tids пусто.
SELECT itemoffset, htid, array_length(tids, 1) AS tids_in_item, data
FROM bt_page_items('demo_bt_status_dedup', 1)
LIMIT 3;

-- ---------------------------------------------------------------------
-- 3. Методы доступа в плане
-- ---------------------------------------------------------------------
-- Index Scan: индекс → куча за каждой строкой
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_bt WHERE id = 500000;

-- Index Only Scan: всё нужное есть в индексе; Heap Fetches: 0 — в кучу не ходили
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_bt WHERE id BETWEEN 1000 AND 2000;

-- Широкий диапазон по id — всё ещё Index Scan: строки в куче лежат в порядке id
-- (correlation = 1), поэтому чтение кучи идёт почти подряд и дёшево
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_bt WHERE id BETWEEN 1000 AND 60000;

SELECT attname, correlation FROM pg_stats
WHERE tablename = 'demo_bt' AND attname IN ('id', 'status', 'amount');

-- Bitmap Index Scan → Bitmap Heap Scan: четверть строк, разбросанных по куче.
-- Сначала из индекса собирается битовая карта страниц, потом страницы кучи
-- читаются по возрастанию номера, каждая один раз (Heap Blocks: exact=...)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_bt WHERE status = 'paid';

-- Seq Scan: условие отбирает три четверти таблицы — индекс бесполезен
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_bt WHERE status <> 'new';

-- ORDER BY ... LIMIT без сортировки: индекс уже упорядочен
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM demo_bt ORDER BY id DESC LIMIT 10;

-- ---------------------------------------------------------------------
-- 4. Skip scan (только PostgreSQL 18+): условие только по второй колонке
--    составного индекса. На PG 13–17 будет Seq Scan или полный просмотр индекса.
-- ---------------------------------------------------------------------
CREATE INDEX demo_bt_status_amount ON demo_bt (status, amount);
ANALYZE demo_bt;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_bt WHERE amount BETWEEN 100 AND 101;

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_bt;

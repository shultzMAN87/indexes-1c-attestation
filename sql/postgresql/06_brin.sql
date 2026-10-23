/* =====================================================================
   BRIN в PostgreSQL: сводки min/max по диапазонам блоков
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 14+ для части 4), не в базе 1С.
   Нужно расширение pageinspect (contrib).
   Таблицы по 5 млн строк: создание занимает до минуты.
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS pageinspect;

-- =====================================================================
-- Часть 1. Журнал событий: строки вставляются в порядке времени
-- =====================================================================
DROP TABLE IF EXISTS demo_log;
CREATE TABLE demo_log (
    id      bigint GENERATED ALWAYS AS IDENTITY,
    ts      timestamp NOT NULL,
    level   text,
    message text
);

-- 5 млн событий за 2024 год, по возрастанию времени
INSERT INTO demo_log (ts, level, message)
SELECT timestamp '2024-01-01' + g * interval '6 seconds',
       (ARRAY['INFO','INFO','INFO','WARN','ERROR'])[1 + g % 5],
       'event ' || g
FROM generate_series(1, 5000000) AS g;

CREATE INDEX demo_log_ts_btree ON demo_log USING btree (ts);
CREATE INDEX demo_log_ts_brin  ON demo_log USING brin  (ts);      -- pages_per_range = 128
VACUUM ANALYZE demo_log;

-- ---------------------------------------------------------------------
-- 1. Размер: BRIN хранит по одной сводке на 128 страниц таблицы
-- ---------------------------------------------------------------------
SELECT pg_size_pretty(pg_relation_size('demo_log'))          AS table_size,
       pg_size_pretty(pg_relation_size('demo_log_ts_btree')) AS btree_size,
       pg_size_pretty(pg_relation_size('demo_log_ts_brin'))  AS brin_size;

-- Корреляция физического порядка с ts: 1 — идеальный случай для BRIN
SELECT attname, correlation FROM pg_stats
WHERE tablename = 'demo_log' AND attname = 'ts';

-- ---------------------------------------------------------------------
-- 2. Что внутри: страница 0 — метастраница, 1 — карта диапазонов (revmap),
--    со 2-й — сами сводки. Каждая запись: номер первого блока диапазона
--    и {min .. max} значений ts в этих 128 страницах таблицы
-- ---------------------------------------------------------------------
SELECT pagesperrange, lastrevmappage
FROM brin_metapage_info(get_raw_page('demo_log_ts_brin', 0));

SELECT itemoffset, blknum AS first_heap_block, value AS min_max
FROM brin_page_items(get_raw_page('demo_log_ts_brin', 2), 'demo_log_ts_brin')
ORDER BY blknum
LIMIT 5;

-- ---------------------------------------------------------------------
-- 3. Поиск за один день: BRIN отбрасывает диапазоны, где дня быть не может,
--    остальные читает ЦЕЛИКОМ и перепроверяет каждую строку.
--    Смотреть: Heap Blocks: lossy=... и Rows Removed by Index Recheck
-- ---------------------------------------------------------------------
DROP INDEX demo_log_ts_btree;     -- чтобы планировщик взял BRIN

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_log
WHERE ts >= '2024-06-10' AND ts < '2024-06-11';

-- Без индекса — Seq Scan по всей таблице, для сравнения времени и Buffers
SET enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_log
WHERE ts >= '2024-06-10' AND ts < '2024-06-11';
RESET enable_bitmapscan;

-- =====================================================================
-- Часть 2. Те же данные, но строки перемешаны: BRIN бесполезен
-- =====================================================================
DROP TABLE IF EXISTS demo_log_shuffled;
CREATE TABLE demo_log_shuffled AS
SELECT * FROM demo_log ORDER BY random();
CREATE INDEX demo_log_shuffled_brin ON demo_log_shuffled USING brin (ts);
VACUUM ANALYZE demo_log_shuffled;

SELECT attname, correlation FROM pg_stats
WHERE tablename = 'demo_log_shuffled' AND attname = 'ts';        -- около 0

-- Каждый диапазон содержит даты почти за весь год
SELECT blknum AS first_heap_block, value AS min_max
FROM brin_page_items(get_raw_page('demo_log_shuffled_brin', 2), 'demo_log_shuffled_brin')
ORDER BY blknum
LIMIT 3;

-- Планировщик понимает это и выбирает Seq Scan
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_log_shuffled
WHERE ts >= '2024-06-10' AND ts < '2024-06-11';

-- =====================================================================
-- Часть 3. Новые строки: сводки для них появляются не сразу
-- =====================================================================
INSERT INTO demo_log (ts, level, message)
SELECT timestamp '2025-01-01' + g * interval '6 seconds', 'INFO', 'new ' || g
FROM generate_series(1, 200000) AS g;

-- Новые диапазоны блоков ещё не «подытожены»: BRIN читает их целиком при любом запросе.
-- Сводки создаёт VACUUM / autovacuum, функция brin_summarize_new_values,
-- или сразу — параметр индекса autosummarize = on
SELECT brin_summarize_new_values('demo_log_ts_brin') AS summarized_ranges;

-- =====================================================================
-- Часть 4. Варианты (PostgreSQL 14+): minmax_multi и bloom
-- =====================================================================
-- minmax_multi: несколько интервалов на диапазон — терпит «выбросы»
-- (отдельные строки с далёкими значениями не раздувают min/max до всего года)
CREATE INDEX demo_log_ts_brin_multi ON demo_log
    USING brin (ts timestamp_minmax_multi_ops);

-- bloom: для равенства по значениям без порядка (здесь — текст сообщения)
CREATE INDEX demo_log_message_brin_bloom ON demo_log
    USING brin (message text_bloom_ops);

SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'demo_log' ORDER BY indexrelname;

-- Плотность диапазонов: меньше pages_per_range — точнее, но индекс больше
-- CREATE INDEX ON demo_log USING brin (ts) WITH (pages_per_range = 32);

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_log; DROP TABLE demo_log_shuffled;

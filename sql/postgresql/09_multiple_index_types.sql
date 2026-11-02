-- =============================================================================
-- 09_multiple_index_types.sql — несколько индексов разных типов на одной таблице
-- К разделу 3.1 методички (подраздел «Несколько индексов разных типов на одной таблице»).
--
-- Что показывает:
--   1. На одной таблице одновременно B-tree, BRIN, GIN (массив, JSONB, триграммы)
--      и Hash — в том числе два индекса разных типов по одной колонке.
--   2. Планировщик выбирает индекс под оператор условия.
--   3. BitmapAnd / BitmapOr — объединение индексов разных типов в одном запросе.
--   4. Цена: каждый индекс — место и работа при записи.
--
-- Запускать в отдельной тестовой базе (не в базе 1С). Проверено на PostgreSQL 16.
-- Нужно расширение pg_trgm (стандартная поставка).
-- =============================================================================

\pset pager off
CREATE EXTENSION IF NOT EXISTS pg_trgm;
DROP SCHEMA IF EXISTS demo_multi CASCADE;
CREATE SCHEMA demo_multi;
SET search_path = demo_multi, public;

-- 1 млн «документов»: дата растёт вместе с порядком вставки (подходит для BRIN),
-- теги — массив, реквизиты — JSONB, заголовок — текст.
CREATE TABLE doc (
    id      bigint PRIMARY KEY,           -- B-tree: PRIMARY KEY/UNIQUE — только B-tree
    created timestamptz NOT NULL,
    title   text        NOT NULL,
    tags    text[]      NOT NULL,
    attrs   jsonb       NOT NULL
);

INSERT INTO doc
SELECT s,
       timestamptz '2026-01-01' + s * interval '30 second',
       'Документ ' || s || CASE WHEN s % 1000 = 0 THEN ' срочно согласовать' ELSE '' END,
       CASE WHEN s % 500 = 0 THEN ARRAY['срочно', 'склад'] ELSE ARRAY['обычный'] END,
       jsonb_build_object('org', s % 10, 'sklad', s % 100)
FROM generate_series(1, 1000000) AS s;

-- -----------------------------------------------------------------------------
-- 1. Индексы разных типов на одной таблице
-- -----------------------------------------------------------------------------
CREATE INDEX doc_created_brin  ON doc USING brin  (created);              -- диапазоны по дате, крошечный
CREATE INDEX doc_created_btree ON doc USING btree (created);              -- та же колонка: точный поиск, ORDER BY
CREATE INDEX doc_tags_gin      ON doc USING gin   (tags);                 -- массив: @>, &&
CREATE INDEX doc_attrs_gin     ON doc USING gin   (attrs jsonb_path_ops); -- JSONB: @>
CREATE INDEX doc_title_trgm    ON doc USING gin   (title gin_trgm_ops);   -- LIKE '%…%'
CREATE INDEX doc_title_hash    ON doc USING hash  (title);                -- только =
ANALYZE doc;

-- Все индексы таблицы, их тип и размер.
-- Ожидаемо: BRIN — десятки КБ, B-tree по той же колонке — десятки МБ.
SELECT i.relname                                  AS index_name,
       am.amname                                  AS index_type,
       pg_size_pretty(pg_relation_size(i.oid))    AS size
FROM pg_index x
JOIN pg_class i  ON i.oid = x.indexrelid
JOIN pg_am    am ON am.oid = i.relam
WHERE x.indrelid = 'doc'::regclass
ORDER BY pg_relation_size(i.oid) DESC;

-- -----------------------------------------------------------------------------
-- 2. Планировщик выбирает индекс под оператор
-- -----------------------------------------------------------------------------
-- Равенство по title: подходят и Hash, и (если бы был) B-tree. Ожидаемо: doc_title_hash.
EXPLAIN (COSTS OFF) SELECT * FROM doc WHERE title = 'Документ 777';

-- Подстрока: Hash и B-tree не умеют, работает только GIN по триграммам.
-- Ожидаемо: Bitmap Index Scan on doc_title_trgm.
EXPLAIN (COSTS OFF) SELECT * FROM doc WHERE title LIKE '%срочно%';

-- Массив: оператор @> есть только в классе GIN. Ожидаемо: doc_tags_gin.
EXPLAIN (COSTS OFF) SELECT * FROM doc WHERE tags @> ARRAY['срочно'];

-- Узкий диапазон дат: B-tree точнее. ORDER BY по дате — только B-tree даёт порядок.
-- Ожидаемо: Index Scan using doc_created_btree, без Sort.
EXPLAIN (COSTS OFF)
SELECT * FROM doc WHERE created >= '2026-03-01' ORDER BY created LIMIT 10;

-- Тот же запрос, если B-tree нет: остаётся BRIN (Bitmap Heap Scan, lossy) + Sort.
-- Индекс «выключаем» внутри транзакции и откатываем — сам индекс не трогаем.
BEGIN;
DROP INDEX doc_created_btree;
EXPLAIN (COSTS OFF)
SELECT * FROM doc WHERE created >= '2026-03-01' AND created < '2026-03-02';
ROLLBACK;

-- -----------------------------------------------------------------------------
-- 3. BitmapAnd / BitmapOr: несколько индексов разных типов в одном запросе
-- -----------------------------------------------------------------------------
-- Каждый индекс строит битовую карту подходящих страниц/строк, карты
-- пересекаются (AND) или объединяются (OR), затем таблица читается один раз
-- в физическом порядке (Bitmap Heap Scan). Условие перепроверяется в Recheck Cond.

-- У узлов BitmapAnd/BitmapOr в EXPLAIN ANALYZE всегда actual rows=0 — это норма:
-- они передают битовую карту, а не строки.

-- AND: диапазон дат (BRIN) + тег (GIN по массиву) — индексы двух разных типов.
-- Ожидаемо: BitmapAnd из doc_created_brin и doc_tags_gin. BRIN неточный
-- (Heap Blocks: lossy), поэтому лишние строки отсекает Recheck
-- (Rows Removed by Index Recheck).
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM doc
WHERE tags @> ARRAY['срочно']
  AND created >= '2026-03-01' AND created < '2026-04-01';

-- OR: равенство по заголовку (Hash) ИЛИ тег (GIN).
-- Без BitmapOr условие с ИЛИ по разным колонкам обычно означает Seq Scan.
-- Ожидаемо: BitmapOr из doc_title_hash и doc_tags_gin.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM doc
WHERE title = 'Документ 777'
   OR tags @> ARRAY['склад'];

-- AND по двум GIN-индексам разных классов операторов (массив и JSONB).
-- Ожидаемо: BitmapAnd из doc_attrs_gin и doc_tags_gin.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM doc
WHERE tags @> ARRAY['срочно']
  AND attrs @> '{"org": 0, "sklad": 0}';

-- -----------------------------------------------------------------------------
-- 4. Цена: каждый индекс обновляется при записи
-- -----------------------------------------------------------------------------
-- Вставка 100 000 строк в таблицу со всеми индексами и в копию без вторичных.
\timing on
CREATE TABLE doc_plain (LIKE doc INCLUDING DEFAULTS);
ALTER TABLE doc_plain ADD PRIMARY KEY (id);
INSERT INTO doc_plain SELECT id + 2000000, created, title, tags, attrs FROM doc WHERE id <= 100000;
INSERT INTO doc       SELECT id + 2000000, created, title, tags, attrs FROM doc WHERE id <= 100000;
\timing off
-- Ожидаемо: вставка в doc в несколько раз дольше — правятся все шесть индексов.
-- Индекс любой колонки также не даёт HOT-обновлений при изменении этой колонки (3.3).

-- Уборка
-- DROP SCHEMA demo_multi CASCADE;

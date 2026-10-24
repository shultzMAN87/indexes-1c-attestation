/* =====================================================================
   Как PostgreSQL хранит строки: страница, версия строки, TOAST
   К разделу 3.10 методички (docs/03-postgresql.md) и 5.11 (docs/05-1c.md)

   Запускать в отдельной тестовой базе (PostgreSQL 14+), не в базе 1С.
   Нужно расширение pageinspect (contrib).
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS pageinspect;

-- =====================================================================
-- Часть 1. Страница 8 КБ и версии строк на ней
-- =====================================================================
DROP TABLE IF EXISTS demo_page;
CREATE TABLE demo_page (
    id    int,
    code  varchar(20),
    price numeric(12,2)
);
INSERT INTO demo_page
SELECT g, 'CODE-' || g, g * 1.5 FROM generate_series(1, 1000) AS g;

-- Заголовок страницы (24 байта):
--   lower — где кончается массив указателей (растёт сверху вниз),
--   upper — где начинаются версии строк (растут снизу вверх),
--   между ними — свободное место
SELECT lower, upper, special, pagesize, upper - lower AS free_bytes
FROM page_header(get_raw_page('demo_page', 0));

-- Указатели (line pointers) и версии строк на странице 0:
--   lp       — номер указателя = вторая часть ctid
--   lp_off   — смещение версии строки от начала страницы
--   lp_len   — длина версии строки (заголовок 24 байта + данные)
--   t_xmin   — транзакция, создавшая версию (MVCC)
--   t_hoff   — размер заголовка версии строки
SELECT lp, lp_off, lp_len, t_xmin, t_xmax, t_ctid, t_hoff
FROM heap_page_items(get_raw_page('demo_page', 0))
LIMIT 5;

-- Сколько строк поместилось на страницу и сколько всего страниц
SELECT count(*) AS rows_on_page_0
FROM heap_page_items(get_raw_page('demo_page', 0));
SELECT pg_relation_size('demo_page') / 8192 AS pages;

-- UPDATE создаёт новую версию строки: у старой заполняется t_xmax,
-- t_ctid указывает на новую версию
UPDATE demo_page SET price = price + 1 WHERE id = 1;
SELECT lp, t_xmin, t_xmax, t_ctid
FROM heap_page_items(get_raw_page('demo_page', 0))
WHERE lp = 1 OR t_ctid <> ('(0,' || lp || ')')::tid;

-- =====================================================================
-- Часть 2. TOAST: длинные значения сжимаются и выносятся
-- =====================================================================
DROP VIEW  IF EXISTS demo_toast_chunks;
DROP TABLE IF EXISTS demo_toast;
CREATE TABLE demo_toast (
    id    int,
    note  text,      -- длинный текст
    blob  bytea      -- двоичные данные (как ХранилищеЗначения 1С)
);

-- Стратегии хранения колонок: p = PLAIN, m = MAIN, e = EXTERNAL, x = EXTENDED.
-- text и bytea по умолчанию EXTENDED: сначала сжать, не помогло — вынести
SELECT attname, atttypid::regtype, attstorage
FROM pg_attribute
WHERE attrelid = 'demo_toast'::regclass AND attnum > 0;

-- TOAST-таблица создаётся автоматически, если в таблице есть «длинные» колонки
SELECT c.relname AS table_name, t.relname AS toast_table,
       i.relname AS toast_index
FROM pg_class AS c
JOIN pg_class AS t ON t.oid = c.reltoastrelid
JOIN pg_index AS x ON x.indrelid = t.oid
JOIN pg_class AS i ON i.oid = x.indexrelid
WHERE c.relname = 'demo_toast';

-- Четыре строки:
--   1 — короткий текст (останется в строке)
--   2 — текст 200 КБ, хорошо сжимаемый (повторы)
--   3 — текст 200 КБ, плохо сжимаемый (случайные символы)
--   4 — ДВЕ большие колонки: текст 200 КБ + двоичные данные 500 КБ
INSERT INTO demo_toast VALUES
 (1, 'Короткий комментарий', NULL),
 (2, repeat('Индексы ускоряют чтение. ', 4452), NULL),   -- ~200 КБ: кириллица = 2 байта
 (3, (SELECT string_agg(md5(g::text), '') FROM generate_series(1, 6400) AS g), NULL),
 (4, (SELECT string_agg(md5((g * 3)::text), '') FROM generate_series(1, 6400) AS g),
     (SELECT decode(string_agg(md5((g * 7)::text), ''), 'hex') FROM generate_series(1, 32000) AS g));

-- Логический размер (octet_length) и сколько реально занято (pg_column_size),
-- и чем сжато (pg_column_compression; NULL — не сжато)
SELECT id,
       octet_length(note)          AS note_bytes,
       pg_column_size(note)        AS note_stored,
       pg_column_compression(note) AS note_compr,
       octet_length(blob)          AS blob_bytes,
       pg_column_size(blob)        AS blob_stored
FROM demo_toast ORDER BY id;

-- Сама версия строки в куче остаётся маленькой: вместо значения — указатель 18 байт
SELECT lp, lp_len AS tuple_bytes_in_heap
FROM heap_page_items(get_raw_page('demo_toast', 0));

-- Куски (chunks) в TOAST-таблице: chunk_id — какое значение, chunk_seq — номер куска.
-- Кусок — до ~2 КБ (TOAST_MAX_CHUNK_SIZE = 1996 байт при странице 8 КБ),
-- примерно 4 куска на страницу TOAST-таблицы
DO $$
DECLARE t text;
BEGIN
  SELECT reltoastrelid::regclass::text INTO t FROM pg_class WHERE relname = 'demo_toast';
  RAISE NOTICE 'TOAST-таблица: %', t;
  EXECUTE format('CREATE OR REPLACE VIEW demo_toast_chunks AS
                  SELECT chunk_id, count(*) AS chunks, sum(length(chunk_data)) AS bytes,
                         max(length(chunk_data)) AS max_chunk
                  FROM %s GROUP BY chunk_id', t);
END $$;

SELECT * FROM demo_toast_chunks ORDER BY chunk_id;
-- Результат на PostgreSQL 16:
--   строка 2: 200 КБ повторяющегося текста сжались pglz до 2 400 байт — 2 куска;
--   строка 3: 200 КБ случайного текста не сжались — 103 куска;
--   строка 4: текст — 103 куска, bytea 500 КБ — 257 кусков, у каждой колонки свой chunk_id.
--   Куча — 1 страница (8 КБ), TOAST-таблица — ~930 КБ

SELECT pg_size_pretty(pg_relation_size('demo_toast'))                 AS heap,
       pg_size_pretty(pg_relation_size(reltoastrelid))                AS toast,
       pg_size_pretty(pg_total_relation_size('demo_toast'))           AS total
FROM pg_class WHERE relname = 'demo_toast';

-- =====================================================================
-- Часть 3. Что читается при запросе
--   Смотрим Buffers в плане: страницы TOAST-таблицы и её индекса считаются там же.
--   ВАЖНО: EXPLAIN ANALYZE не передаёт результат клиенту и поэтому НЕ распаковывает
--   длинные значения в списке выборки. Чтобы увидеть чтение TOAST, значение
--   должно понадобиться самому запросу — в условии или в функции (md5, length…).
-- =====================================================================
-- 3.1. Длинные колонки не нужны — TOAST не читается (1 страница кучи)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_toast;

-- 3.2. Нужны значения обеих больших колонок строки 4: читаются ВСЕ куски
--      (360 кусков ≈ 90 страниц TOAST + страницы её индекса; на PG 16 — 96 буферов)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT md5(note), md5(blob) FROM demo_toast WHERE id = 4;

-- 3.3. LIKE '%...%' по длинному тексту: значение каждой строки собирается
--      из кусков и распаковывается ЦЕЛИКОМ, потом в нём ищется подстрока.
--      Совпадения нет — значит, каждое значение прочитано полностью
--      (на PG 16 — 61 буфер: все куски колонки note всех строк).
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_toast WHERE note LIKE '%zzzz%';

-- 3.4. Начало строки по НЕсжатому значению (строка 3 не сжалась):
--      substr читает только первый кусок — 4 буфера (куча + индекс TOAST + 1 страница)
--      вместо ~30 для всего значения
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT substr(note, 1, 100) FROM demo_toast WHERE id = 3;

-- 3.5. То же по СЖАТОМУ значению (строка 2): нужно распаковать начало.
--      PostgreSQL 12+ умеет распаковывать pglz частично (только начало),
--      но куски читаются с первого. Здесь значение сжато до 2 кусков — дёшево в любом случае
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT substr(note, 1, 100) FROM demo_toast WHERE id = 2;

-- 3.6. Стратегия EXTERNAL: выносить без сжатия — частичное чтение гарантировано,
--      но ценой места: строка 2 займёт ~200 КБ вместо 2,4 КБ.
--      Имеет смысл для больших текстов, которые часто читают кусками (substr)
ALTER TABLE demo_toast ALTER COLUMN note SET STORAGE EXTERNAL;   -- действует на новые значения
UPDATE demo_toast SET note = note || '' WHERE id = 2;            -- переписать значение строки 2
SELECT id, pg_column_size(note) AS note_stored, pg_column_compression(note) AS compr
FROM demo_toast WHERE id = 2;                                     -- теперь не сжато: ~200 КБ
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT substr(note, 1, 100) FROM demo_toast WHERE id = 2;

-- =====================================================================
-- Часть 4. UPDATE короткой колонки не переписывает TOAST
-- =====================================================================
ALTER TABLE demo_toast ADD COLUMN status int DEFAULT 0;
SELECT pg_relation_size(reltoastrelid) AS toast_before FROM pg_class WHERE relname = 'demo_toast';
UPDATE demo_toast SET status = 1 WHERE id = 4;     -- новая версия строки ссылается на те же куски
SELECT pg_relation_size(reltoastrelid) AS toast_after  FROM pg_class WHERE relname = 'demo_toast';

-- =====================================================================
-- Часть 5. Индекс по содержимому длинного текста: GIN по триграммам
--   Индекс хранит триграммы, а не текст. Он отбирает строки-кандидаты,
--   и TOAST читается только у них. Нужно расширение pg_trgm (contrib).
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP TABLE IF EXISTS demo_long;
CREATE TABLE demo_long (id int, note text);
-- 200 строк по ~50 КБ несжимаемого текста; в одной — искомая фраза
INSERT INTO demo_long
SELECT g, (SELECT string_agg(md5((g * 100000 + k)::text), '') FROM generate_series(1, 1600) AS k)
FROM generate_series(1, 200) AS g;
UPDATE demo_long SET note = note || ' договор №777 ' WHERE id = 50;
VACUUM ANALYZE demo_long;

SELECT pg_size_pretty(pg_relation_size('demo_long'))     AS heap,     -- ~16 КБ
       pg_size_pretty(pg_relation_size(reltoastrelid))   AS toast     -- ~10 МБ
FROM pg_class WHERE relname = 'demo_long';

-- 5.1. Без индекса: распаковать все значения (на PG 16 — ~1 800 буферов)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_long WHERE note LIKE '%договор №777%';

CREATE INDEX demo_long_trgm ON demo_long USING gin (note gin_trgm_ops);
ANALYZE demo_long;

-- 5.2. ПОДВОХ: индекс есть, а планировщик всё равно выбирает Seq Scan.
--      В стоимость Seq Scan входят только 2 страницы кучи (cost ≈ 4,5),
--      чтение и распаковка 10 МБ TOAST в оценку не попадают
EXPLAIN SELECT id FROM demo_long WHERE note LIKE '%договор №777%';

-- 5.3. Через индекс (принудительно): ~30 буферов вместо ~1 800 —
--      TOAST прочитан только у одной найденной строки (Recheck)
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id FROM demo_long WHERE note LIKE '%договор №777%';
RESET enable_seqscan;

-- 5.4. Короткий шаблон: в '%ab%' нет ни одной полной триграммы —
--      индекс ничего не отсекает
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_long WHERE note LIKE '%ab%';
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP VIEW demo_toast_chunks; DROP TABLE demo_toast; DROP TABLE demo_page; DROP TABLE demo_long;

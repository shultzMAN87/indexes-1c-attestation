/* =====================================================================
   GIN в PostgreSQL: инвертированный индекс по элементам значения
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 13+), не в базе 1С.
   Нужны расширения pageinspect и pg_trgm (оба — contrib).
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP TABLE IF EXISTS demo_gin;
CREATE TABLE demo_gin (
    id     int GENERATED ALWAYS AS IDENTITY,
    title  text,           -- название товара
    tags   text[],         -- массив меток
    attrs  jsonb           -- произвольные свойства
);

INSERT INTO demo_gin (title, tags, attrs)
SELECT (ARRAY['Ноутбук','Смартфон','Наушники','Монитор','Клавиатура'])[1 + g % 5]
         || ' модель ' || md5(g::text),
       ARRAY[(ARRAY['новинка','скидка','хит','premium','eco'])[1 + g % 5],
             (ARRAY['красный','чёрный','белый'])[1 + g % 3]],
       jsonb_build_object('brand', (ARRAY['Acme','Globex','Initech','Umbrella'])[1 + g % 4],
                          'warranty', 12 + 12 * (g % 3),
                          'wifi', g % 2 = 0)
       || CASE WHEN g % 100 = 0 THEN '{"promo": true}'::jsonb ELSE '{}'::jsonb END   -- редкий ключ
FROM generate_series(1, 300000) AS g;

CREATE INDEX demo_gin_tags  ON demo_gin USING gin (tags);
CREATE INDEX demo_gin_attrs ON demo_gin USING gin (attrs);                    -- jsonb_ops
CREATE INDEX demo_gin_attrs_path ON demo_gin USING gin (attrs jsonb_path_ops);
CREATE INDEX demo_gin_title_trgm ON demo_gin USING gin (title gin_trgm_ops);  -- триграммы
VACUUM ANALYZE demo_gin;

-- ---------------------------------------------------------------------
-- 1. Идея: из каждого значения извлекаются ЭЛЕМЕНТЫ (ключи),
--    и для каждого ключа хранится список строк, где он встречается
-- ---------------------------------------------------------------------
-- Какие ключи GIN получает из одного значения:
SELECT tags AS array_value,                      -- ключи массива — его элементы
       attrs AS jsonb_value                      -- ключи jsonb_ops — имена и значения
FROM demo_gin WHERE id = 1;

-- Триграммы — тройки символов строки (ключи индекса gin_trgm_ops)
SELECT show_trgm('c4ca4238') AS trigrams;

-- Метастраница: число страниц записей (entry) и страниц списков (data),
-- число различных ключей и размер «отложенного списка» (pending list)
SELECT n_entry_pages, n_data_pages, n_entries, n_pending_pages, n_pending_tuples
FROM gin_metapage_info(get_raw_page('demo_gin_tags', 0));
-- n_entries = 8: на 300 тыс. строк всего 8 различных меток.
-- Индекс — это 8 ключей и 8 длинных (сжатых) списков ctid.

-- Размеры: jsonb_path_ops компактнее jsonb_ops; триграммный индекс — самый большой
-- (из каждой строки извлекаются десятки триграмм)
SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'demo_gin' ORDER BY indexrelname;

-- ---------------------------------------------------------------------
-- 2. Запросы. GIN всегда работает через битовую карту:
--    берёт списки строк для каждого ключа условия и пересекает/объединяет их
-- ---------------------------------------------------------------------
-- Массив содержит обе метки (пересечение двух списков)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_gin WHERE tags @> ARRAY['хит', 'белый'];

-- Тот же смысл, но другой оператор: = ANY не входит в класс операторов array_ops,
-- поэтому индекс НЕ используется (Seq Scan)
EXPLAIN (COSTS OFF)
SELECT count(*) FROM demo_gin WHERE 'хит' = ANY (tags);

EXPLAIN (COSTS OFF)
SELECT count(*) FROM demo_gin WHERE tags @> ARRAY['хит'];   -- а так — Bitmap Index Scan

-- jsonb: документ содержит пару ключ-значение
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM demo_gin WHERE attrs @> '{"brand": "Acme", "warranty": 36}';

-- jsonb: есть ли ключ — только jsonb_ops (jsonb_path_ops этот оператор не умеет)
EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM demo_gin WHERE attrs ? 'promo';

-- Поиск по подстроке (ведущий %!) — B-tree здесь бессилен, триграммы справляются
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_gin WHERE title LIKE '%c4ca4238%';

-- То же без учёта регистра
EXPLAIN (COSTS OFF)
SELECT * FROM demo_gin WHERE title ILIKE '%НОУТБУК модель c4ca%';

-- ---------------------------------------------------------------------
-- 3. Полнотекстовый поиск: ключи — лексемы (нормализованные слова)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS demo_fts;
CREATE TABLE demo_fts (id int GENERATED ALWAYS AS IDENTITY, body text, tsv tsvector);
INSERT INTO demo_fts (body)
SELECT (ARRAY['Индекс ускоряет поиск строк в таблице',
              'Индексы замедляют запись в базу данных',
              'Секционирование делит большую таблицу на части',
              'Статистика нужна оптимизатору для выбора плана'])[1 + g % 4] || ' №' || g
FROM generate_series(1, 200000) AS g;
UPDATE demo_fts SET tsv = to_tsvector('russian', body);
CREATE INDEX demo_fts_tsv ON demo_fts USING gin (tsv);
VACUUM ANALYZE demo_fts;

-- Лексемы: «Индексы», «индекс» → одна лексема «индекс»
SELECT to_tsvector('russian', 'Индексы замедляют запись в базу данных');

EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM demo_fts WHERE tsv @@ to_tsquery('russian', 'индекс & таблица');

-- ---------------------------------------------------------------------
-- 4. Цена записи и pending list (fastupdate)
--    Одна строка добавляет записи во МНОГО списков (по числу её элементов).
--    Чтобы вставка была быстрой, новые записи сначала копятся в
--    неупорядоченном «отложенном списке» и переносятся в дерево
--    пачкой — при VACUUM, при переполнении gin_pending_list_limit
--    или функцией gin_clean_pending_list.
-- ---------------------------------------------------------------------
INSERT INTO demo_gin (title, tags, attrs)
SELECT 'Новый товар ' || g, ARRAY['новинка','красный'], '{"brand":"Acme"}'
FROM generate_series(1, 2000) AS g;

SELECT n_pending_pages, n_pending_tuples
FROM gin_metapage_info(get_raw_page('demo_gin_tags', 0));     -- записи ждут в pending list

SELECT gin_clean_pending_list('demo_gin_tags') AS moved_pages;

SELECT n_pending_pages, n_pending_tuples
FROM gin_metapage_info(get_raw_page('demo_gin_tags', 0));     -- 0: перенесены в дерево

-- Сравнить скорость вставки с fastupdate и без можно так:
-- ALTER INDEX demo_gin_tags SET (fastupdate = off);
-- \timing on  (в psql)  и повторить INSERT выше

-- ---------------------------------------------------------------------
-- 5. Откуда берутся лишние строки (Rows Removed by Index Recheck)
--    Recheck Cond есть в любом Bitmap Heap Scan, но строки отбрасываются,
--    только когда индекс вернул кандидатов «с запасом». Три причины.
-- ---------------------------------------------------------------------
VACUUM demo_gin;   -- перенести pending list после части 4 (отдельной командой)

-- 5.1. @> по массиву точен: перепроверка ничего не отбрасывает
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_gin WHERE tags @> ARRAY['хит', 'белый'];
-- Bitmap Index Scan: rows=20000, Rows Removed by Index Recheck — нет

-- 5.2. Причина 1: оператор не проверить по ключам.
--      <@ «все метки строки входят в набор»: индекс берёт ОБЪЕДИНЕНИЕ списков
--      хит, белый, eco (строки, где есть хотя бы одна из них), а «нет ли
--      в строке ЛИШНИХ меток» проверяется только в куче
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_gin WHERE tags <@ ARRAY['хит', 'белый', 'eco'];
-- PG 16: Bitmap Index Scan rows=180000, Rows Removed by Index Recheck: 140000,
--        в результате 40000

-- 5.3. Причина 2: jsonb_ops хранит имена ключей и значения ОТДЕЛЬНЫМИ элементами.
--      {"color":"красный","case":"синий"} содержит и элемент color, и элемент синий,
--      хотя пары color = синий в нём нет — это кандидат, его отсеет перепроверка.
--      jsonb_path_ops хранит хеш пары «путь + значение» и такой ошибки не делает.
DROP TABLE IF EXISTS demo_json;
CREATE TABLE demo_json (id int GENERATED ALWAYS AS IDENTITY, attrs jsonb);
INSERT INTO demo_json (attrs)
SELECT CASE WHEN g % 2 = 0 THEN '{"color":"красный","case":"синий"}'::jsonb
            ELSE '{"color":"синий","case":"чёрный"}'::jsonb END
FROM generate_series(1, 100000) AS g;
CREATE INDEX demo_json_ops  ON demo_json USING gin (attrs);                 -- jsonb_ops
CREATE INDEX demo_json_path ON demo_json USING gin (attrs jsonb_path_ops);
VACUUM ANALYZE demo_json;

SET enable_seqscan = off;   -- только для демонстрации: половина таблицы подходит

BEGIN;
DROP INDEX demo_json_path;  -- оставить только jsonb_ops (откатится)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_json WHERE attrs @> '{"color": "синий"}';
ROLLBACK;
-- PG 16: Bitmap Index Scan rows=100000, Rows Removed by Index Recheck: 50000

BEGIN;
DROP INDEX demo_json_ops;   -- оставить только jsonb_path_ops (откатится)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_json WHERE attrs @> '{"color": "синий"}';
ROLLBACK;
-- PG 16: Bitmap Index Scan rows=50000, лишних строк нет

-- 5.4. Причина 3: битовая карта не поместилась в work_mem и стала
--      неточной (lossy): для части страниц хранится только номер страницы,
--      и перепроверяются ВСЕ строки этих страниц
SET work_mem = '64kB';
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_gin WHERE tags @> ARRAY['хит'];
-- PG 16: Heap Blocks: exact=398 lossy=3997, Rows Removed by Index Recheck — десятки тысяч
RESET work_mem;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_gin WHERE tags @> ARRAY['хит'];
-- с обычным work_mem: Heap Blocks: exact=7895, лишних строк нет
RESET enable_seqscan;

-- 5.5. Селективность: GIN силён, когда хотя бы один ключ запроса редкий
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_gin WHERE attrs @> '{"promo": true}';
-- 1 % строк: Bitmap Index Scan — Buffers: shared hit=3

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_gin; DROP TABLE demo_fts; DROP TABLE demo_json;

/* =====================================================================
   Hash-индекс PostgreSQL: корзины, хеш-коды, только равенство
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 10+), не в базе 1С.
   Нужно расширение pageinspect (contrib).
   ===================================================================== */

CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS demo_hash;
CREATE TABLE demo_hash (
    id  bigint GENERATED ALWAYS AS IDENTITY,
    url text NOT NULL                 -- длинные строки: здесь hash выигрывает
);

-- 500 тыс. URL длиной ~100 символов
INSERT INTO demo_hash (url)
SELECT 'https://example.com/catalog/' || md5(g::text) || '/' || md5((g * 7)::text) || '?page=' || g
FROM generate_series(1, 500000) AS g;

CREATE INDEX demo_hash_url_btree ON demo_hash USING btree (url);
CREATE INDEX demo_hash_url_hash  ON demo_hash USING hash  (url);
ANALYZE demo_hash;

-- ---------------------------------------------------------------------
-- 1. Размер: hash хранит 4-байтовый хеш-код вместо самой строки
-- ---------------------------------------------------------------------
SELECT avg(length(url))::int AS avg_url_length FROM demo_hash;

SELECT indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'demo_hash';

-- ---------------------------------------------------------------------
-- 2. Что внутри
-- ---------------------------------------------------------------------
-- Метастраница: число корзин (maxbucket + 1), маски для вычисления номера корзины
SELECT maxbucket + 1 AS buckets, highmask, lowmask, ntuples, ffactor
FROM hash_metapage_info(get_raw_page('demo_hash_url_hash', 0));

-- Типы страниц: m — метастраница, b — корзина, o — страница переполнения, v — битовая карта
SELECT hash_page_type(get_raw_page('demo_hash_url_hash', n)) AS page_type, count(*)
FROM generate_series(0, pg_relation_size('demo_hash_url_hash') / 8192 - 1) AS n
GROUP BY 1 ORDER BY 1;

-- Записи в корзине: только хеш-код (32 бита) и ctid строки, самой строки нет
SELECT itemoffset, ctid AS heap_tid, data AS hash_code
FROM hash_page_items(get_raw_page('demo_hash_url_hash', 1))
LIMIT 5;

-- Хеш-функция, которой пользуется индекс для text
SELECT url, hashtext(url) AS hash_code
FROM demo_hash WHERE id = 1;

-- ---------------------------------------------------------------------
-- 3. Что умеет и чего не умеет
-- ---------------------------------------------------------------------
-- Чтобы планировщик выбирал между двумя индексами, временно уберём B-tree
DROP INDEX demo_hash_url_btree;

-- Равенство — Index Scan по hash. Rows Removed by Index Recheck появился бы
-- при совпадении хеш-кодов у разных строк (коллизии): строка перепроверяется в куче
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_hash
WHERE url = 'https://example.com/catalog/' || md5('250000') || '/' || md5('1750000') || '?page=250000';

-- Диапазон и префикс — hash бесполезен: порядка значений в нём нет → Seq Scan
EXPLAIN (COSTS OFF)
SELECT * FROM demo_hash WHERE url > 'https://example.com/catalog/f';

EXPLAIN (COSTS OFF)
SELECT * FROM demo_hash WHERE url LIKE 'https://example.com/catalog/ff%';

-- Сортировка — тоже нет
EXPLAIN (COSTS OFF)
SELECT * FROM demo_hash ORDER BY url LIMIT 10;

-- Ошибки (раскомментируйте, чтобы увидеть):
-- CREATE UNIQUE INDEX ON demo_hash USING hash (url);       -- hash не поддерживает UNIQUE
-- CREATE INDEX ON demo_hash USING hash (url, id);          -- и составные ключи

-- Зато поддерживает EXCLUDE с оператором =  (то есть уникальность другим способом)
ALTER TABLE demo_hash ADD CONSTRAINT demo_hash_url_excl EXCLUDE USING hash (url WITH =);

-- ---------------------------------------------------------------------
-- Уборка
-- ---------------------------------------------------------------------
-- DROP TABLE demo_hash;

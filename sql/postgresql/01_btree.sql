/* =====================================================================
   B-tree в PostgreSQL: что внутри и чем он отличается от MS SQL
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 13+), не в базе 1С.
   Нужно расширение pageinspect (входит в стандартную поставку, contrib).

   В pgAdmin выполняйте скрипт по частям или через PSQL Tool (\i путь/к/файлу):
   если запустить всё одним пакетом, PostgreSQL выполнит его одной транзакцией,
   а VACUUM внутри транзакции запрещён — ошибка «VACUUM cannot run inside
   a transaction block», и откатится всё, что было в пакете.
   Строку VACUUM ANALYZE выполняйте отдельно.
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
-- Выполнить отдельной командой (в pgAdmin — выделить строку и запустить):
VACUUM ANALYZE demo_bt;       -- обновить карту видимости (нужна Index Only Scan)

-- ---------------------------------------------------------------------
-- 1. Устройство дерева: метастраница → корень → внутренние → листья
--
-- Ниже у каждого запроса — что вы увидите и как это читать.
-- Цифры — с прогона на PostgreSQL 16, 1 млн строк, свежая таблица (id с 1).
--
-- Если id в вашей таблице начинаются не с 1, а, например, с 1 000 001 —
-- значит, первый INSERT откатился (например, из-за ошибки VACUUM в одном
-- пакете с ним), а значения IDENTITY при откате не возвращаются.
-- Проверить: SELECT min(id), max(id) FROM demo_bt;
-- ---------------------------------------------------------------------

-- 1.1. Метастраница (блок 0 файла индекса) — «паспорт» дерева.
-- Ожидаемо: root_block = 290, root_level = 2, fastroot = 290, fastlevel = 2.
--   root_level — уровень корня; листья — уровень 0. Уровень 2 = три уровня:
--     корень → внутренние страницы → листья. Любой поиск читает 3 страницы
--     (логарифмический поиск, раздел 1.2).
--   Корень на странице 290, а не 1: CREATE INDEX строит дерево снизу вверх,
--     сначала пишет листья и внутренние страницы, корень — последним.
--   fastroot/fastlevel — с какой страницы реально начинать спуск. Отличаются
--     от root/level, только если после массовых удалений верх дерева
--     выродился в цепочку страниц с одной ссылкой.
SELECT root AS root_block, level AS root_level, fastroot, fastlevel
FROM bt_metap('demo_bt_id');

-- 1.2. Корень: ключи-границы и ссылки на дочерние страницы.
-- Ожидаемо (первые 5 строк):
--   itemoffset | child_page | data
--   1          | (3,0)      |                          ← «минус бесконечность»
--   2          | (289,1)    | 09 96 01 00 00 00 00 00  ← 104 969
--   3          | (575,1)    | 11 2c 03 00 00 00 00 00  ← 209 937
--   4          | (860,1)    | 19 c2 04 00 00 00 00 00  ← 314 905
--   5          | (1145,1)   | 21 58 06 00 00 00 00 00  ← 419 873
-- Как читать:
--   ctid во внутренней странице — НЕ адрес строки таблицы. Первое число —
--     номер дочерней страницы индекса. Второе — служебное: сколько колонок
--     ключа сохранено (1); у первой записи 0 — ключ отброшен.
--   Первая запись без ключа — ссылка «для всего, что меньше следующей
--     границы»: левый край дерева ключа не хранит.
--   data — ключ в байтах. bigint = 8 байт, little-endian (младший байт первым):
--     09 96 01 00 00 00 00 00 читается справа налево: 0x00019609 = 104 969.
--   Страница 3 получает ключи < 104 969, страница 289 — от 104 969 до 209 937
--     и т. д. Шаг ~104 968 ключей = столько ключей под одной внутренней страницей.
--   Поиск id = 250 000: 209 937 ≤ 250 000 < 314 905 → спуск на страницу 575.
SELECT itemoffset, ctid AS child_page, data
FROM bt_page_items('demo_bt_id', (SELECT root FROM bt_metap('demo_bt_id')))
LIMIT 5;

-- 1.3. Внутренняя страница (блок 3) — промежуточный уровень.
-- Ожидаемо:
--   1 | (286,1) | 09 96 01 00 …  ← high key = 104 969: верхняя граница страницы
--   2 | (1,0)   |                ← «минус бесконечность» → лист 1
--   3 | (2,1)   | 6f 01 00 00 …  ← ключи от 367 → лист 2
-- Как читать:
--   Первая запись на любой странице, кроме самой правой на своём уровне, —
--     high key: все ключи этой страницы меньше него. Его ctid — служебный,
--     ни на что не указывает (сравните: страница справа — 289, а не 286).
--   Дальше — такие же «граница + ссылка», только ссылки ведут на листья.
--   High key этой страницы равен границе для страницы 289 в корне —
--     так соседние страницы одного уровня «стыкуются».
SELECT itemoffset, ctid, data
FROM bt_page_items('demo_bt_id', 3)
LIMIT 3;

-- 1.4. Лист (блок 1): ключ + ctid — адрес строки в куче.
-- Ожидаемо:
--   itemoffset | heap_tid | data
--   1          | (2,1)    | 6f 01 00 00 00 00 00 00  ← high key = 367
--   2          | (0,1)    | 01 00 00 00 00 00 00 00  ← id 1 → куча: стр. 0, указатель 1
--   3          | (0,2)    | 02 00 00 00 00 00 00 00  ← id 2 → стр. 0, указатель 2
--   4          | (0,3)    | 03 00 00 00 00 00 00 00
--   5          | (0,4)    | 04 00 00 00 00 00 00 00
-- Как читать:
--   Главное: в листе лежит ключ и ctid = (страница кучи, номер указателя) —
--     физический адрес версии строки. В MS SQL на этом месте лежал бы ключ
--     кластерного индекса (раздел 3.2). Поэтому каждый UPDATE, который не
--     стал HOT, добавляет запись в индекс: у новой версии новый ctid (3.3).
--   Первая запись — high key = 367: на странице ключи 1…366, ключ 367 и
--     больше — правее. Его ctid (2,1) — служебный. Ловушка: запрос
--     «найти строку по ctid high key» вернёт случайную строку (id 315).
--   366 ключей на лист: запись 16 байт (8 — заголовок записи индекса,
--     8 — bigint) + 4 байта указатель; fillfactor B-tree по умолчанию 90,
--     поэтому лист при построении заполнен на 90%.
SELECT itemoffset, ctid AS heap_tid, data
FROM bt_page_items('demo_bt_id', 1)
LIMIT 5;

-- Проверка: ctid из листа — это действительно адрес строки в куче.
-- Ожидаемо: (0,1) → id 1, (0,2) → id 2. На странице кучи 157 строк,
-- поэтому (1,1) → id 158, (2,1) → id 315.
SELECT ctid, id, status, amount
FROM demo_bt
WHERE ctid IN ('(0,1)', '(0,2)', '(1,1)', '(2,1)');

-- 1.5. Статистика страниц трёх уровней.
-- Ожидаемо:
--   blkno | type | live_items | free_size | btpo_prev | btpo_next | btpo_level
--   290   | r    | 10         | 7956      | 0         | 0         | 2
--   3     | i    | 285        | 2456      | 0         | 289       | 1
--   1     | l    | 367        | 808       | 0         | 2         | 0
-- Как читать:
--   type: r — корень, i — внутренняя, l — лист.
--   Корень: 10 записей = 10 внутренних страниц; почти пустой (7 956 байт свободно).
--   Внутренняя: 285 записей (high key + ссылки на листья); свободно ~30% —
--     внутренние страницы при построении заполняются на 70%.
--   Лист: 367 записей = 366 ключей + high key; свободно 808 байт ≈ 10% (fillfactor 90).
--   btpo_prev / btpo_next — соседи на том же уровне. 0 — соседа нет
--     (блок 0 — метастраница, ссылкой быть не может). Лист 1 — самый левый,
--     следующий — лист 2. Листья связаны списком, поэтому диапазон и ORDER BY
--     читаются по цепочке без возврата к корню.
--   Проверка арифметики: 10 внутренних × ~285 листьев × 366 ключей ≈ 1 млн.
SELECT blkno, type, live_items, avg_item_size, free_size, btpo_prev, btpo_next, btpo_level
FROM bt_page_stats('demo_bt_id', (SELECT root FROM bt_metap('demo_bt_id')))
UNION ALL
SELECT blkno, type, live_items, avg_item_size, free_size, btpo_prev, btpo_next, btpo_level
FROM bt_page_stats('demo_bt_id', 3)
UNION ALL
SELECT blkno, type, live_items, avg_item_size, free_size, btpo_prev, btpo_next, btpo_level
FROM bt_page_stats('demo_bt_id', 1);

-- 1.6. Самый правый лист — последняя страница файла.
-- Ожидаемо: type = l, live_items — меньше 367 (здесь 88), btpo_next = 0.
-- У самой правой страницы уровня high key нет: справа ничего, граница — +∞.
-- Размер индекса: 2 745 страниц = метастраница + корень + 10 внутренних + 2 733 листа.
SELECT pg_relation_size('demo_bt_id') / 8192 AS index_pages;

SELECT blkno, type, live_items, free_size, btpo_prev, btpo_next
FROM bt_page_stats('demo_bt_id', (pg_relation_size('demo_bt_id') / 8192 - 1)::int);

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

-- Bitmap Index Scan → Bitmap Heap Scan: строки разбросаны по куче.
-- Сначала из индекса собирается битовая карта страниц, потом страницы кучи
-- читаются по возрастанию номера, каждая один раз (Heap Blocks: exact=...).
-- Индекс по amount создаём только для этого примера и сразу удаляем,
-- чтобы он не мешал примеру со skip scan в разделе 4.
CREATE INDEX demo_bt_amount ON demo_bt (amount);
ANALYZE demo_bt;

-- ~0,1% строк (около 1 000), разбросанных по ~960 страницам из 6 370.
-- Ожидаемо: Bitmap Index Scan on demo_bt_amount → Bitmap Heap Scan,
-- Heap Blocks: exact≈960 — читается только часть страниц, по порядку номеров.
-- Index Scan здесь хуже: 1 000 случайных чтений кучи в порядке ключа,
-- одна и та же страница могла бы читаться повторно.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM demo_bt WHERE amount BETWEEN 100 AND 110;

DROP INDEX demo_bt_amount;

-- Пограничный случай: четверть таблицы, status = 'paid'.
-- Значения status чередуются через строку, поэтому 'paid' есть на КАЖДОЙ
-- странице кучи: Bitmap Heap Scan всё равно прочитает все 6 370 страниц
-- (плюс ~200 страниц индекса) и выигрывает у Seq Scan только тем, что
-- проверяет условие не у всех строк. Стоимости близки (на PG 16:
-- Bitmap ≈ 12 300, Seq Scan ≈ 18 900), и в зависимости от версии и настроек
-- (random_page_cost, effective_io_concurrency, work_mem) планировщик выбирает
-- и то и другое. Оба плана правильные — вывод: при большой доле строк
-- индекс почти ничего не даёт (раздел 1.4).
-- Если увидели Seq Scan, сравните стоимости (COSTS ON):
--   SET enable_seqscan = off;  EXPLAIN SELECT * FROM demo_bt WHERE status = 'paid';
--   RESET enable_seqscan;
-- Индекс по status создаётся в разделе 2 (demo_bt_status_dedup) — без него
-- вариантов, кроме Seq Scan, нет.
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

-- =============================================================================
-- 10_physical_files.sql — где лежат файлы таблицы и индекса и как прочитать
-- страницу «как есть»: заголовок, указатели, версии строк, байты колонок,
-- карта видимости, карта свободного места.
-- К разделам 3.3 и 3.10 методички.
--
-- Что показывает:
--   1. Путь к файлам таблицы и индекса, слои (main / fsm / vm), сегменты по 1 ГБ.
--   2. Страница из файла на диске (pg_read_binary_file) и та же страница из
--      буферного кэша (get_raw_page) — байт в байт после CHECKPOINT.
--   3. Разбор страницы кучи: заголовок, указатели, версии строк, флаги, байты колонок.
--   4. UPDATE «вживую»: старая версия остаётся на странице, xmax и t_ctid
--      указывают на новую; бит в карте видимости сбрасывается.
--   5. Карта видимости (pg_visibility) и карта свободного места (pg_freespacemap).
--
-- Запускать в отдельной тестовой базе (не в базе 1С). Проверено на PostgreSQL 16.
-- Расширения из стандартной поставки: pageinspect, pg_visibility, pg_freespacemap.
-- pg_read_binary_file и CHECKPOINT требуют прав суперпользователя
-- (или ролей pg_read_server_files / pg_checkpoint).
--
-- В pgAdmin выполняйте скрипт по частям или через PSQL Tool (\i путь/к/файлу):
-- VACUUM нельзя запускать в одном пакете с другими командами.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_visibility;
CREATE EXTENSION IF NOT EXISTS pg_freespacemap;

DROP TABLE IF EXISTS demo_phys;
CREATE TABLE demo_phys (
    id      bigint        NOT NULL,
    status  text          NOT NULL,
    amount  numeric(12,2) NOT NULL
);

INSERT INTO demo_phys
SELECT g,
       (ARRAY['new','paid','shipped','closed'])[1 + g % 4],
       round((g * 7 % 10000)::numeric, 2)
FROM generate_series(1, 100000) AS g;

CREATE INDEX demo_phys_id ON demo_phys (id);

-- Выполнить отдельной командой (в pgAdmin — выделить строку и запустить):
VACUUM ANALYZE demo_phys;

-- -----------------------------------------------------------------------------
-- 1. Где файлы
-- -----------------------------------------------------------------------------
-- Путь относительно каталога данных: base/<oid базы>/<relfilenode>.
-- Ожидаемо: что-то вроде base/16384/16390 и base/16384/16397.
SELECT current_setting('data_directory')   AS data_directory,
       pg_relation_filepath('demo_phys')    AS heap_file,
       pg_relation_filepath('demo_phys_id') AS index_file;

-- relfilenode — имя файла. Оно меняется после TRUNCATE, VACUUM FULL, CLUSTER,
-- REINDEX: команда пишет новый файл, старый удаляется. OID таблицы при этом прежний.
SELECT relname, oid, relfilenode, relpages, reltuples
FROM pg_class
WHERE relname IN ('demo_phys', 'demo_phys_id');

-- У таблицы несколько слоёв (fork), каждый — отдельный файл:
--   main — данные (файл <relfilenode>, при размере > 1 ГБ — ещё .1, .2, …);
--   fsm  — карта свободного места (<relfilenode>_fsm);
--   vm   — карта видимости (<relfilenode>_vm), 2 бита на страницу.
SELECT f.fork,
       pg_relation_size('demo_phys', f.fork)                 AS bytes,
       pg_relation_size('demo_phys', f.fork) / 8192           AS pages
FROM unnest(ARRAY['main', 'fsm', 'vm']) AS f(fork);

-- Посмотреть файлы с сервера (в консоли ОС, путь из запроса выше):
--   ls -l  $PGDATA/base/<oid базы>/<relfilenode>*
--   hexdump -C $PGDATA/base/<oid базы>/<relfilenode> | head -40
-- Утилита pg_filedump (отдельный проект сообщества, ставится пакетом) разбирает
-- файл без запущенного сервера:  pg_filedump -i -f <файл>

-- -----------------------------------------------------------------------------
-- 2. Файл на диске и страница в буферном кэше
-- -----------------------------------------------------------------------------
-- Изменения сначала попадают в shared_buffers и журнал (WAL), в файл таблицы —
-- позже (контрольная точка, фоновая запись). CHECKPOINT сбрасывает всё на диск.
CHECKPOINT;

-- Первые 64 байта страницы 0: из файла и из буфера. Ожидаемо: строки совпадают.
SELECT 'file'   AS source, encode(pg_read_binary_file(pg_relation_filepath('demo_phys'), 0, 64), 'hex') AS first_64_bytes
UNION ALL
SELECT 'buffer', encode(substr(get_raw_page('demo_phys', 0), 1, 64), 'hex');
-- Как читать начало (все числа little-endian):
--   байты 0–7   — LSN последней записи журнала, изменившей страницу;
--   8–9         — контрольная сумма (0, если кластер без data checksums);
--   10–11       — флаги; 12–13 — pd_lower; 14–15 — pd_upper; 16–17 — pd_special;
--   18–19       — размер страницы и версия; 20–23 — prune_xid;
--   с 24-го     — массив указателей на строки, по 4 байта.

-- -----------------------------------------------------------------------------
-- 3. Разбор страницы кучи
-- -----------------------------------------------------------------------------
-- Заголовок страницы. Ожидаемо: lower ≈ 24 + 4 × число строк, upper — где
-- начинаются данные (строки пишутся с конца страницы к началу), свободно upper − lower.
SELECT lsn, checksum, flags, lower, upper, special, pagesize, version, prune_xid,
       upper - lower AS free_bytes
FROM page_header(get_raw_page('demo_phys', 0));

-- Указатели и версии строк.
--   lp      — номер указателя (вторая часть ctid);
--   lp_off  — смещение версии строки внутри страницы, lp_len — её длина;
--   t_xmin  — транзакция, создавшая версию; t_xmax — удалившая (0 — жива);
--   t_ctid  — у актуальной версии указывает на саму себя, у старой — на новую;
--   t_hoff  — длина заголовка версии (24 байта, если нет битовой карты NULL);
--   t_data  — сами колонки в байтах.
-- Ожидаемо: lp_off убывает (8144, 8096, …) — строки лежат с конца страницы.
SELECT lp, lp_off, lp_len, t_xmin, t_xmax, t_ctid, t_hoff, t_data
FROM heap_page_items(get_raw_page('demo_phys', 0))
LIMIT 5;

-- Флаги версии строки в читаемом виде (PostgreSQL 13+).
-- HEAP_XMIN_COMMITTED — «подсказка», что создавшая транзакция зафиксирована
-- (выставляется первым читателем или VACUUM); HEAP_XMAX_INVALID — версия не удалена;
-- HEAP_HASVARWIDTH — есть колонки переменной длины.
SELECT h.lp, f.raw_flags
FROM heap_page_items(get_raw_page('demo_phys', 0)) AS h,
     LATERAL heap_tuple_infomask_flags(h.t_infomask, h.t_infomask2) AS f
LIMIT 3;

-- Колонки по отдельности (массив байтов на каждую колонку).
-- Как читать строку id = 1, status = 'paid':
--   id     — \x0100000000000000: bigint 8 байт, little-endian → 1;
--   status — \x0b70616964: 0x0b — короткий заголовок varlena (длина 5 = 1 + 4,
--            записана как 5 << 1 | 1), дальше 'p' 'a' 'i' 'd' в UTF-8;
--   amount — numeric: короткий заголовок + цифры по основанию 10 000.
SELECT lp, t_attrs
FROM heap_page_item_attrs(get_raw_page('demo_phys', 0), 'demo_phys'::regclass)
LIMIT 3;

-- Сколько строк на странице кучи и сколько страниц всего.
SELECT count(*) AS rows_on_page_0 FROM heap_page_items(get_raw_page('demo_phys', 0));
SELECT pg_relation_size('demo_phys') / 8192 AS heap_pages;

-- -----------------------------------------------------------------------------
-- 4. UPDATE вживую: что остаётся на странице
-- -----------------------------------------------------------------------------
-- Карта видимости до изменения: страница 0 «вся видима» (после VACUUM).
SELECT * FROM pg_visibility_map('demo_phys') WHERE blkno = 0;

UPDATE demo_phys SET amount = amount + 1 WHERE id = 1;

-- Старая версия осталась на месте: t_xmax = номер нашей транзакции,
-- t_ctid указывает на новую версию. Страница была заполнена полностью
-- (fillfactor 100), поэтому новая версия ушла на другую страницу — это не HOT,
-- и в индекс demo_phys_id добавилась новая запись (3.3).
SELECT lp, t_xmin, t_xmax, t_ctid
FROM heap_page_items(get_raw_page('demo_phys', 0))
WHERE lp = 1;

SELECT ctid, xmin, xmax, id, amount FROM demo_phys WHERE id = 1;

-- Бит «вся видима» у страницы 0 сброшен: Index Only Scan по строкам этой страницы
-- снова будет ходить в кучу, пока VACUUM не уберёт старую версию.
SELECT * FROM pg_visibility_map('demo_phys') WHERE blkno = 0;

-- Сводка по карте видимости: сколько страниц «вся видима» и «вся заморожена».
SELECT * FROM pg_visibility_map_summary('demo_phys');

-- -----------------------------------------------------------------------------
-- 5. Карта свободного места
-- -----------------------------------------------------------------------------
-- Сколько байт свободно на страницах (по данным FSM, с округлением до 32 байт).
-- Ожидаемо: 0 на заполненных страницах, больше — на последней.
SELECT * FROM pg_freespace('demo_phys') ORDER BY blkno DESC LIMIT 3;

-- -----------------------------------------------------------------------------
-- Уборка
-- -----------------------------------------------------------------------------
-- DROP TABLE demo_phys;

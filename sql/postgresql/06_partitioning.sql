/*
    PostgreSQL: декларативное секционирование, локальные индексы и уникальность
    Методичка: docs/04-sekcionirovanie.md, раздел 4.5

    Запускать в тестовой базе. Не применять к таблицам базы 1С.
*/

DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS sales_2024_01, sales_2024_04;   -- остатки прошлого запуска (отсоединённые секции)

-- 1. Секционированная таблица. PRIMARY KEY обязан включать ключ секционирования.
CREATE TABLE sales (
    sale_id   bigint        NOT NULL,
    sale_date date          NOT NULL,
    customer  int           NOT NULL,
    amount    numeric(18,2),
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);

-- Так нельзя — ошибка «unique constraint on partitioned table must include all partitioning columns»:
-- CREATE TABLE sales_bad (sale_id bigint PRIMARY KEY, sale_date date NOT NULL) PARTITION BY RANGE (sale_date);

-- 2. Секции
CREATE TABLE sales_2024_01 PARTITION OF sales FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE sales_2024_02 PARTITION OF sales FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE sales_2024_03 PARTITION OF sales FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');

-- 3. Индекс на родителе → автоматически на каждой секции (и на будущих)
CREATE INDEX ON sales (customer);

-- 4. Данные
INSERT INTO sales
SELECT g,
       date '2024-01-01' + (random() * 89)::int,
       (random() * 1000)::int,
       round((random() * 1000)::numeric, 2)
FROM generate_series(1, 90000) AS g;
ANALYZE sales;

-- 5. Какие индексы получились: у каждой секции свои (локальные)
SELECT tablename, indexname FROM pg_indexes WHERE tablename LIKE 'sales%' ORDER BY tablename, indexname;

-- 6. Отсечение секций
EXPLAIN SELECT * FROM sales WHERE sale_date = '2024-02-10' AND customer = 5;  -- только sales_2024_02
EXPLAIN SELECT * FROM sales WHERE customer = 5;                               -- все секции

-- Отсечение во время выполнения (параметр) — смотрите «Subplans Removed»
PREPARE q(date) AS SELECT count(*) FROM sales WHERE sale_date = $1;
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE) EXECUTE q('2024-03-05');
RESET plan_cache_mode;
DEALLOCATE q;

-- 7. Аналог SWITCH: отсоединить старую секцию и присоединить новую
ALTER TABLE sales DETACH PARTITION sales_2024_01;            -- PG 14+: можно ... CONCURRENTLY (вне транзакции)

CREATE TABLE sales_2024_04 (LIKE sales INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
ALTER TABLE sales_2024_04
    ADD CONSTRAINT sales_2024_04_range CHECK (sale_date >= '2024-04-01' AND sale_date < '2024-05-01');
-- CHECK заранее → ATTACH не сканирует секцию для проверки
ALTER TABLE sales ATTACH PARTITION sales_2024_04 FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');

SELECT inhrelid::regclass AS partition_name
FROM pg_inherits WHERE inhparent = 'sales'::regclass ORDER BY 1;

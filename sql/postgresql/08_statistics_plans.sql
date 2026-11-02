-- =============================================================================
-- 08_statistics_plans.sql — статистика планировщика и планы подготовленных запросов
-- К разделам 6.5 и 6.6 методички.
--
-- Что показывает:
--   1. Коррелированные колонки (аналог «Организация + Склад»): недооценка в 10 раз
--      и как её исправляет расширенная статистика CREATE STATISTICS.
--   2. Проблема возрастающего ключа (аналог «Период» регистра): новые строки
--      после последнего ANALYZE планировщик почти не видит.
--   3. Подготовленный запрос: custom- и generic-план, plan_cache_mode.
--
-- Запускать в отдельной тестовой базе (не в базе 1С). Проверено на PostgreSQL 16.
-- psql -f 08_statistics_plans.sql
-- =============================================================================

\pset pager off
DROP SCHEMA IF EXISTS demo_stats CASCADE;
CREATE SCHEMA demo_stats;
SET search_path = demo_stats;

-- -----------------------------------------------------------------------------
-- 1. Коррелированные колонки
-- -----------------------------------------------------------------------------
-- 100 складов, каждый склад принадлежит ровно одной из 10 организаций:
-- склад 35 всегда у организации 3. Строк с org = 3 AND sklad = 35 — 10 000.
CREATE TABLE ost (org int, sklad int, qty numeric) WITH (autovacuum_enabled = off);
INSERT INTO ost
SELECT s % 100 / 10, s % 100, 1
FROM generate_series(1, 1000000) AS s;
ANALYZE ost;

-- Планировщик считает условия независимыми: 1/10 × 1/100 × 1 000 000 ≈ 1 000.
-- Ожидаемо: rows≈1000 (оценка), actual rows=10000 (факт) — ошибка в 10 раз.
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT * FROM ost WHERE org = 3 AND sklad = 35;

-- Расширенная статистика: функциональные зависимости + MCV по паре колонок.
CREATE STATISTICS ost_org_sklad (dependencies, mcv) ON org, sklad FROM ost;
ANALYZE ost;   -- без ANALYZE объект статистики пустой

-- Ожидаемо: оценка ≈ 10 000 — совпадает с фактом.
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT * FROM ost WHERE org = 3 AND sklad = 35;

-- Что собрано: степень зависимости sklad → org равна 1.
SELECT statistics_name, attnames, dependencies
FROM pg_stats_ext
WHERE tablename = 'ost';

-- -----------------------------------------------------------------------------
-- 2. Возрастающий ключ: строки «после последнего ANALYZE»
-- -----------------------------------------------------------------------------
-- 500 000 «старых» движений с января по июнь, статистика собрана.
CREATE TABLE mov (period timestamp, val int) WITH (autovacuum_enabled = off);
INSERT INTO mov
SELECT timestamp '2026-01-01' + s * interval '30 second', 1
FROM generate_series(1, 500000) AS s;
CREATE INDEX mov_period_idx ON mov (period);
ANALYZE mov;

-- Верхняя граница гистограммы — около 23 июня.
SELECT max(period) AS max_in_table FROM mov;

-- Затем пришли 50 000 «новых» движений за 1 октября, ANALYZE ещё не было
-- (autovacuum отключён, чтобы воспроизвести ситуацию стабильно).
INSERT INTO mov
SELECT timestamp '2026-10-01' + s * interval '1 second', 1
FROM generate_series(1, 50000) AS s;

-- Ожидаемо: оценка — десятки строк, факт — 50 000.
-- Индекс по period планировщик использует, чтобы узнать реальный максимум
-- (get_actual_variable_range), но расширяет им только последний интервал
-- гистограммы, который «весит» ~1% строк выборки ANALYZE. Недооценка остаётся.
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT * FROM mov WHERE period >= '2026-10-01';

-- Лечится только свежей статистикой.
ANALYZE mov;
-- Ожидаемо: оценка ≈ 50 000.
EXPLAIN (ANALYZE, COSTS ON, TIMING OFF, SUMMARY OFF)
SELECT * FROM mov WHERE period >= '2026-10-01';

-- Когда последний раз собиралась статистика и сколько изменений накопилось:
SELECT relname, last_analyze, last_autoanalyze, n_mod_since_analyze, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'demo_stats';

-- -----------------------------------------------------------------------------
-- 3. Подготовленный запрос: custom- и generic-план
-- -----------------------------------------------------------------------------
-- Перекос: 'open' — 1% строк, 'closed' — 99%.
CREATE TABLE doc (id int, status text, pad text);
INSERT INTO doc
SELECT s, CASE WHEN s % 100 = 0 THEN 'open' ELSE 'closed' END, repeat('x', 50)
FROM generate_series(1, 1000000) AS s;
CREATE INDEX doc_status_idx ON doc (status);
ANALYZE doc;

PREPARE q(text) AS SELECT count(pad) FROM doc WHERE status = $1;

-- Custom-план строится под конкретное значение:
-- 'open'   → Index Scan (оценка ≈ 10 000 строк);
-- 'closed' → Seq Scan (оценка ≈ 990 000 строк).
EXPLAIN EXECUTE q('open');
EXPLAIN EXECUTE q('closed');

-- Generic-план строится без знания значения: в условии виден $1, оценка —
-- «среднее» значение (здесь ≈ 500 000 строк), и план один для всех значений.
SET plan_cache_mode = force_generic_plan;
EXPLAIN EXECUTE q('open');
EXPLAIN EXECUTE q('closed');

-- В режиме auto (по умолчанию) первые 5 выполнений — custom-планы, дальше
-- PostgreSQL сравнивает стоимость generic-плана со средней стоимостью custom
-- и может перейти на generic. Подготовим запрос заново, чтобы счётчики
-- (pg_prepared_statements, PostgreSQL 14+) не учитывали EXPLAIN выше.
RESET plan_cache_mode;
DEALLOCATE q;
PREPARE q(text) AS SELECT count(pad) FROM doc WHERE status = $1;
EXECUTE q('open'); EXECUTE q('open'); EXECUTE q('open');
EXECUTE q('open'); EXECUTE q('open'); EXECUTE q('open');
-- Ожидаемо: custom_plans = 6, generic_plans = 0. Generic-план (стоимость
-- ≈ 16 000) намного дороже среднего custom (≈ 1 200), поэтому PostgreSQL
-- остаётся на custom-планах — это и есть защита от «прилипшего» плана.
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements;

-- Когда стоимости близки (равномерное распределение, поиск по уникальному
-- ключу), с шестого выполнения PostgreSQL переходит на generic-план.
CREATE INDEX doc_id_idx ON doc (id);
PREPARE q_id(int) AS SELECT pad FROM doc WHERE id = $1;
EXECUTE q_id(1); EXECUTE q_id(2); EXECUTE q_id(3);
EXECUTE q_id(4); EXECUTE q_id(5); EXECUTE q_id(6);
-- Ожидаемо: q_id — custom_plans = 5, generic_plans = 1.
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements ORDER BY name;

DEALLOCATE q_id;
DEALLOCATE q;

-- Уборка
-- DROP SCHEMA demo_stats CASCADE;

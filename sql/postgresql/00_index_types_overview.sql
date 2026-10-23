/* =====================================================================
   Типы индексов PostgreSQL: что установлено и что умеет каждый
   К разделу 3.1 методички (docs/03-postgresql.md)

   Запускать в отдельной тестовой базе (PostgreSQL 13+), не в базе 1С.
   Скрипт только читает системные каталоги.
   ===================================================================== */

-- 1. Методы доступа (типы индексов), которые есть в этой установке.
--    Встроенные: btree, hash, gist, spgist, gin, brin.
--    Расширения могут добавить свои (например, bloom).
SELECT amname AS index_type, amhandler
FROM pg_am
WHERE amtype = 'i'
ORDER BY amname;

-- 2. Что умеет каждый тип в целом.
--    can_order      — может отдавать строки в порядке индекса (ORDER BY без Sort)
--    can_unique     — поддерживает UNIQUE
--    can_multi_col  — составные индексы
--    can_exclude    — ограничения исключения EXCLUDE
--    can_include    — INCLUDE-колонки
SELECT a.amname AS index_type,
       pg_indexam_has_property(a.oid, 'can_order')     AS can_order,
       pg_indexam_has_property(a.oid, 'can_unique')    AS can_unique,
       pg_indexam_has_property(a.oid, 'can_multi_col') AS can_multi_col,
       pg_indexam_has_property(a.oid, 'can_exclude')   AS can_exclude,
       pg_indexam_has_property(a.oid, 'can_include')   AS can_include
FROM pg_am AS a
WHERE a.amtype = 'i'
ORDER BY a.amname;

-- 3. Классы операторов: какие типы данных каждый тип индекса умеет индексировать.
--    Класс операторов = «как этот тип индекса работает с этим типом данных».
--    opcdefault = true — класс, который берётся, если в CREATE INDEX класс не указан.
SELECT am.amname AS index_type, opc.opcname AS operator_class,
       format_type(opc.opcintype, NULL) AS data_type, opc.opcdefault AS is_default
FROM pg_opclass AS opc
JOIN pg_am AS am ON am.oid = opc.opcmethod
WHERE am.amname IN ('gist', 'spgist', 'gin')   -- у hash и brin классов десятки — добавьте при желании
  AND opc.opcdefault          -- только классы по умолчанию; уберите условие, чтобы увидеть все
ORDER BY am.amname, data_type, operator_class;

-- 4. Какие операторы поддерживает конкретный класс — например, GIN для jsonb.
--    Именно эти операторы в WHERE позволяют использовать индекс.
SELECT am.amname AS index_type, opf.opfname AS operator_family,
       amop.amopopr::regoperator AS operator
FROM pg_amop AS amop
JOIN pg_opfamily AS opf ON opf.oid = amop.amopfamily
JOIN pg_am AS am ON am.oid = opf.opfmethod
WHERE am.amname = 'gin' AND opf.opfname IN ('jsonb_ops', 'jsonb_path_ops', 'array_ops')
ORDER BY operator_family, operator;

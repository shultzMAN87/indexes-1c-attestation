# Индексы в MS SQL Server и PostgreSQL применительно к 1С

Методичка для подготовки к аттестации **«Работа с индексами»**: индексы в SQL применительно к платформе 1С:Предприятие 8 на обеих СУБД — MS SQL Server и PostgreSQL.

Каждый вопрос разобран по одной схеме:

> **Коротко** — ответ на 30–60 секунд, его и стоит говорить на аттестации.

Затем — подробное объяснение со схемами, примерами SQL, разделом **«Применительно к 1С»** и блоком **«Запомнить»**.

Вопросы из примеров аттестации помечены **★**.

---

## Как пользоваться

1. **Первый проход** — читать главы по порядку: каждая следующая опирается на предыдущую.
2. **Повторение** — [шпаргалка](docs/07-shpargalka.md): все короткие ответы, сравнительная таблица MS SQL / PostgreSQL, числа и словарик.
3. **Практика** — [скрипты](#скрипты): запускать в отдельной тестовой базе.

---

## Оглавление

### [Глава 1. Общая теория индексов](docs/01-teoriya.md)
- [1.1. Что такое индекс, задачи и цена](docs/01-teoriya.md#11-что-такое-индекс-какие-задачи-он-решает-и-чем-за-это-приходится-платить)
- [1.2. Устройство B-дерева, почему поиск логарифмический](docs/01-teoriya.md#12-как-устроено-b-дерево-почему-поиск-логарифмический)
- [1.3. Селективность и кардинальность](docs/01-teoriya.md#13-что-такое-селективность-и-кардинальность)
- [1.4. Почему индекс по малоселективному (булеву) полю может не использоваться](docs/01-teoriya.md#14-почему-индекс-по-малоселективному-полю-может-не-использоваться-на-примере-булева-поля)
- [1.5. Порядок колонок в составном индексе, правило левого префикса](docs/01-teoriya.md#15-как-порядок-колонок-в-составном-индексе-влияет-на-его-применимость-правило-левого-префикса)
- [1.6. Покрывающий индекс и `INCLUDE`](docs/01-teoriya.md#16-что-такое-покрывающий-индекс-и-зачем-нужны-включённые-столбцы-include)
- [1.7. Уникальный индекс и ограничение уникальности](docs/01-teoriya.md#17-что-такое-уникальный-индекс-и-чем-он-отличается-от-ограничения-уникальности)
- [1.8. Индексы, блокировки и взаимоблокировки](docs/01-teoriya.md#18-как-индексы-влияют-на-блокировки-и-взаимоблокировки)

### [Глава 2. MS SQL Server](docs/02-mssql.md)
- [Основа: кластерный индекс, некластерный индекс, куча](docs/02-mssql.md#основа-главы-кластерный-индекс-некластерный-индекс-и-куча)
- [2.1. Ограничения на ключ индекса](docs/02-mssql.md#21-каковы-ограничения-на-ключ-индекса-байты-число-колонок)
- [2.2. ★ Fill factor и page split](docs/02-mssql.md#22--что-такое-fill-factor-и-зачем-может-потребоваться-его-менять-что-такое-page-split)
- [2.3. Фрагментация, `REORGANIZE` и `REBUILD`, новый подход Microsoft к порогам](docs/02-mssql.md#23-что-такое-фрагментация-и-как-её-измерить-чем-reorganize-отличается-от-rebuild-и-как-изменился-подход-microsoft-к-порогам)
- [2.4. `sys.dm_db_index_usage_stats` и `sys.dm_db_missing_index_*`](docs/02-mssql.md#24-что-показывают-sysdm_db_index_usage_stats-и-sysdm_db_missing_index_-ограничения-рекомендаций-по-недостающим-индексам)
- [2.5. Типы индексов кроме B-tree: columnstore, hash, Bw-tree, полнотекстовый, spatial, XML, JSON, векторный](docs/02-mssql.md#25-какие-типы-индексов-есть-в-ms-sql-server-кроме-b-tree-и-для-чего-каждый)
  - [Columnstore](docs/02-mssql.md#columnstore--колоночное-хранение) · [Hash](docs/02-mssql.md#hash--бакеты-по-хеш-коду-только-in-memory-oltp) · [Bw-tree](docs/02-mssql.md#bw-tree--некластерный-индекс-memory-optimized-таблиц) · [Полнотекстовый](docs/02-mssql.md#полнотекстовый-индекс-и-семантический) · [Spatial](docs/02-mssql.md#пространственный-индекс-spatial--сетка-поверх-b-tree) · [XML](docs/02-mssql.md#xml-индексы-primary-path--value--property-selective) · [JSON](docs/02-mssql.md#json-индекс-sql-server-2025) · [Векторный](docs/02-mssql.md#векторный-индекс-diskann-sql-server-2025) · [Что не является отдельным типом](docs/02-mssql.md#что-не-является-отдельным-типом-индекса) · [MS SQL ↔ PostgreSQL](docs/02-mssql.md#ms-sql-и-postgresql-чему-что-соответствует)
- [2.6. Фильтруемые индексы и сжатие данных](docs/02-mssql.md#26-что-такое-фильтруемые-индексы-и-сжатие-данных-и-когда-они-полезны)
- [2.7. Создание и перестроение индекса без остановки работы: `ONLINE`, `RESUMABLE`](docs/02-mssql.md#27-как-создать-или-перестроить-индекс-не-останавливая-работу-пользователей-online-resumable-wait_at_low_priority)
- [2.8. Индексы по выражениям: вычисляемые столбцы и индексированные представления](docs/02-mssql.md#28-как-в-ms-sql-проиндексировать-выражение-вычисляемые-столбцы-и-индексированные-представления)
- [2.9. Как хранятся строки на страницах: IN_ROW, ROW_OVERFLOW, LOB](docs/02-mssql.md#29-как-ms-sql-хранит-строки-на-страницах-in_row-row_overflow-и-lob)
- [2.10. READ COMMITTED SNAPSHOT и индексы: метка версии, version store, ghost-записи](docs/02-mssql.md#210-как-read-committed-snapshot-влияет-на-индексы-метка-версии-version-store-ghost-записи)

### [Глава 3. PostgreSQL](docs/03-postgresql.md)
- [3.1. Типы индексов: B-tree, Hash, GiST, SP-GiST, GIN, BRIN — устройство, схемы, скрипты; несколько типов на одной таблице, `BitmapAnd`/`BitmapOr`](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый)
- [3.2. Почему нет кластерного индекса и что делает `CLUSTER`](docs/03-postgresql.md#32-почему-в-postgresql-нет-кластерного-индекса-в-понимании-ms-sql-и-что-делает-cluster)
- [3.3. MVCC, HOT-обновления и раздувание](docs/03-postgresql.md#33-как-mvcc-влияет-на-индексы-что-такое-hot-обновления-и-раздувание-bloat)
- [3.4. `fillfactor` для таблицы и индекса, отличия от MS SQL](docs/03-postgresql.md#34-что-значит-fillfactor-в-postgresql-для-таблицы-и-для-индекса-и-чем-он-отличается-от-ms-sql)
- [3.5. `VACUUM` и autovacuum; `REINDEX` и `REINDEX CONCURRENTLY`](docs/03-postgresql.md#35-какова-роль-vacuum-и-autovacuum-в-обслуживании-индексов-чем-отличаются-reindex-и-reindex-concurrently)
- [3.6. Фрагментация и раздувание — как отличить](docs/03-postgresql.md#36-как-отличить-фрагментацию-индекса-от-раздувания-в-postgresql)
- [3.7. Неиспользуемые индексы и тяжёлые запросы](docs/03-postgresql.md#37-как-найти-неиспользуемые-индексы-и-проблемные-запросы-pg_stat_user_indexes-explain-analyze-pg_stat_statements)
- [3.8. `CREATE INDEX CONCURRENTLY`](docs/03-postgresql.md#38-как-создать-индекс-без-блокировки-записи-create-index-concurrently)
- [3.9. Индексы по выражениям](docs/03-postgresql.md#39-что-такое-индекс-по-выражению-в-postgresql-и-когда-он-нужен)
- [3.10. Как хранятся строки на страницах: версия строки, TOAST](docs/03-postgresql.md#310-как-postgresql-хранит-строки-страница-версия-строки-и-toast)

### [Глава 4. Секционирование и индексы](docs/04-sekcionirovanie.md)
- [4.0. Секционирование на пальцах: зачем оно, как устроено, когда применять](docs/04-sekcionirovanie.md#40-секционирование-на-пальцах-зачем-оно-и-как-устроено)
- [4.1. ★ Индексы и секционирование в MS SQL: выровненные индексы, `SWITCH`, partition elimination](docs/04-sekcionirovanie.md#41--в-чём-особенность-совместной-работы-индексов-и-секционирования-в-ms-sql-выровненные-индексы-switch-partition-elimination)
- [4.1a. Как работает `SWITCH`: что переключается, три направления, условия, блокировки, ошибки](docs/04-sekcionirovanie.md#41a-как-работает-switch-что-переключается-куда-попадают-данные-и-почему-это-мгновенно)
- [4.1b. Файловые группы: где физически лежат таблицы и секции](docs/04-sekcionirovanie.md#41b-файловые-группы-где-физически-лежат-таблицы-и-секции)
- [4.2. Секционирование и операция Seek](docs/04-sekcionirovanie.md#42-как-секционирование-влияет-на-операцию-seek-что-такое-partition-elimination)
- [4.2a. Секционирование по дате и поиск по пользователю: выровненный и невыровненный кластерный индекс](docs/04-sekcionirovanie.md#42a-секционирование-по-дате-и-поиск-по-пользователю-выровненный-и-невыровненный-кластерный-индекс)
- [4.3. Скользящее окно: `SPLIT`, `MERGE`, `SWITCH`](docs/04-sekcionirovanie.md#43-пример-скользящего-окна-sliding-window-на-t-sql-split-merge-switch)
- [4.4. Глобальные и локальные индексы](docs/04-sekcionirovanie.md#44-глобальные-и-локальные-индексы-при-секционировании-что-есть-в-ms-sql-и-postgresql)
- [4.5. Секционирование в PostgreSQL и уникальность](docs/04-sekcionirovanie.md#45-как-устроено-секционирование-в-postgresql-почему-там-нет-глобальных-индексов-и-как-это-влияет-на-уникальность)
- [4.6. Когда отсечение секций не срабатывает и другие грабли](docs/04-sekcionirovanie.md#46-когда-отсечение-секций-не-срабатывает-и-другие-грабли)
- [Секционирование и 1С](docs/04-sekcionirovanie.md#секционирование-и-1с)

### [Глава 5. Индексы в 1С:Предприятии](docs/05-1c.md)
- [5.1. Какие индексы создаёт платформа](docs/05-1c.md#51-какие-индексы-платформа-создаёт-автоматически-для-справочников-документов-и-регистров)
- [5.2. ★ Рекомендации при создании индексов объектов метаданных](docs/05-1c.md#52--какие-рекомендации-можно-дать-при-создании-индексов-объектов-метаданных-в-1с)
- [5.3. 1С на PostgreSQL: `mvarchar`/`mchar`, регистронезависимость, `online_analyze`](docs/05-1c.md#53-какие-особенности-есть-у-1с-на-postgresql-mvarcharmchar-регистронезависимость-online_analyze)
- [5.4. Различия MS SQL и PostgreSQL, важные для 1С](docs/05-1c.md#54-основные-различия-в-организации-индексов-ms-sql-и-postgresql-которые-нужно-учитывать-в-1с)
- [5.5. Регистр бухгалтерии и регистр расчёта: таблицы и индексы](docs/05-1c.md#55-какие-индексы-и-таблицы-у-регистра-бухгалтерии-и-регистра-расчёта)
- [5.6. Кластерный индекс по Ссылке (GUID) и вставка новых объектов](docs/05-1c.md#56-как-кластерный-индекс-по-ссылке-guid-ведёт-себя-при-вставке-новых-объектов)
- [5.7. Динамический список и индексы](docs/05-1c.md#57-как-динамический-список-читает-данные-и-какие-индексы-ему-нужны)
- [5.8. `ИНДЕКСИРОВАТЬ ПО` во временных таблицах](docs/05-1c.md#58-что-делает-индексировать-по-во-временной-таблице-и-когда-это-окупается)
- [5.9. Ограничения доступа (RLS) и индексы](docs/05-1c.md#59-как-ограничения-доступа-на-уровне-записей-rls-влияют-на-индексы-и-планы-запросов)
- [5.10. Разделение итогов](docs/05-1c.md#510-что-такое-разделение-итогов-и-как-оно-влияет-на-индексы-таблиц-итогов)
- [5.11. Длинные строки и ХранилищеЗначения в СУБД; `ПОДОБНО` по длинной строке](docs/05-1c.md#511-как-хранятся-длинные-строки-и-хранилищезначения-1с-и-что-происходит-при-отборе-подобно)

### [Глава 6. Обслуживание и диагностика](docs/06-obsluzhivanie-diagnostika.md)
- [6.1. Регламент обслуживания индексов и статистики](docs/06-obsluzhivanie-diagnostika.md#61-каков-регламент-обслуживания-индексов-и-статистики-для-баз-1с-на-ms-sql-и-на-postgresql)
- [6.2. Как найти медленный запрос и связанный индекс](docs/06-obsluzhivanie-diagnostika.md#62-как-найти-медленный-запрос-и-связанный-с-ним-индекс-технологический-журнал-цуп-profiler--extended-events-pg_stat_statements)
- [6.3. Кейс: тормозит отчёт по регистру](docs/06-obsluzhivanie-diagnostika.md#63-кейс-отчёт-по-регистру-тормозит-порядок-диагностики-и-варианты-решения-через-индексы)
- [6.4. Дублирующиеся и пересекающиеся индексы](docs/06-obsluzhivanie-diagnostika.md#64-как-найти-дублирующиеся-и-пересекающиеся-индексы)
- [6.5. Статистика и выбор индекса: пороги обновления, возрастающий ключ, коррелированные условия](docs/06-obsluzhivanie-diagnostika.md#65-как-статистика-влияет-на-выбор-индекса-пороги-обновления-возрастающий-ключ-коррелированные-условия)
- [6.6. Parameter sniffing: почему один и тот же запрос то пользуется индексом, то нет](docs/06-obsluzhivanie-diagnostika.md#66-что-такое-parameter-sniffing-и-почему-один-и-тот-же-запрос-то-пользуется-индексом-то-нет)

### [Шпаргалка](docs/07-shpargalka.md) · [Источники](docs/08-istochniki.md)
- [Короткие ответы](docs/07-shpargalka.md#короткие-ответы)
- [MS SQL Server и PostgreSQL — сравнение одной таблицей](docs/07-shpargalka.md#ms-sql-server-и-postgresql--сравнение-одной-таблицей)
- [Числа, которые стоит помнить](docs/07-shpargalka.md#числа-которые-стоит-помнить)
- [Словарик](docs/07-shpargalka.md#словарик)

---

## Скрипты

| Файл | Что делает | Раздел |
|---|---|---|
| [sql/mssql/01_columnstore_demo.sql](sql/mssql/01_columnstore_demo.sql) | Columnstore и rowstore на одних данных: размер, план, batch mode, группы строк и сегменты, segment elimination, deltastore | [2.5](docs/02-mssql.md#columnstore--колоночное-хранение) |
| [sql/mssql/02_row_storage_lob.sql](sql/mssql/02_row_storage_lob.sql) | Страница и запись; IN_ROW / ROW_OVERFLOW / LOB на примерах 200 КБ и 500 КБ, две большие колонки, `ntext`/`image`; `lob logical reads` при `SELECT`, `LIKE`, `SUBSTRING` | [2.9](docs/02-mssql.md#29-как-ms-sql-хранит-строки-на-страницах-in_row-row_overflow-и-lob), [5.11](docs/05-1c.md#511-как-хранятся-длинные-строки-и-хранилищезначения-1с-и-что-происходит-при-отборе-подобно) |
| [sql/mssql/07_rcsi_version_tag.sql](sql/mssql/07_rcsi_version_tag.sql) | RCSI: метка версии 14 байт, рост записей и page split при fill factor 100, version store, ghost-записи, состояние после `REBUILD` | [2.10](docs/02-mssql.md#210-как-read-committed-snapshot-влияет-на-индексы-метка-версии-version-store-ghost-записи) |
| [sql/mssql/08_nonclustered_columnstore.sql](sql/mssql/08_nonclustered_columnstore.sql) | Некластерный columnstore на обычной таблице без её пересоздания: выбор B-tree или NCCI под запрос, deltastore и delete buffer при DML (`sys.internal_partitions`), фильтрованный NCCI и `COMPRESSION_DELAY`, batch mode on rowstore | [2.5](docs/02-mssql.md#columnstore--колоночное-хранение) |
| [sql/mssql/09_partitioning_clustered_choice.sql](sql/mssql/09_partitioning_clustered_choice.sql) | Секционирование по дате при поиске по пользователю: кластерный по `UserID` выровненный и невыровненный, кластерный по дате + некластерный выровненный и глобальный; `Scan count` для трёх запросов, ошибка 7733 при `SWITCH` и обход | [4.2a](docs/04-sekcionirovanie.md#42a-секционирование-по-дате-и-поиск-по-пользователю-выровненный-и-невыровненный-кластерный-индекс) |
| [sql/mssql/10_inmemory_hash_bwtree.sql](sql/mssql/10_inmemory_hash_bwtree.sql) | In-Memory OLTP: hash-индекс и Bw-tree на одинаковых таблицах; планы для `=`, диапазона, `ORDER BY` и `DESC`; бакеты и цепочки при нормальном и заниженном `BUCKET_COUNT` (`sys.dm_db_xtp_hash_index_stats`); hash по колонке с повторами; составной hash-ключ | [2.5](docs/02-mssql.md#hash--бакеты-по-хеш-коду-только-in-memory-oltp) |
| [sql/mssql/11_fulltext.sql](sql/mssql/11_fulltext.sql) | Полнотекстовый индекс: разбор русского текста (`sys.dm_fts_parser`), `CONTAINS` со словоформами, префиксом и `NEAR`, `FREETEXT`, ранг `CONTAINSTABLE`, содержимое индекса, асинхронное заполнение, стоп-слова, сравнение с `LIKE '%…%'` | [2.5](docs/02-mssql.md#полнотекстовый-индекс-и-семантический) |
| [sql/mssql/12_spatial.sql](sql/mssql/12_spatial.sql) | Пространственный индекс: «в радиусе», «в районе», «N ближайших» без индекса и с ним; первичный и вторичный фильтр в плане; `sp_help_spatial_geography_index`; автоматическая и ручная сетка; условия, которые ломают индекс | [2.5](docs/02-mssql.md#пространственный-индекс-spatial--сетка-поверх-b-tree) |
| [sql/mssql/13_xml_indexes.sql](sql/mssql/13_xml_indexes.sql) | XML-индексы: XQuery без индексов, primary (размер таблицы узлов), вторичные `PATH`/`VALUE`/`PROPERTY` под разные запросы, selective XML index и его размер | [2.5](docs/02-mssql.md#xml-индексы-primary-path--value--property-selective) |
| [sql/mssql/14_json_index.sql](sql/mssql/14_json_index.sql) | JSON: вычисляемая колонка с `JSON_VALUE` + B-tree (2016+); тип `json` и `CREATE JSON INDEX` по нескольким путям, `JSON_PATH_EXISTS`, `JSON_CONTAINS` (2025) | [2.5](docs/02-mssql.md#json-индекс-sql-server-2025) |
| [sql/mssql/15_vector_index.sql](sql/mssql/15_vector_index.sql) | Векторный индекс DiskANN (2025, preview): точный поиск `VECTOR_DISTANCE` против приближённого `VECTOR_SEARCH`, recall, фильтр `WHERE` после поиска, ограничение read-only | [2.5](docs/02-mssql.md#векторный-индекс-diskann-sql-server-2025) |
| [sql/postgresql/00_index_types_overview.sql](sql/postgresql/00_index_types_overview.sql) | Какие типы индексов установлены, что умеет каждый, классы операторов | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/01_btree.sql](sql/postgresql/01_btree.sql) | B-tree изнутри (`pageinspect`) с разбором вывода каждого запроса: метастраница, корень, внутренняя страница, лист, high key, `ctid` в листьях, как читать байты ключа, дедупликация; Index / Index Only / Bitmap / Seq Scan | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/02_hash.sql](sql/postgresql/02_hash.sql) | Hash: корзины и хеш-коды, размер против B-tree на длинных строках, что не умеет | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/03_gist.sql](sql/postgresql/03_gist.sql) | GiST: ограничивающие прямоугольники, поиск в области, ближайшие соседи (KNN), `EXCLUDE` для броней, опорные функции классов, деградация после удалений, RD-дерево для `tsvector` (сигнатуры, насыщение, сравнение с GIN), стеммер и поиск слова «мир»: лексемы, префикс, подстрока | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/04_spgist.sql](sql/postgresql/04_spgist.sql) | SP-GiST: дерево квадрантов и k-d дерево, префиксное дерево для строк, IP-подсети | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/05_gin.sql](sql/postgresql/05_gin.sql) | GIN: массивы, JSONB (`jsonb_ops` и `jsonb_path_ops`), триграммы для `LIKE '%…%'`, полнотекстовый поиск, отложенный список; откуда `Rows Removed by Index Recheck` (`<@`, `jsonb_ops`, lossy-карта), селективность ключа | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/06_brin.sql](sql/postgresql/06_brin.sql) | BRIN: сводки min/max, размер против B-tree, упорядоченная и перемешанная таблица, `minmax_multi` и `bloom` | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/07_storage_toast.sql](sql/postgresql/07_storage_toast.sql) | Страница и версии строк (`pageinspect`); TOAST: сжатие, куски, 200 КБ и 500 КБ, две колонки; что читают `SELECT`, `LIKE`, `substr`; `UPDATE` без копирования TOAST | [3.10](docs/03-postgresql.md#310-как-postgresql-хранит-строки-страница-версия-строки-и-toast), [5.11](docs/05-1c.md#511-как-хранятся-длинные-строки-и-хранилищезначения-1с-и-что-происходит-при-отборе-подобно) |
| [sql/postgresql/08_statistics_plans.sql](sql/postgresql/08_statistics_plans.sql) | Статистика: коррелированные колонки и `CREATE STATISTICS`, возрастающий ключ (строки после последнего `ANALYZE`), custom- и generic-планы подготовленного запроса | [6.5](docs/06-obsluzhivanie-diagnostika.md#65-как-статистика-влияет-на-выбор-индекса-пороги-обновления-возрастающий-ключ-коррелированные-условия), [6.6](docs/06-obsluzhivanie-diagnostika.md#66-что-такое-parameter-sniffing-и-почему-один-и-тот-же-запрос-то-пользуется-индексом-то-нет) |
| [sql/postgresql/09_multiple_index_types.sql](sql/postgresql/09_multiple_index_types.sql) | Шесть индексов разных типов на одной таблице (два — по одной колонке): размеры, выбор индекса под оператор, `BitmapAnd` (BRIN + GIN) и `BitmapOr` (Hash + GIN), цена при вставке | [3.1](docs/03-postgresql.md#31-какие-типы-индексов-есть-в-postgresql-и-для-чего-каждый) |
| [sql/postgresql/10_physical_files.sql](sql/postgresql/10_physical_files.sql) | Где лежат файлы таблицы и индекса (слои main/fsm/vm); страница из файла и из буфера байт в байт; разбор страницы кучи: заголовок, указатели, `xmin`/`xmax`/`ctid`, флаги, байты колонок; `UPDATE` вживую; карта видимости и свободного места | [3.3](docs/03-postgresql.md#33-как-mvcc-влияет-на-индексы-что-такое-hot-обновления-и-раздувание-bloat), [3.10](docs/03-postgresql.md#310-как-postgresql-хранит-строки-страница-версия-строки-и-toast) |

Скрипты учебные: запускайте в отдельной тестовой базе, не в базе 1С. **В pgAdmin** не запускайте скрипт целиком одним пакетом: PostgreSQL выполнит его одной транзакцией, а `VACUUM` (и `CREATE INDEX CONCURRENTLY`) внутри транзакции запрещён — будет ошибка «cannot run inside a transaction block» и откат всего пакета. Выполняйте по частям (строки с `VACUUM` — отдельно) или через PSQL Tool: `\i путь/к/скрипту.sql`. Скрипты PostgreSQL проверены на PostgreSQL 16; используют расширения из стандартной поставки (`pageinspect`, `pg_trgm`, `btree_gist`). Скрипт `07_rcsi_version_tag.sql` создаёт и удаляет собственную тестовую базу `demo_rcsi` (переключение RCSI требует монопольного доступа). Скрипты `10`–`15` тоже создают и удаляют собственные базы (`demo_inmem`, `demo_fts`, `demo_spatial`, `demo_xml`, `demo_json`, `demo_vector`); `11` требует установленного компонента Full-Text Search, `14` (часть 2) и `15` — SQL Server 2025.

---

## Интерактивные схемы

Пошаговые HTML-схемы: выбираете операцию, нажимаете «Дальше» (или стрелки ← →), и на каждом шаге видно, что читается и почему. «Открыть» запускает схему в браузере сразу; можно и скачать файл (*Download raw file* на странице файла) и открыть локально — интернет не нужен.

| Схема | Что показывает | Раздел | |
|---|---|---|---|
| B-tree | Спуск по дереву, диапазон по цепочке листьев, `ORDER BY … DESC LIMIT`, Index Only Scan и карта видимости, вставка с page split и ростом дерева | [3.1](docs/03-postgresql.md#b-tree--то-же-b-дерево-что-в-ms-sql-с-отличиями) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/btree.html) · [файл](interactive/btree.html) |
| Hash | Метастраница и маски, корзины и страницы переполнения, коллизия и перепроверка, деление корзины | [3.1](docs/03-postgresql.md#hash--корзины-по-хеш-коду) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/hash.html) · [файл](interactive/hash.html) |
| GiST | R-дерево: поиск в области, KNN, `penalty`/`picksplit`, деградация после удалений | [3.1](docs/03-postgresql.md#gist--дерево-охватывающих-ключей) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/gist.html) · [файл](interactive/gist.html) |
| GiST, RD-дерево | Сигнатуры `tsvector`, коллизии битов, префикс, длина сигнатуры | [3.1](docs/03-postgresql.md#rd-дерево-gist-для-полнотекстового-поиска) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/gist-rd-tree.html) · [файл](interactive/gist-rd-tree.html) |
| SP-GiST | Префиксное дерево и дерево квадрантов: поиск, `choose`, `picksplit` | [3.1](docs/03-postgresql.md#sp-gist--разбиение-пространства-на-непересекающиеся-части) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/spgist.html) · [файл](interactive/spgist.html) |
| GIN | Ключи → списки `ctid`, `@>` / `&&` / `<@`, pending list | [3.1](docs/03-postgresql.md#gin--инвертированный-индекс) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/gin.html) · [файл](interactive/gin.html) |
| BRIN | Сводки по диапазонам, lossy-карта, корреляция, `minmax_multi`, диапазон без сводки | [3.1](docs/03-postgresql.md#brin--сводки-по-диапазонам-блоков) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/brin.html) · [файл](interactive/brin.html) |
| Skip scan | Поиск по второй колонке составного индекса | [1.5](docs/01-teoriya.md#skip-scan-в-postgresql-18) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/skip-scan.html) · [файл](interactive/skip-scan.html) |
| Page split (MS SQL) | Страница, массив слотов, расщепление и фрагментация | [2.2](docs/02-mssql.md#22--что-такое-fill-factor-и-зачем-может-потребоваться-его-менять-что-такое-page-split) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/page-split.html) · [файл](interactive/page-split.html) |
| Columnstore (MS SQL) | Группы строк и сегменты, segment elimination на упорядоченных и перемешанных данных, deltastore, delete bitmap, `UPDATE` = удаление + вставка, `REORGANIZE` | [2.5](docs/02-mssql.md#columnstore--колоночное-хранение) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/columnstore.html) · [файл](interactive/columnstore.html) |
| Hash и Bw-tree (MS SQL, In-Memory) | Бакеты и цепочки, `BUCKET_COUNT`, диапазон по hash и по Bw-tree, однонаправленность, delta-записи, CAS и консолидация | [2.5](docs/02-mssql.md#hash--бакеты-по-хеш-коду-только-in-memory-oltp) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/mssql-inmemory.html) · [файл](interactive/mssql-inmemory.html) |
| Spatial (MS SQL) | Тесселяция по уровням сетки и `CELLS_PER_OBJECT`, B-tree «ячейка → Id», первичный, внутренний и вторичный фильтр | [2.5](docs/02-mssql.md#пространственный-индекс-spatial--сетка-поверх-b-tree) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/spatial.html) · [файл](interactive/spatial.html) |
| Векторный DiskANN (MS SQL 2025) | Граф соседей, жадный поиск, ширина списка и recall, сравнение с полным перебором | [2.5](docs/02-mssql.md#векторный-индекс-diskann-sql-server-2025) | [открыть](https://raw.githack.com/shultzMAN87/indexes-1c-attestation/main/interactive/vector-diskann.html) · [файл](interactive/vector-diskann.html) |

---

## Структура репозитория

```
├── README.md
├── docs/            главы методички, шпаргалка, источники
├── images/          схемы (SVG)
├── interactive/     интерактивные пошаговые схемы (HTML)
└── sql/
    ├── mssql/       учебные скрипты для MS SQL Server
    └── postgresql/  учебные скрипты для PostgreSQL
```

---

## О точности

Основа ответов подготовлена в NotebookLM по опорным материалам, затем проверена и дополнена. Места, где исходные ответы устарели или были неточны, помечены в тексте **«⚠️ Поправка»**:

- лимиты ключа индекса MS SQL — 1700 байт / 32 колонки для некластерных индексов с SQL Server 2016, а не 900 / 16;
- `pg_stat_statements`: с PostgreSQL 13 — `total_exec_time`, а не `total_time`;
- `REINDEX` без `CONCURRENTLY` блокирует и сам индекс, а не только запись в таблицу;
- значения `fillfactor` по умолчанию для индексов PostgreSQL;
- длина индексируемых строк в 1С считается от лимита ключа, а не по правилу «100–150 символов»;
- `DBCC DBREINDEX` + `sp_msforeachtable` — устаревший способ обслуживания.

Версии, на которые ориентирован текст: SQL Server 2016–2022 (JSON- и векторный индексы — SQL Server 2025), PostgreSQL 13–18, платформа 1С:Предприятие 8.3. Поведение конкретной базы проверяйте на ней самой: состав индексов — через `ПолучитьСтруктуруХраненияБазыДанных()`, планы — через технологический журнал или `EXPLAIN`.

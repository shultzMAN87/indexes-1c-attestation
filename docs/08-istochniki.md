# Источники

[← Шпаргалка](07-shpargalka.md) · [Оглавление](../README.md)

## Опорные материалы аттестации

### MS SQL Server
- [Индексы (обзор)](https://learn.microsoft.com/ru-ru/sql/relational-databases/indexes/indexes?view=sql-server-ver16) — Microsoft Learn
- [Оптимизация обслуживания индексов (reorganize и rebuild)](https://learn.microsoft.com/ru-ru/sql/relational-databases/indexes/reorganize-and-rebuild-indexes?view=sql-server-ver16) — Microsoft Learn
- [Указание коэффициента заполнения для индекса](https://learn.microsoft.com/ru-ru/sql/relational-databases/indexes/specify-fill-factor-for-an-index?view=sql-server-ver16) — Microsoft Learn
- [Обзор columnstore-индексов](https://learn.microsoft.com/ru-ru/sql/relational-databases/indexes/columnstore-indexes-overview?view=sql-server-ver16) — Microsoft Learn
- [sys.dm_db_index_usage_stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-usage-stats-transact-sql?view=sql-server-ver16) — Microsoft Learn
- [sys.dm_db_missing_index_group_stats](https://learn.microsoft.com/ru-ru/sql/relational-databases/system-dynamic-management-views/sys-dm-db-missing-index-group-stats-transact-sql?view=sql-server-ver16) — Microsoft Learn
- [Секционированные таблицы и индексы](https://learn.microsoft.com/ru-ru/sql/relational-databases/partitions/partitioned-tables-and-indexes?view=sql-server-ver16) — Microsoft Learn
- [Windows IT Pro/RE, 2016/08](https://www.osp.ru/winitpro/2016/08/13050086) и [2016/04](https://www.osp.ru/winitpro/2016/04/13048963) — статистика использования индексов
- [Секционирование в SQL Server](https://habr.com/ru/articles/464665/) — Хабр

### PostgreSQL
- [Типы индексов (документация 9.6)](https://postgrespro.com/docs/postgresql/9.6/indexes-types) — устаревшая версия, см. актуальную ниже
- [Сборщик статистики (Postgres Pro 9.5)](https://postgrespro.ru/docs/postgrespro/9.5/monitoring-stats) — устаревшая версия
- [Индексы в PostgreSQL — 1](https://habr.com/ru/companies/postgrespro/articles/326096/) — Е. Рогов, начало цикла

### 1С
- [Статья на Инфостарте](https://infostart.ru/1c/articles/1158005/)
- [Влияние ограничений длины ключа индексов на проектирование объектов метаданных](http://itsphera.ru/1c/vliyanie-ogranichenij-dliny-klyucha-indeksov-na-proektirovanie-obektov-metadannyx.html) — для 8.1, лимиты в статье устаревшие (см. [2.1](02-mssql.md#21-каковы-ограничения-на-ключ-индекса-байты-число-колонок)), принцип актуален

## Материалы, по которым готовились ответы (NotebookLM)

- Е. Рогов. «PostgreSQL 17 изнутри» — [бесплатно на сайте Postgres Pro](https://postgrespro.ru/education/books/internals)
- Е. В. Филиппов. «Настольная книга 1С:Эксперта по технологическим вопросам»
- Методические материалы 1С по технологическим вопросам (в ответах NotebookLM — `1C_Metodika2.pdf`)
- Microsoft Learn: «Руководство по архитектуре и проектированию индексов SQL Server»

## Рекомендуемые дополнительные источники

### MS SQL Server
- [Руководство по архитектуре и проектированию индексов](https://learn.microsoft.com/ru-ru/sql/relational-databases/sql-server-index-design-guide) — главный документ по индексам MS SQL
- [Статистика](https://learn.microsoft.com/ru-ru/sql/relational-databases/statistics/statistics)
- [sys.dm_db_index_physical_stats](https://learn.microsoft.com/ru-ru/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-physical-stats-transact-sql)
- [Максимальные значения емкости для SQL Server](https://learn.microsoft.com/ru-ru/sql/sql-server/maximum-capacity-specifications-for-sql-server) — лимиты ключа индекса
- [Увеличенный размер ключа некластерного индекса в SQL Server 2016](https://learn.microsoft.com/en-us/archive/blogs/sqlserverstorageengine/increased-nonclustered-index-key-size-with-sql-server-2016)
- [Создание фильтруемых индексов](https://learn.microsoft.com/ru-ru/sql/relational-databases/indexes/create-filtered-indexes)
- [Сжатие данных](https://learn.microsoft.com/ru-ru/sql/relational-databases/data-compression/data-compression)
- [Скрипты обслуживания Ola Hallengren](https://ola.hallengren.com/) — `IndexOptimize`

### PostgreSQL (актуальная документация)
- [Индексы](https://postgrespro.ru/docs/postgresql/17/indexes)
- [Регулярная очистка (VACUUM)](https://postgrespro.ru/docs/postgresql/17/routine-vacuuming)
- [Секционирование таблиц](https://postgrespro.ru/docs/postgresql/17/ddl-partitioning)
- [pgstattuple](https://postgrespro.ru/docs/postgresql/17/pgstattuple)
- [pg_stat_statements](https://postgrespro.ru/docs/postgresql/17/pgstatstatements)
- [REINDEX](https://postgrespro.ru/docs/postgresql/17/sql-reindex)
- Цикл Е. Рогова «Индексы в PostgreSQL» на Хабре — все части (B-tree, Hash, GiST, SP-GiST, GIN, BRIN и др.), начиная с [первой](https://habr.com/ru/companies/postgrespro/articles/326096/)

### Обе СУБД
- [Use The Index, Luke!](https://use-the-index-luke.com/) — индексы на примерах для MS SQL, PostgreSQL и других СУБД

### 1С (its.1c.ru, нужна подписка ИТС)
- [Индексы таблиц базы данных: регистр накопления](https://its.1c.ru/db/pubapplied/content/355/hdoc) и соседние разделы
- [Методическая поддержка для разработчиков и администраторов](https://its.1c.ru/db/metod8dev) — регламентные операции на уровне СУБД для MS SQL и PostgreSQL, особенности работы с PostgreSQL
- [Стандарты и методики разработки](https://its.1c.ru/db/v8std) — индексирование реквизитов, эффективные условия запросов
- Синтакс-помощник: `ПолучитьСтруктуруХраненияБазыДанных()`

### 1С — к разделам 5.5–5.10
- [Использование временных таблиц](https://its.1c.ru/db/content/v8std/src/300/200/i8100777.htm) — стандарт 1С: когда индексировать временные таблицы ([5.8](05-1c.md))
- [Режим разделения итогов для регистров накопления](https://its.1c.ru/db/content/v8std/src/300/400/i8100664.htm) — стандарт 1С ([5.10](05-1c.md))
- [Индексы таблиц 1С](https://pbazeliuk.com/2017/04/28/1c-expert-7-1-7-49/) — П. Базелюк, конспект к 1С:Эксперту: кластерные индексы, ведущие измерения, разделители, Splitter ([5.1](05-1c.md), [5.10](05-1c.md))
- [4 способа ускорить запись в регистры](https://xn----1-bedvffifm4g.xn--p1ai/news/2017-03-27-four-methods-of-write-acceleration/) — А. Бурмистров, в том числе разделение итогов
- [Физические таблицы объектов конфигурации](https://almaz-sharipov.ru/article/1c-expert/tables) — состав таблиц регистров бухгалтерии и расчёта ([5.5](05-1c.md))
- [GUID в 1С: устройство, использование, нюансы](https://1c.alexcode.ru/guid-v-1s-ustrojstvo-ispolzovanie-nekotorye-nyuansy/) — как генерируются ссылки ([5.6](05-1c.md))
- «Реализация прикладных задач в системе 1С:Предприятие 8» (ИТС), глава «Вопросы производительности регистра бухгалтерии» — индексы таблиц итогов и влияние типа субконто

---

[← Шпаргалка](07-shpargalka.md) · [Оглавление](../README.md)

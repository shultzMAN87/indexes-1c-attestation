-- =============================================================================
-- 07_rcsi_version_tag.sql — как READ COMMITTED SNAPSHOT меняет строки и страницы
-- К разделу 2.10 методички.
--
-- Что показывает:
--   1. Без версионирования UPDATE колонки фиксированной длины не меняет размер
--      записи — страницы не расщепляются.
--   2. После включения READ_COMMITTED_SNAPSHOT каждая изменённая запись получает
--      14-байтовую метку версии: записи растут, плотно заполненные страницы
--      (fill factor 100) расщепляются, страниц становится почти вдвое больше.
--   3. Где смотреть version store и ghost-записи.
--
-- Создаёт и удаляет отдельную базу demo_rcsi. НЕ запускать на сервере с базами 1С
-- в рабочее время: переключение READ_COMMITTED_SNAPSHOT требует монопольного
-- доступа к базе (здесь это только demo_rcsi).
-- =============================================================================

USE master;
GO
IF DB_ID(N'demo_rcsi') IS NOT NULL
BEGIN
    ALTER DATABASE demo_rcsi SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE demo_rcsi;
END;
GO
CREATE DATABASE demo_rcsi;
GO
ALTER DATABASE demo_rcsi SET READ_COMMITTED_SNAPSHOT OFF;
GO
USE demo_rcsi;
GO

-- Запись: int + int + char(200) + служебные байты ≈ 215 байт → ~37 записей на страницу.
CREATE TABLE dbo.T
(
    id  int       NOT NULL CONSTRAINT PK_T PRIMARY KEY CLUSTERED,
    val int       NOT NULL,
    pad char(200) NOT NULL
);

INSERT INTO dbo.T (id, val, pad)
SELECT TOP (100000)
       ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 0, 'x'
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

-- Страницы заполнены «под завязку».
ALTER INDEX PK_T ON dbo.T REBUILD WITH (FILLFACTOR = 100);
GO

-- Процедура замера: листовой уровень кластерного индекса.
CREATE OR ALTER PROCEDURE dbo.ShowLeaf @step nvarchar(100)
AS
SELECT @step                                     AS step,
       ips.page_count,
       ips.avg_record_size_in_bytes,
       ips.max_record_size_in_bytes,
       CAST(ips.avg_page_space_used_in_percent AS decimal(5,1)) AS page_fullness_pct,
       ips.ghost_record_count,
       ips.version_ghost_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.T'), 1, NULL, 'DETAILED') AS ips
WHERE ips.index_level = 0;
GO

EXEC dbo.ShowLeaf N'0. После REBUILD, RCSI выключен';
-- Ожидаемо: ~2 700 страниц, запись ~215 байт, заполнение ~99%.

-- -----------------------------------------------------------------------------
-- 1. UPDATE без версионирования
-- -----------------------------------------------------------------------------
UPDATE dbo.T SET val = 1;
EXEC dbo.ShowLeaf N'1. UPDATE при RCSI = OFF';
-- Ожидаемо: число страниц и размер записи не изменились — int обновлён на месте.

-- -----------------------------------------------------------------------------
-- 2. Включаем RCSI (так работает база 1С в режиме управляемых блокировок)
-- -----------------------------------------------------------------------------
ALTER DATABASE demo_rcsi SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
SELECT name, is_read_committed_snapshot_on, snapshot_isolation_state_desc
FROM sys.databases WHERE name = N'demo_rcsi';
GO

-- Сбросим счётчики операций: смотрим расщепления только от следующего UPDATE.
DECLARE @before bigint =
    (SELECT leaf_allocation_count
     FROM sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID(N'dbo.T'), 1, NULL));

UPDATE dbo.T SET val = 2;

SELECT (SELECT leaf_allocation_count
        FROM sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID(N'dbo.T'), 1, NULL))
       - @before AS leaf_page_splits_by_update;
GO
EXEC dbo.ShowLeaf N'2. UPDATE при RCSI = ON';
-- Ожидаемо: запись выросла на 14 байт (~229), свободных 14 × 37 ≈ 520 байт
-- на полной странице нет → почти каждая страница расщепилась: страниц ~в 2 раза
-- больше, заполнение ~50–60%, leaf_page_splits_by_update ≈ исходному числу страниц.

-- -----------------------------------------------------------------------------
-- 3. Version store и ghost-записи
-- -----------------------------------------------------------------------------
-- Размер version store по базам (SQL Server 2016 SP2 / 2017+). Без ADR версии
-- лежат в tempdb; при включённом ADR (2019+) — в самой базе (PVS).
SELECT DB_NAME(database_id) AS db, reserved_page_count, reserved_space_kb
FROM sys.dm_tran_version_store_space_usage;

-- Самые старые активные snapshot-транзакции — пока они живы, версии и
-- ghost-записи не очищаются.
SELECT session_id, transaction_id, elapsed_time_seconds
FROM sys.dm_tran_active_snapshot_database_transactions
ORDER BY elapsed_time_seconds DESC;

-- Удалим часть строк: записи сначала становятся ghost и удаляются фоновой
-- задачей ghost cleanup позже (обычно в течение секунд, если версии не нужны).
DELETE FROM dbo.T WHERE id % 10 = 0;
EXEC dbo.ShowLeaf N'3. Сразу после DELETE';
-- Ожидаемо: ghost_record_count / version_ghost_record_count > 0.
-- Повторите через минуту — счётчики уйдут к нулю.

-- -----------------------------------------------------------------------------
-- 4. Перестроение
-- -----------------------------------------------------------------------------
ALTER INDEX PK_T ON dbo.T REBUILD WITH (FILLFACTOR = 100);
EXEC dbo.ShowLeaf N'4. После REBUILD при RCSI = ON';
-- Сравните avg_record_size_in_bytes с шагом 2: остались ли метки версии
-- после перестроения на вашей версии SQL Server. Если сняты — следующий
-- массовый UPDATE снова вызовет волну расщеплений (см. раздел 2.10).

-- -----------------------------------------------------------------------------
-- Уборка
-- -----------------------------------------------------------------------------
-- USE master; ALTER DATABASE demo_rcsi SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE demo_rcsi;

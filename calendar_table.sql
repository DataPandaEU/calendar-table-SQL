-------------------------------------------------------------------------------
-- 0) Safety/Housekeeping
--		Select database
-------------------------------------------------------------------------------
USE [AdventureWorksDW2022]; 
SET NOCOUNT ON;


-------------------------------------------------------------------------------
-- 1) Define fiscal year parameters
-------------------------------------------------------------------------------
-- Example: FY25 runs from 2024-06-01 (start) to 2025-05-31 (end).
-- In your question, you want the end to be May 29, so we'll adjust below.
-------------------------------------------------------------------------------
DECLARE @FiscalYearStartDate DATE = '2024-07-01';  -- <== Adjust as needed
--DECLARE @FiscalYearNumber    INT  = 25;            -- <== Example; optional

DECLARE @FiscalYearStartMonth INT = 1;
SET @FiscalYearStartMonth = (SELECT MONTH(@FiscalYearStartDate));



-------------------------------------------------------------------------------
-- 1) Define Columns to Exclude
-- This istep is optional
-------------------------------------------------------------------------------
DROP TABLE IF EXISTS #ExcludeColumns;

CREATE TABLE #ExcludeColumns (
    ColumnName NVARCHAR(255)
);

INSERT INTO #ExcludeColumns (ColumnName)
VALUES 
    ('dbo.DimCustomer.BirthDate'),
    ('dbo.DimEmployee.BirthDate'),
    ('dbo.ProspectiveBuyer.BirthDate');

-------------------------------------------------------------------------------
-- 2) Identify All Date Columns and Store in a Temporary Table
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#DateColumns') IS NOT NULL
    DROP TABLE #DateColumns;

CREATE TABLE #DateColumns
(
      SchemaName SYSNAME
    , TableName  SYSNAME
    , ColumnName SYSNAME
    , DataType   SYSNAME
);

INSERT INTO #DateColumns (SchemaName, TableName, ColumnName, DataType)
SELECT 
      s.name                    AS SchemaName
    , t.name                    AS TableName
    , c.name                    AS ColumnName
    , ty.name                   AS DataType
FROM sys.columns           AS c
JOIN sys.tables            AS t    ON c.object_id     = t.object_id
JOIN sys.schemas           AS s    ON t.schema_id     = s.schema_id
JOIN sys.types             AS ty   ON c.user_type_id  = ty.user_type_id
WHERE t.is_ms_shipped = 0
  AND ty.name IN ('date', 'datetime', 'datetime2', 'datetimeoffset', 'smalldatetime')
  -- Columns to exclude
  -- You can remove this if necesarry or add your own logic to define the date columns in scope
  AND s.name + '.' + t.name + '.' + c.name NOT IN (
        SELECT ColumnName COLLATE Latin1_General_CI_AS 
        FROM #ExcludeColumns
     )
ORDER BY s.name, t.name, c.column_id;

-------------------------------------------------------------------------------
-- 3) Build Dynamic SQL to Retrieve MIN and MAX Date Values for Each Column
-------------------------------------------------------------------------------
DECLARE @SQL  NVARCHAR(MAX) = N'';
DECLARE @CRLF NVARCHAR(2)   = NCHAR(13) + NCHAR(10);

SELECT @SQL += 
    N'SELECT ' + 
        N'''' + DC.SchemaName + N'.' + DC.TableName + N'.' + DC.ColumnName + ''' AS [Table.Column],' + @CRLF + 
        N'       MIN(CAST(' + QUOTENAME(DC.ColumnName) + N' AS DATE)) AS MinDate,' + @CRLF +
        N'       MAX(CAST(' + QUOTENAME(DC.ColumnName) + N' AS DATE)) AS MaxDate' + @CRLF +
    N'FROM ' + QUOTENAME(DC.SchemaName) + N'.' + QUOTENAME(DC.TableName) + N' WITH (NOLOCK)' + @CRLF +
    N'WHERE ' + QUOTENAME(DC.ColumnName) + N' IS NOT NULL' + @CRLF +
    N'UNION ALL' + @CRLF
FROM #DateColumns AS DC;

-- Remove trailing "UNION ALL" if we have at least one row
IF EXISTS (SELECT 1 FROM #DateColumns)
BEGIN
    SET @SQL = LEFT(@SQL, LEN(@SQL) - LEN(@CRLF) - 9);
END
ELSE
BEGIN
    SET @SQL = N'SELECT ''No date/datetime columns found'' AS [Message]';
END

-------------------------------------------------------------------------------
-- 4) Create a Temporary Table to Hold the Results
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#DateRanges') IS NOT NULL
    DROP TABLE #DateRanges;

CREATE TABLE #DateRanges
(
      TableColumn SYSNAME
    , MinDate     DATE
    , MaxDate     DATE
);

-------------------------------------------------------------------------------
-- 5) Insert Dynamic SQL Output into #DateRanges
-------------------------------------------------------------------------------
INSERT INTO #DateRanges (TableColumn, MinDate, MaxDate)
EXEC sys.sp_executesql @SQL;

-------------------------------------------------------------------------------
-- 6) Get Overall Minimum and Maximum Date from #DateRanges
-------------------------------------------------------------------------------
DECLARE @MinDate DATE, @MaxDate DATE;

SET @MinDate = (SELECT MIN(MinDate) FROM #DateRanges WHERE MinDate IS NOT NULL);
SET @MaxDate = (SELECT MAX(MaxDate) FROM #DateRanges WHERE MaxDate IS NOT NULL);

-- Handle NULL Cases Gracefully
IF @MinDate IS NULL OR @MaxDate IS NULL
BEGIN
    PRINT 'No valid date ranges found!';
    RETURN;
END

-------------------------------------------------------------------------------
-- 8) Snap @MinDate to the closest prior fiscal year start
--    Snap @MaxDate to the next fiscal year end
--    (in this script, the "end" is May 29 if you want 2 days before May 31)
-------------------------------------------------------------------------------
DECLARE @TempFYStart DATE, @TempFYEnd DATE;

/*-----------------------------------------------------------------------------
    A) Snap @MinDate "down" to earliest FY start
-----------------------------------------------------------------------------*/
SET @TempFYStart = DATEADD(
    YEAR, 
    DATEDIFF(YEAR, @FiscalYearStartDate, @MinDate), 
    @FiscalYearStartDate
);

IF @TempFYStart > @MinDate
BEGIN
    SET @TempFYStart = DATEADD(YEAR, -1, @TempFYStart);
END;

SET @MinDate = @TempFYStart;

/*-----------------------------------------------------------------------------
    B) Snap @MaxDate "up" to next FY end
-----------------------------------------------------------------------------*/
-- 1) Find the start of the FY that @MaxDate belongs to
SET @TempFYStart = DATEADD(
    YEAR, 
    DATEDIFF(YEAR, @FiscalYearStartDate, @MaxDate), 
    @FiscalYearStartDate
);

IF @TempFYStart > @MaxDate
BEGIN
    SET @TempFYStart = DATEADD(YEAR, -1, @TempFYStart);
END;

-- 2) End of that FY = 2 days before the next year's start
SET @TempFYEnd = DATEADD(DAY, -1, DATEADD(YEAR, 1, @TempFYStart));

IF @TempFYEnd < @MaxDate
BEGIN
    -- If somehow that is still before @MaxDate, shift one more year
    SET @TempFYEnd = DATEADD(YEAR, 1, @TempFYEnd);
END;

SET @MaxDate = @TempFYEnd;

-------------------------------------------------------------------------------
-- 9) Create and Populate the Calendar Table
-------------------------------------------------------------------------------
DROP TABLE IF EXISTS #Calendar;

CREATE TABLE #Calendar (
    DateKey              DATE PRIMARY KEY,
    YearNumber           INT,
    MonthNumber          INT,
    MonthNumberText      CHAR(2),
    MonthName            VARCHAR(20),
	Semester			 INT,
    DayOfMonthNumber     INT,
    DayOfWeekNumber      INT,
    DayOfWeekName        VARCHAR(20),
    CalendarYearDayNumber INT,
    CalendarYearQuarter  INT,
    CalendarYearQuarterText VARCHAR(3),
    FiscalYearNumber     INT,
	FiscalYear			 VARCHAR(4),
    FiscalMonthNumber    INT,
    FiscalMonthText      CHAR(2),
    FiscalYearDayNumber  INT,
    FiscalYearQuarter    INT,
    FiscalYearQuarterText VARCHAR(3),
    FiscalPeriod         VARCHAR(10),
	FiscalYearStart		 DATE,
	FiscalSemester       INT
);

WITH DateSeries AS (
    SELECT @MinDate AS DateKey
    UNION ALL
    SELECT DATEADD(DAY, 1, DateKey)
    FROM DateSeries
    WHERE DateKey < @MaxDate
)
INSERT INTO #Calendar 
(
    DateKey, YearNumber, MonthNumber, MonthNumberText, MonthName, Semester,
    DayOfMonthNumber, DayOfWeekNumber, DayOfWeekName,
    CalendarYearDayNumber, CalendarYearQuarter, CalendarYearQuarterText,
    FiscalYearNumber, FiscalYear, FiscalMonthNumber, FiscalMonthText,
    FiscalYearDayNumber, FiscalYearQuarter, FiscalYearQuarterText, FiscalPeriod,
	FiscalYearStart, FiscalSemester
)
SELECT 
    DateKey,
    YEAR(DateKey) AS YearNumber,
	-- MonthNumber
    MONTH(DateKey) AS MonthNumber,
	-- MonthNumberText
    FORMAT(MONTH(DateKey), '00') AS MonthNumberText,
	-- MonthName
    DATENAME(MONTH, DateKey) AS MonthName,
	-- Semester
	CASE WHEN MONTH(DateKey) <= 6 THEN 1 ELSE 2 END AS Semester,
	-- DayOfMonthNumber
    DAY(DateKey) AS DayOfMonthNumber,
	-- DayOfWeekNumber
    DATEPART(WEEKDAY, DateKey) AS DayOfWeekNumber,
	-- DayOfWeekName
    DATENAME(WEEKDAY, DateKey) AS DayOfWeekName,
	-- CalendarYearDayNumber
    DATEDIFF(DAY, DATEFROMPARTS(YEAR(DateKey), 1, 1), DateKey) + 1 AS CalendarYearDayNumber,
	-- CalendarYearQuarter
    DATEPART(QUARTER, DateKey) AS CalendarYearQuarter,
	-- CalendarYearQuarterText
    'Q' + CAST(DATEPART(QUARTER, DateKey) AS VARCHAR) AS CalendarYearQuarterText,
	-- FiscalYearNumber
    RIGHT(CASE 
        WHEN @FiscalYearStartMonth > 1 AND MONTH(DateKey) >= @FiscalYearStartMonth THEN YEAR(DateKey) + 1 
        ELSE YEAR(DateKey)
    END, 2) AS FiscalYearNumber,
	-- FiscalYear
	'FY' + RIGHT(CASE 
        WHEN @FiscalYearStartMonth > 1 AND MONTH(DateKey) >= @FiscalYearStartMonth THEN YEAR(DateKey) + 1 
        ELSE YEAR(DateKey)
    END, 2) AS FiscalYear,
	-- FiscalMonthNumber
    ((MONTH(DateKey) - @FiscalYearStartMonth + 12) % 12) + 1 AS FiscalMonthNumber,
	-- FiscalMonthText
    FORMAT(((MONTH(DateKey) - @FiscalYearStartMonth + 12) % 12) + 1, '00') AS FiscalMonthText,
	-- FiscalYearDayNumber
	DATEDIFF(DAY,
	DATEFROMPARTS(
    CASE 
        WHEN MONTH(DateKey) >= @FiscalYearStartMonth 
        THEN YEAR(DateKey) 
        ELSE YEAR(DateKey) - 1 
    END,
    @FiscalYearStartMonth,
    1
	)
	, DateKey) + 1 AS FiscalYearDayNumber,
	-- FiscalYearQuarter
    ((MONTH(DateKey) - @FiscalYearStartMonth + 12) % 12) / 3 + 1 AS FiscalYearQuarter,
	-- FiscalYearQuarterText
    'Q' + CAST((((MONTH(DateKey) - @FiscalYearStartMonth + 12) % 12) / 3 + 1) AS VARCHAR) AS FiscalYearQuarterText,
	-- FiscalPeriod
    'FY' + RIGHT(CASE 
        WHEN @FiscalYearStartMonth > 1 AND MONTH(DateKey) >= @FiscalYearStartMonth THEN YEAR(DateKey) + 1 
        ELSE YEAR(DateKey)
    END, 2) 
    + '-' + 
    FORMAT(((MONTH(DateKey) - @FiscalYearStartMonth + 12) % 12) + 1, '00') AS FiscalPeriod,
	-- FiscalYearStart
	DATEFROMPARTS(
    CASE 
        WHEN MONTH(DateKey) >= @FiscalYearStartMonth 
        THEN YEAR(DateKey) 
        ELSE YEAR(DateKey) - 1 
    END,
    @FiscalYearStartMonth,
    1
	) AS FiscalYearStart,
	-- FiscalSemester
	CASE WHEN (((MONTH(DateKey) - @FiscalYearStartMonth + 12) % 12) + 1) <= 6 THEN 1 ELSE 2 END AS FiscalSemester
FROM DateSeries
OPTION (MAXRECURSION 0);

-------------------------------------------------------------------------------
-- 10) Final Results
-------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.CalendarTable;

SELECT * 
INTO dbo.CalendarTable
FROM #Calendar ORDER BY DateKey;
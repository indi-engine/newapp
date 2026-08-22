SET XACT_ABORT ON;
SET NOCOUNT ON;

BEGIN TRY
  BEGIN TRANSACTION;

-- Spoof MySQL-specific field.columnTypeId values with SQL Server-specific ones
UPDATE [f]
SET [columnTypeId] = [sqlserver].[id]
FROM [system].[field] AS [f]
  JOIN [system].[columnType] AS [mysql] ON [mysql].[id] = [f].[columnTypeId]
  JOIN [system].[columnType] AS [sqlserver] ON [sqlserver].[kind] = [mysql].[kind] AND (
    ([sqlserver].[isDefault] = 'y' AND [mysql].[isDefault] = 'y')
    OR
    [sqlserver].[type] =
      CASE [mysql].[kind]
        WHEN 'string'    THEN REPLACE([mysql].[type], 'VARCHAR', 'NVARCHAR')
        WHEN 'timestamp' THEN REPLACE([mysql].[type], 'TIMESTAMP', 'DATETIMEOFFSET')
        WHEN 'datetime'  THEN REPLACE([mysql].[type], 'DATETIME', 'DATETIME2')
        ELSE [mysql].[type]
      END
  )
WHERE CAST([mysql].[engines] AS VARCHAR(MAX)) LIKE '%mysql%'
  AND CAST([sqlserver].[engines] AS VARCHAR(MAX)) LIKE '%sqlserver%'
  AND [mysql].[id] <> [sqlserver].[id];

-- Spoof MySQL-specific element.defaultType values with SQL Server-specific ones
UPDATE [e]
SET [defaultType] = [sqlserver].[id]
FROM [system].[element] AS [e]
  JOIN [system].[columnType] AS [mysql] ON [mysql].[id] = [e].[defaultType]
  JOIN [system].[columnType] AS [sqlserver] ON [sqlserver].[kind] = [mysql].[kind] AND (
    ([sqlserver].[isDefault] = 'y' AND [mysql].[isDefault] = 'y')
    OR
    [sqlserver].[type] =
      CASE [mysql].[kind]
        WHEN 'string'    THEN REPLACE([mysql].[type], 'VARCHAR', 'NVARCHAR')
        WHEN 'timestamp' THEN REPLACE([mysql].[type], 'TIMESTAMP', 'DATETIMEOFFSET')
        WHEN 'datetime'  THEN REPLACE([mysql].[type], 'DATETIME', 'DATETIME2')
        ELSE [mysql].[type]
      END
  )
WHERE CAST([mysql].[engines] AS VARCHAR(MAX)) LIKE '%mysql%'
  AND CAST([sqlserver].[engines] AS VARCHAR(MAX)) LIKE '%sqlserver%'
  AND [mysql].[id] <> [sqlserver].[id];

-- Convert SSMA-calculated integer-list column types to VARCHAR(2999)
DECLARE
  @intSchemaName SYSNAME,
  @intTableName SYSNAME,
  @intColumnName SYSNAME,
  @intNullability VARCHAR(1),
  @intQualifiedTable NVARCHAR(517),
  @intDefaultName SYSNAME,
  @intSql NVARCHAR(MAX);

SELECT
    CASE [e].[fraction] WHEN 'system' THEN N'system' ELSE N'dbo' END AS [schemaName],
    [e].[table] AS [tableName],
    [f].[alias] AS [columnName],
    [f].[nullability]
  INTO [#integer_list_fields]
  FROM [system].[field] AS [f]
    JOIN [system].[entity] AS [e] ON [e].[id] = [f].[entityId]
    JOIN [system].[columnType] AS [ct] ON [ct].[id] = [f].[columnTypeId]
  WHERE [f].[entry] = 0
    AND [ct].[kind] = 'integer[]'
    AND [ct].[type] = 'VARCHAR(2999)'
    AND CAST([ct].[engines] AS VARCHAR(MAX)) LIKE '%sqlserver%';

DECLARE [integer_list_fields] CURSOR LOCAL FAST_FORWARD FOR
  SELECT [schemaName], [tableName], [columnName], [nullability]
  FROM [#integer_list_fields];

OPEN [integer_list_fields];

FETCH NEXT FROM [integer_list_fields] INTO
  @intSchemaName,
  @intTableName,
  @intColumnName,
  @intNullability;

WHILE @@FETCH_STATUS = 0
BEGIN
  SET @intQualifiedTable = QUOTENAME(@intSchemaName) + N'.' + QUOTENAME(@intTableName);

  PRINT LEFT(N'CSV: ' + @intQualifiedTable + N'.' + QUOTENAME(@intColumnName), 79);

  SET @intDefaultName = NULL;
  SELECT @intDefaultName = [dc].[name]
  FROM [sys].[default_constraints] AS [dc]
    JOIN [sys].[columns] AS [c]
      ON [c].[object_id] = [dc].[parent_object_id]
     AND [c].[column_id] = [dc].[parent_column_id]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [c].[object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
  WHERE [s].[name] = @intSchemaName
    AND [t].[name] = @intTableName
    AND [c].[name] = @intColumnName;

  IF @intDefaultName IS NOT NULL
  BEGIN
    SET @intSql = N'ALTER TABLE ' + @intQualifiedTable
      + N' DROP CONSTRAINT ' + QUOTENAME(@intDefaultName) + N';';
    EXEC sys.sp_executesql @intSql;
  END;

  SET @intSql = N'ALTER TABLE ' + @intQualifiedTable
    + N' ALTER COLUMN ' + QUOTENAME(@intColumnName) + N' VARCHAR(2999) '
    + CASE WHEN @intNullability = 'y' THEN N'NULL' ELSE N'NOT NULL' END + N';';
  EXEC sys.sp_executesql @intSql;

  SET @intSql = N'ALTER TABLE ' + @intQualifiedTable
    + N' ADD DEFAULT '''' FOR ' + QUOTENAME(@intColumnName) + N';';
  EXEC sys.sp_executesql @intSql;

  FETCH NEXT FROM [integer_list_fields] INTO
    @intSchemaName,
    @intTableName,
    @intColumnName,
    @intNullability;
END;

CLOSE [integer_list_fields];
DEALLOCATE [integer_list_fields];
DROP TABLE [#integer_list_fields];

-- Convert former MySQL SET-columns to JSON type with CHECK-constraints
DECLARE
  @schemaName SYSNAME,
  @tableName SYSNAME,
  @columnName SYSNAME,
  @defaultValue NVARCHAR(MAX),
  @nullability VARCHAR(1),
  @whitelist VARCHAR(8000),
  @defaultJson NVARCHAR(MAX),
  @pattern VARCHAR(8000),
  @qualifiedTable NVARCHAR(517),
  @constraintName SYSNAME,
  @defaultName SYSNAME,
  @sql NVARCHAR(MAX);

SELECT
    CASE [e].[fraction] WHEN 'system' THEN N'system' ELSE N'dbo' END AS [schemaName],
    [e].[table] AS [tableName],
    [f].[alias] AS [columnName],
    [f].[defaultValue],
    [f].[nullability],
    STRING_AGG(
      CAST(REGEXP_REPLACE(
        STRING_ESCAPE([enumset].[alias], 'json'),
        '([\\.^$|?*+(){}\[\]])',
        '\\\1'
      ) AS VARCHAR(MAX)),
      '|'
    ) WITHIN GROUP (ORDER BY [enumset].[move]) AS [whitelist]
  INTO [#enum_fields]
  FROM [system].[field] AS [f]
    JOIN [system].[entity] AS [e] ON [e].[id] = [f].[entityId]
    JOIN [system].[columnType] AS [ct] ON [ct].[id] = [f].[columnTypeId]
    JOIN [system].[enumset] AS [enumset] ON [enumset].[fieldId] = [f].[id]
    JOIN [sys].[schemas] AS [physicalSchema]
      ON [physicalSchema].[name] = CASE [e].[fraction] WHEN 'system' THEN N'system' ELSE N'dbo' END
    JOIN [sys].[tables] AS [physicalTable]
      ON [physicalTable].[schema_id] = [physicalSchema].[schema_id]
     AND [physicalTable].[name] = [e].[table]
    JOIN [sys].[columns] AS [physicalColumn]
      ON [physicalColumn].[object_id] = [physicalTable].[object_id]
     AND [physicalColumn].[name] = [f].[alias]
    JOIN [sys].[types] AS [physicalType]
      ON [physicalType].[user_type_id] = [physicalColumn].[user_type_id]
  WHERE [f].[entry] = 0
    AND [ct].[kind] = 'enum[]'
    AND [ct].[type] = 'JSON + CHECK'
    AND CAST([ct].[engines] AS VARCHAR(MAX)) LIKE '%sqlserver%'
    AND [physicalType].[name] <> N'json'
  GROUP BY
    [e].[fraction],
    [e].[table],
    [f].[alias],
    [f].[defaultValue],
    [f].[nullability];

DECLARE [enum_fields] CURSOR LOCAL FAST_FORWARD FOR
  SELECT
    [schemaName],
    [tableName],
    [columnName],
    [defaultValue],
    [nullability],
    [whitelist]
  FROM [#enum_fields];

OPEN [enum_fields];

FETCH NEXT FROM [enum_fields] INTO
  @schemaName,
  @tableName,
  @columnName,
  @defaultValue,
  @nullability,
  @whitelist;

WHILE @@FETCH_STATUS = 0
BEGIN
  SET @qualifiedTable = QUOTENAME(@schemaName) + N'.' + QUOTENAME(@tableName);
  SET @constraintName = LEFT(@tableName + N'_enum_' + @columnName, 128);
  SET @pattern = '^\[\s*(,?\s*"(' + @whitelist + ')"\s*)*\]$';
  SET @defaultJson = CASE
    WHEN ISNULL(@defaultValue, N'') = N'' THEN N'[]'
    ELSE N'["' + REPLACE(STRING_ESCAPE(@defaultValue, 'json'), N',', N'","') + N'"]'
  END;

  PRINT LEFT(N'JSON: ' + @qualifiedTable + N'.' + QUOTENAME(@columnName), 79);

  -- Drop indexes depending on current column
  SET @sql = NULL;
  SELECT @sql = STRING_AGG(
    CAST(
      N'DROP INDEX ' + QUOTENAME([i].[name]) + N' ON ' + @qualifiedTable + N';'
      AS NVARCHAR(MAX)
    ),
    NCHAR(10)
  )
  FROM [sys].[indexes] AS [i]
    JOIN [sys].[index_columns] AS [ic]
      ON [ic].[object_id] = [i].[object_id]
     AND [ic].[index_id] = [i].[index_id]
    JOIN [sys].[columns] AS [c]
      ON [c].[object_id] = [ic].[object_id]
     AND [c].[column_id] = [ic].[column_id]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [i].[object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
  WHERE [s].[name] = @schemaName
    AND [t].[name] = @tableName
    AND [c].[name] = @columnName
    AND [i].[is_primary_key] = 0
    AND [i].[is_unique_constraint] = 0;

  IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;

  -- Drop existing default-constraint
  SET @defaultName = NULL;
  SELECT @defaultName = [dc].[name]
  FROM [sys].[default_constraints] AS [dc]
    JOIN [sys].[columns] AS [c]
      ON [c].[object_id] = [dc].[parent_object_id]
     AND [c].[column_id] = [dc].[parent_column_id]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [c].[object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
  WHERE [s].[name] = @schemaName
    AND [t].[name] = @tableName
    AND [c].[name] = @columnName;

  IF @defaultName IS NOT NULL
  BEGIN
    SET @sql = N'ALTER TABLE ' + @qualifiedTable
      + N' DROP CONSTRAINT ' + QUOTENAME(@defaultName) + N';';
    EXEC sys.sp_executesql @sql;
  END;

  -- Widen current column before values are converted to JSON
  SET @sql = N'ALTER TABLE ' + @qualifiedTable
    + N' ALTER COLUMN ' + QUOTENAME(@columnName) + N' NVARCHAR(MAX) '
    + CASE WHEN @nullability = 'y' THEN N'NULL' ELSE N'NOT NULL' END + N';';
  EXEC sys.sp_executesql @sql;

  -- Convert existing comma-separated values to JSON arrays
  SET @sql = N'UPDATE ' + @qualifiedTable + N'
    SET ' + QUOTENAME(@columnName) + N' = CASE
      WHEN ' + QUOTENAME(@columnName) + N' IS NULL THEN NULL
      WHEN ' + QUOTENAME(@columnName) + N' = N'''' THEN N''[]''
      ELSE N''["'' + REPLACE(
        STRING_ESCAPE(CONVERT(NVARCHAR(MAX), ' + QUOTENAME(@columnName) + N'), ''json''),
        N'','', N''","''
      ) + N''"]''
    END;';
  EXEC sys.sp_executesql @sql;

  -- Convert column to native JSON
  SET @sql = N'ALTER TABLE ' + @qualifiedTable
    + N' ALTER COLUMN ' + QUOTENAME(@columnName) + N' JSON '
    + CASE WHEN @nullability = 'y' THEN N'NULL' ELSE N'NOT NULL' END + N';';
  EXEC sys.sp_executesql @sql;

  -- Restore default-value as JSON array
  SET @sql = N'ALTER TABLE ' + @qualifiedTable
    + N' ADD DEFAULT ''' + REPLACE(@defaultJson, N'''', N'''''')
    + N''' FOR ' + QUOTENAME(@columnName) + N';';
  EXEC sys.sp_executesql @sql;

  -- Add CHECK-constraint restricting JSON array item values
  SET @sql = N'ALTER TABLE ' + @qualifiedTable
    + N' ADD CONSTRAINT ' + QUOTENAME(@constraintName)
    + N' CHECK (REGEXP_LIKE(CAST(' + QUOTENAME(@columnName) + N' AS VARCHAR(MAX)), '''
    + REPLACE(@pattern, '''', '''''') + N''', ''c''));';
  EXEC sys.sp_executesql @sql;

  FETCH NEXT FROM [enum_fields] INTO
    @schemaName,
    @tableName,
    @columnName,
    @defaultValue,
    @nullability,
    @whitelist;
END;

CLOSE [enum_fields];
DEALLOCATE [enum_fields];
DROP TABLE [#enum_fields];

-- Replace SSMA UNIQUE-constraints with ordinary unique indexes
DECLARE @uniqueSql NVARCHAR(MAX);

SELECT
    [kc].[object_id] AS [constraintObjectId],
    [kc].[parent_object_id] AS [tableObjectId],
    [s].[name] AS [schemaName],
    [t].[name] AS [tableName],
    [kc].[name] AS [constraintName],
    STRING_AGG(CAST([c].[name] AS NVARCHAR(MAX)), N',')
      WITHIN GROUP (ORDER BY [ic].[key_ordinal]) AS [indexName],
    STRING_AGG(
      CAST(QUOTENAME([c].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN N' DESC' ELSE N' ASC' END AS NVARCHAR(MAX)),
      N', '
    ) WITHIN GROUP (ORDER BY [ic].[key_ordinal]) AS [columns]
  INTO [#unique_constraints]
  FROM [sys].[key_constraints] AS [kc]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [kc].[parent_object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
    JOIN [sys].[indexes] AS [i]
      ON [i].[object_id] = [kc].[parent_object_id]
     AND [i].[index_id] = [kc].[unique_index_id]
    JOIN [sys].[index_columns] AS [ic]
      ON [ic].[object_id] = [i].[object_id]
     AND [ic].[index_id] = [i].[index_id]
     AND [ic].[key_ordinal] > 0
    JOIN [sys].[columns] AS [c]
      ON [c].[object_id] = [ic].[object_id]
     AND [c].[column_id] = [ic].[column_id]
  WHERE [kc].[type] = N'UQ'
    AND [s].[name] IN (N'dbo', N'system')
  GROUP BY [kc].[object_id], [kc].[parent_object_id], [s].[name], [t].[name], [kc].[name];

IF EXISTS (SELECT 1 FROM [#unique_constraints] WHERE LEN([indexName]) > 128)
  THROW 50001, 'Generated UNIQUE index name exceeds 128 characters', 1;

IF EXISTS (
  SELECT 1
  FROM [#unique_constraints] AS [u]
  JOIN [sys].[indexes] AS [i]
    ON [i].[object_id] = [u].[tableObjectId]
   AND [i].[name] = [u].[indexName]
   AND [i].[name] <> [u].[constraintName]
)
  THROW 50002, 'Generated UNIQUE index name is already used on its table', 1;

DECLARE [unique_constraints] CURSOR LOCAL FAST_FORWARD FOR
  SELECT N'ALTER TABLE ' + QUOTENAME([schemaName]) + N'.' + QUOTENAME([tableName])
    + N' DROP CONSTRAINT ' + QUOTENAME([constraintName]) + N';'
    + N' CREATE UNIQUE INDEX ' + QUOTENAME([indexName]) + N' ON '
    + QUOTENAME([schemaName]) + N'.' + QUOTENAME([tableName]) + N' (' + [columns] + N');'
  FROM [#unique_constraints];

OPEN [unique_constraints];
FETCH NEXT FROM [unique_constraints] INTO @uniqueSql;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC [sys].[sp_executesql] @uniqueSql;
  FETCH NEXT FROM [unique_constraints] INTO @uniqueSql;
END;
CLOSE [unique_constraints];
DEALLOCATE [unique_constraints];
DROP TABLE [#unique_constraints];

-- Convert scalar MySQL ENUM-columns to VARCHAR(255) with CHECK-constraints
SELECT DISTINCT
    [ps].[name] AS [schemaName],
    [pt].[name] AS [tableName],
    [pc].[name] AS [columnName],
    [f].[nullability],
    [f].[defaultValue],
    [pt].[object_id] AS [tableObjectId],
    [pc].[column_id] AS [columnId]
  INTO [#scalar_enum_fields]
  FROM [system].[field] AS [f]
    JOIN [system].[entity] AS [e] ON [e].[id] = [f].[entityId]
    JOIN [system].[columnType] AS [ct] ON [ct].[id] = [f].[columnTypeId]
    JOIN [sys].[schemas] AS [ps]
      ON [ps].[name] = CASE [e].[fraction] WHEN 'system' THEN N'system' ELSE N'dbo' END
    JOIN [sys].[tables] AS [pt] ON [pt].[schema_id] = [ps].[schema_id] AND [pt].[name] = [e].[table]
    JOIN [sys].[columns] AS [pc] ON [pc].[object_id] = [pt].[object_id] AND [pc].[name] = [f].[alias]
    JOIN [sys].[types] AS [pty] ON [pty].[user_type_id] = [pc].[user_type_id]
  WHERE [f].[entry] = 0 AND [ct].[kind] = N'enum' AND [pty].[name] = N'nvarchar';

SELECT DISTINCT
    [i].[object_id], [i].[index_id], [s].[name] AS [schemaName], [t].[name] AS [tableName], [i].[name] AS [indexName],
    N'CREATE ' + CASE WHEN [i].[is_unique] = 1 THEN N'UNIQUE ' ELSE N'' END
      + CASE [i].[type] WHEN 1 THEN N'CLUSTERED ' ELSE N'NONCLUSTERED ' END
      + N'INDEX ' + QUOTENAME([i].[name]) + N' ON ' + QUOTENAME([s].[name]) + N'.' + QUOTENAME([t].[name])
      + N' (' + [keys].[list] + N')'
      + CASE WHEN [includes].[list] IS NULL THEN N'' ELSE N' INCLUDE (' + [includes].[list] + N')' END
      + CASE WHEN [i].[has_filter] = 1 THEN N' WHERE ' + [i].[filter_definition] ELSE N'' END + N';' AS [createSql]
  INTO [#scalar_enum_indexes]
  FROM [sys].[indexes] AS [i]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [i].[object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
    CROSS APPLY (SELECT STRING_AGG(CAST(QUOTENAME([c].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN N' DESC' ELSE N' ASC' END AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY [ic].[key_ordinal]) AS [list] FROM [sys].[index_columns] [ic] JOIN [sys].[columns] [c] ON [c].[object_id]=[ic].[object_id] AND [c].[column_id]=[ic].[column_id] WHERE [ic].[object_id]=[i].[object_id] AND [ic].[index_id]=[i].[index_id] AND [ic].[key_ordinal]>0) [keys]
    OUTER APPLY (SELECT STRING_AGG(CAST(QUOTENAME([c].[name]) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY [ic].[index_column_id]) AS [list] FROM [sys].[index_columns] [ic] JOIN [sys].[columns] [c] ON [c].[object_id]=[ic].[object_id] AND [c].[column_id]=[ic].[column_id] WHERE [ic].[object_id]=[i].[object_id] AND [ic].[index_id]=[i].[index_id] AND [ic].[is_included_column]=1) [includes]
  WHERE [i].[name] IS NOT NULL AND [i].[is_primary_key]=0 AND [i].[is_unique_constraint]=0
    AND EXISTS (SELECT 1 FROM [sys].[index_columns] [x] JOIN [#scalar_enum_fields] [f] ON [f].[tableObjectId]=[x].[object_id] AND [f].[columnId]=[x].[column_id] WHERE [x].[object_id]=[i].[object_id] AND [x].[index_id]=[i].[index_id]);

SELECT @uniqueSql = STRING_AGG(CAST(N'DROP INDEX ' + QUOTENAME([indexName]) + N' ON ' + QUOTENAME([schemaName]) + N'.' + QUOTENAME([tableName]) + N';' AS NVARCHAR(MAX)), NCHAR(10)) FROM [#scalar_enum_indexes];
IF @uniqueSql IS NOT NULL EXEC [sys].[sp_executesql] @uniqueSql;

DECLARE @enumSchema SYSNAME, @enumTable SYSNAME, @enumColumn SYSNAME, @enumNullability VARCHAR(1), @enumDefault NVARCHAR(MAX), @enumValues NVARCHAR(MAX), @enumDefaultConstraint SYSNAME;
DECLARE [scalar_enum_fields] CURSOR LOCAL FAST_FORWARD FOR SELECT [schemaName],[tableName],[columnName],[nullability],[defaultValue] FROM [#scalar_enum_fields];
OPEN [scalar_enum_fields];
FETCH NEXT FROM [scalar_enum_fields] INTO @enumSchema,@enumTable,@enumColumn,@enumNullability,@enumDefault;
WHILE @@FETCH_STATUS = 0
BEGIN
  SELECT @enumDefaultConstraint = [dc].[name] FROM [sys].[default_constraints] [dc] JOIN [sys].[columns] [c] ON [c].[object_id]=[dc].[parent_object_id] AND [c].[column_id]=[dc].[parent_column_id] JOIN [sys].[tables] [t] ON [t].[object_id]=[c].[object_id] JOIN [sys].[schemas] [s] ON [s].[schema_id]=[t].[schema_id] WHERE [s].[name]=@enumSchema AND [t].[name]=@enumTable AND [c].[name]=@enumColumn;
  IF @enumDefaultConstraint IS NOT NULL
  BEGIN
    SET @uniqueSql = N'ALTER TABLE ' + QUOTENAME(@enumSchema) + N'.' + QUOTENAME(@enumTable)
      + N' DROP CONSTRAINT ' + QUOTENAME(@enumDefaultConstraint);
    EXEC [sys].[sp_executesql] @uniqueSql;
  END;
  SET @uniqueSql=N'ALTER TABLE '+QUOTENAME(@enumSchema)+N'.'+QUOTENAME(@enumTable)+N' ALTER COLUMN '+QUOTENAME(@enumColumn)+N' VARCHAR(255) '+CASE WHEN @enumNullability='y' THEN N'NULL' ELSE N'NOT NULL' END+N';';
  EXEC [sys].[sp_executesql] @uniqueSql;
  SET @uniqueSql=N'ALTER TABLE '+QUOTENAME(@enumSchema)+N'.'+QUOTENAME(@enumTable)+N' ADD DEFAULT '''+REPLACE(COALESCE(@enumDefault,N''),N'''',N'''''')+N''' FOR '+QUOTENAME(@enumColumn)+N';';
  EXEC [sys].[sp_executesql] @uniqueSql;
  SELECT @enumValues=STRING_AGG(CAST(N''''+REPLACE([es].[alias],N'''',N'''''')+N'''' AS NVARCHAR(MAX)),N',') WITHIN GROUP (ORDER BY [es].[move]) FROM [system].[enumset] [es] JOIN [system].[field] [f] ON [f].[id]=[es].[fieldId] JOIN [system].[entity] [e] ON [e].[id]=[f].[entityId] WHERE CASE [e].[fraction] WHEN 'system' THEN N'system' ELSE N'dbo' END=@enumSchema AND [e].[table]=@enumTable AND [f].[alias]=@enumColumn;
  IF @enumValues IS NOT NULL BEGIN SET @uniqueSql=N'ALTER TABLE '+QUOTENAME(@enumSchema)+N'.'+QUOTENAME(@enumTable)+N' ADD CONSTRAINT '+QUOTENAME(LEFT(@enumTable+N'_enum_'+@enumColumn,128))+N' CHECK ('+QUOTENAME(@enumColumn)+N' IN ('+@enumValues+N'));'; EXEC [sys].[sp_executesql] @uniqueSql; END;
  FETCH NEXT FROM [scalar_enum_fields] INTO @enumSchema,@enumTable,@enumColumn,@enumNullability,@enumDefault;
END;
CLOSE [scalar_enum_fields]; DEALLOCATE [scalar_enum_fields];
SELECT @uniqueSql=STRING_AGG(CAST([createSql] AS NVARCHAR(MAX)),NCHAR(10)) FROM [#scalar_enum_indexes]; IF @uniqueSql IS NOT NULL EXEC [sys].[sp_executesql] @uniqueSql;
DROP TABLE [#scalar_enum_indexes]; DROP TABLE [#scalar_enum_fields];

-- Remove owning table and "$" prefix from SSMA foreign-key constraint names
DECLARE @fkOldName SYSNAME, @fkNewName SYSNAME, @fkSchema SYSNAME;
DECLARE [ssma_foreign_keys] CURSOR LOCAL FAST_FORWARD FOR
  SELECT [s].[name], [fk].[name], SUBSTRING([fk].[name], CHARINDEX(N'$', [fk].[name]) + 1, 128)
  FROM [sys].[foreign_keys] [fk] JOIN [sys].[tables] [t] ON [t].[object_id]=[fk].[parent_object_id] JOIN [sys].[schemas] [s] ON [s].[schema_id]=[t].[schema_id]
  WHERE [s].[name] IN (N'dbo',N'system') AND [fk].[name] LIKE [t].[name] + N'$%';
OPEN [ssma_foreign_keys]; FETCH NEXT FROM [ssma_foreign_keys] INTO @fkSchema,@fkOldName,@fkNewName;
WHILE @@FETCH_STATUS=0 BEGIN
  IF EXISTS (SELECT 1 FROM [sys].[objects] [o] WHERE [o].[schema_id]=SCHEMA_ID(@fkSchema) AND [o].[name]=@fkNewName) THROW 50003, 'Foreign-key name after removing SSMA prefix is already used', 1;
  SET @uniqueSql = QUOTENAME(@fkSchema) + N'.' + QUOTENAME(@fkOldName);
  EXEC [sys].[sp_rename] @objname=@uniqueSql, @newname=@fkNewName, @objtype=N'OBJECT';
  FETCH NEXT FROM [ssma_foreign_keys] INTO @fkSchema,@fkOldName,@fkNewName;
END;
CLOSE [ssma_foreign_keys]; DEALLOCATE [ssma_foreign_keys];

-- Rename primary-key constraints according to PK_<table> convention
DECLARE
  @pkSchemaName SYSNAME,
  @pkOldName SYSNAME,
  @pkNewName SYSNAME,
  @pkQualifiedName NVARCHAR(517);

SELECT
    [s].[name] AS [schemaName],
    [kc].[name] AS [oldName],
    CAST(N'PK_' + [t].[name] AS SYSNAME) AS [newName]
  INTO [#primary_keys]
  FROM [sys].[key_constraints] AS [kc]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [kc].[parent_object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
  WHERE [kc].[type] = 'PK'
    AND [s].[name] IN (N'dbo', N'system')
    AND [kc].[name] <> N'PK_' + [t].[name];

DECLARE [primary_keys] CURSOR LOCAL FAST_FORWARD FOR
  SELECT [schemaName], [oldName], [newName]
  FROM [#primary_keys];

OPEN [primary_keys];

FETCH NEXT FROM [primary_keys] INTO
  @pkSchemaName,
  @pkOldName,
  @pkNewName;

WHILE @@FETCH_STATUS = 0
BEGIN
  SET @pkQualifiedName = QUOTENAME(@pkSchemaName) + N'.' + QUOTENAME(@pkOldName);

  PRINT LEFT(N'PK: ' + @pkQualifiedName + N' -> ' + QUOTENAME(@pkNewName), 79);

  EXEC sys.sp_rename
    @objname = @pkQualifiedName,
    @newname = @pkNewName,
    @objtype = N'OBJECT';

  FETCH NEXT FROM [primary_keys] INTO
    @pkSchemaName,
    @pkOldName,
    @pkNewName;
END;

CLOSE [primary_keys];
DEALLOCATE [primary_keys];
DROP TABLE [#primary_keys];

-- Rename MySQL calendar scheme titles to SQL Server-specific ones
UPDATE [system].[enumset]
SET [title] = REPLACE([title], 'TIMESTAMP', 'DATETIMEOFFSET(0)')
WHERE [fieldId] = 2243
  AND [alias] IN ('timestamp', 'timestamp-minuteQty');

UPDATE [system].[enumset]
SET [title] = REPLACE([title], 'TIME', 'TIME(0)')
WHERE [fieldId] = 2243
  AND [alias] IN ('date-time', 'date-time-minuteQty');

-- Convert SSMA-generated DATETIME columns to DATETIME2(0)
DECLARE
  @datetimeSchemaName SYSNAME,
  @datetimeTableName SYSNAME,
  @datetimeColumnName SYSNAME,
  @datetimeNullability BIT,
  @datetimeDefaultName SYSNAME,
  @datetimeDefaultDefinition NVARCHAR(MAX),
  @datetimeIndexesDropSql NVARCHAR(MAX),
  @datetimeIndexesCreateSql NVARCHAR(MAX),
  @datetimeSql NVARCHAR(MAX);

SELECT
    [s].[name] AS [schemaName],
    [t].[name] AS [tableName],
    [c].[name] AS [columnName],
    [c].[is_nullable] AS [nullability],
    [dc].[name] AS [defaultName],
    [dc].[definition] AS [defaultDefinition]
  INTO [#nosubsecond_fields]
  FROM [sys].[columns] AS [c]
    JOIN [sys].[tables] AS [t] ON [t].[object_id] = [c].[object_id]
    JOIN [sys].[schemas] AS [s] ON [s].[schema_id] = [t].[schema_id]
    JOIN [sys].[types] AS [ty] ON [ty].[user_type_id] = [c].[user_type_id]
    LEFT JOIN [sys].[default_constraints] AS [dc]
      ON [dc].[parent_object_id] = [c].[object_id]
     AND [dc].[parent_column_id] = [c].[column_id]
  WHERE [s].[name] IN (N'dbo', N'system')
    AND [ty].[name] = N'datetime';

-- Collect indexes to be recreated after DATETIME column types are changed
SELECT
    [f].[schemaName],
    [f].[tableName],
    [f].[columnName],
    [i].[name] AS [indexName],
    N'CREATE ' + CASE WHEN [i].[is_unique] = 1 THEN N'UNIQUE ' ELSE N'' END
      + CASE [i].[type] WHEN 1 THEN N'CLUSTERED ' ELSE N'NONCLUSTERED ' END
      + N'INDEX ' + QUOTENAME([i].[name]) + N' ON ' + QUOTENAME([f].[schemaName]) + N'.' + QUOTENAME([f].[tableName])
      + N' (' + [keys].[list] + N')'
      + CASE WHEN [includes].[list] IS NULL THEN N'' ELSE N' INCLUDE (' + [includes].[list] + N')' END
      + CASE WHEN [i].[has_filter] = 1 THEN N' WHERE ' + [i].[filter_definition] ELSE N'' END
      + N';' AS [createSql]
  INTO [#nosubsecond_indexes]
  FROM [#nosubsecond_fields] AS [f]
    JOIN [sys].[tables] AS [t]
      ON [t].[schema_id] = SCHEMA_ID([f].[schemaName])
     AND [t].[name] = [f].[tableName]
    JOIN [sys].[columns] AS [target]
      ON [target].[object_id] = [t].[object_id]
     AND [target].[name] = [f].[columnName]
    JOIN [sys].[index_columns] AS [target_ic]
      ON [target_ic].[object_id] = [target].[object_id]
     AND [target_ic].[column_id] = [target].[column_id]
    JOIN [sys].[indexes] AS [i]
      ON [i].[object_id] = [target_ic].[object_id]
     AND [i].[index_id] = [target_ic].[index_id]
    CROSS APPLY (
      SELECT STRING_AGG(
        CAST(QUOTENAME([c].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN N' DESC' ELSE N' ASC' END AS NVARCHAR(MAX)),
        N', '
      ) WITHIN GROUP (ORDER BY [ic].[key_ordinal]) AS [list]
      FROM [sys].[index_columns] AS [ic]
        JOIN [sys].[columns] AS [c]
          ON [c].[object_id] = [ic].[object_id]
         AND [c].[column_id] = [ic].[column_id]
      WHERE [ic].[object_id] = [i].[object_id]
        AND [ic].[index_id] = [i].[index_id]
        AND [ic].[key_ordinal] > 0
    ) AS [keys]
    OUTER APPLY (
      SELECT STRING_AGG(CAST(QUOTENAME([c].[name]) AS NVARCHAR(MAX)), N', ')
        WITHIN GROUP (ORDER BY [ic].[index_column_id]) AS [list]
      FROM [sys].[index_columns] AS [ic]
        JOIN [sys].[columns] AS [c]
          ON [c].[object_id] = [ic].[object_id]
         AND [c].[column_id] = [ic].[column_id]
      WHERE [ic].[object_id] = [i].[object_id]
        AND [ic].[index_id] = [i].[index_id]
        AND [ic].[is_included_column] = 1
    ) AS [includes]
  WHERE [i].[type] IN (1, 2)
    AND [i].[is_primary_key] = 0
    AND [i].[is_unique_constraint] = 0
    AND [i].[is_hypothetical] = 0;

DECLARE [nosubsecond_fields] CURSOR LOCAL FAST_FORWARD FOR
  SELECT [schemaName], [tableName], [columnName], [nullability], [defaultName], [defaultDefinition]
  FROM [#nosubsecond_fields];

OPEN [nosubsecond_fields];

FETCH NEXT FROM [nosubsecond_fields] INTO
  @datetimeSchemaName,
  @datetimeTableName,
  @datetimeColumnName,
  @datetimeNullability,
  @datetimeDefaultName,
  @datetimeDefaultDefinition;

WHILE @@FETCH_STATUS = 0
BEGIN
  PRINT LEFT(N'DATETIME2(0): ' + QUOTENAME(@datetimeSchemaName) + N'.'
    + QUOTENAME(@datetimeTableName) + N'.' + QUOTENAME(@datetimeColumnName), 79);

  SET @datetimeIndexesDropSql = NULL;
  SELECT @datetimeIndexesDropSql = STRING_AGG(
    CAST(N'DROP INDEX ' + QUOTENAME([indexName]) + N' ON ' + QUOTENAME(@datetimeSchemaName) + N'.' + QUOTENAME(@datetimeTableName) + N';' AS NVARCHAR(MAX)),
    NCHAR(10)
  )
  FROM [#nosubsecond_indexes]
  WHERE [schemaName] = @datetimeSchemaName
    AND [tableName] = @datetimeTableName
    AND [columnName] = @datetimeColumnName;
  IF @datetimeIndexesDropSql IS NOT NULL EXEC sys.sp_executesql @datetimeIndexesDropSql;

  IF @datetimeDefaultName IS NOT NULL
  BEGIN
    SET @datetimeSql = N'ALTER TABLE ' + QUOTENAME(@datetimeSchemaName) + N'.' + QUOTENAME(@datetimeTableName)
      + N' DROP CONSTRAINT ' + QUOTENAME(@datetimeDefaultName) + N';';
    EXEC sys.sp_executesql @datetimeSql;
  END;

  SET @datetimeSql = N'ALTER TABLE ' + QUOTENAME(@datetimeSchemaName) + N'.' + QUOTENAME(@datetimeTableName)
    + N' ALTER COLUMN ' + QUOTENAME(@datetimeColumnName) + N' DATETIME2(0) '
    + CASE WHEN @datetimeNullability = 1 THEN N'NULL' ELSE N'NOT NULL' END + N';';
  EXEC sys.sp_executesql @datetimeSql;

  IF @datetimeDefaultName IS NOT NULL
  BEGIN
    SET @datetimeSql = N'ALTER TABLE ' + QUOTENAME(@datetimeSchemaName) + N'.' + QUOTENAME(@datetimeTableName)
      + N' ADD CONSTRAINT ' + QUOTENAME(@datetimeDefaultName)
      + N' DEFAULT ' + @datetimeDefaultDefinition + N' FOR ' + QUOTENAME(@datetimeColumnName) + N';';
    EXEC sys.sp_executesql @datetimeSql;
  END;

  SET @datetimeIndexesCreateSql = NULL;
  SELECT @datetimeIndexesCreateSql = STRING_AGG(CAST([createSql] AS NVARCHAR(MAX)), NCHAR(10))
  FROM [#nosubsecond_indexes]
  WHERE [schemaName] = @datetimeSchemaName
    AND [tableName] = @datetimeTableName
    AND [columnName] = @datetimeColumnName;
  IF @datetimeIndexesCreateSql IS NOT NULL EXEC sys.sp_executesql @datetimeIndexesCreateSql;

  FETCH NEXT FROM [nosubsecond_fields] INTO
    @datetimeSchemaName,
    @datetimeTableName,
    @datetimeColumnName,
    @datetimeNullability,
    @datetimeDefaultName,
    @datetimeDefaultDefinition;
END;

CLOSE [nosubsecond_fields];
DEALLOCATE [nosubsecond_fields];
DROP TABLE [#nosubsecond_indexes];
DROP TABLE [#nosubsecond_fields];

  COMMIT TRANSACTION;
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH;

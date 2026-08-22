#!/bin/bash

set -euo pipefail

source maintain/functions.sh
trap on_exit EXIT

export COMPOSE_PATH_SEPARATOR=';'

# Shortcuts
mysql_compose="docker-compose.yml;compose/mysql/service.yml;compose/mysql/expose.yml;custom/docker-compose.yml"
dual_compose="docker-compose.yml;compose/mysql/service.yml;compose/sqlserver/service.yml;compose/sqlserver/convert/compose.yml;compose/sqlserver/expose.yml;custom/docker-compose.yml"
state_file=".convert.sqlserver"
ssma_system_db="ssma_system"
ssma_custom_db="ssma_custom"

# Print SQL Server conversion usage
sqlserver_convert_usage() {
  echo "Usage: source convert sqlserver {prepare|transfer|finish}"
  echo
  echo "  prepare   Start the source MySQL-based setup"
  echo "  transfer  Add SQL Server and print SSMA connection details"
  echo "  finish    Post-process the result and switch to SQL Server"
}

# Set variable in .env file
set_env_value() {

  # Arguments
  local name="${1:?Environment variable name is required}"
  local value="${2-}"

  # Update existing variable or append missing one
  if grep -q "^${name}=" .env; then
    sed -Ei "s~^(${name}=).*$~\\1${value}~" .env
  else
    printf '%s=%s\n' "$name" "$value" >> .env
  fi
}

# Make sure .env file exists
require_env() {
  if [[ ! -f .env ]]; then
    echo ".env does not exist; initialize the project first" >&2
    exit 1
  fi
}

# Run query against SQL Server target database
sqlserver_query() {

  # Arguments
  local query="${1:?SQL query is required}"

  # Run query
  COMPOSE_FILE="$dual_compose" DB_EXPOSE_PORT=1433 docker compose exec -T sqlserver bash -lc \
    '/opt/mssql-tools18/bin/sqlcmd -S localhost -d "$MSSQL_DB" -U "$MSSQL_USER" -P "$MSSQL_PASSWORD" -C -b -W -h-1 -Q "$1"' \
    bash "$query"
}

# Run query against MySQL source database as root-user
mysql_root_query() {

  # Arguments
  local query="${1:?SQL query is required}"

  # Run query
  COMPOSE_FILE="$mysql_compose" docker compose exec -T \
    -e MYSQL_PWD="$(get_env DB_ROOT_PASSWORD)" mysql mysql -uroot -N -e "$query"
}

# Wrap ODBC connection-string value into braces
odbc_value() {

  # Arguments
  local value="${1-}"

  # Escape closing braces and wrap value
  value="$(printf '%s' "$value" | sed 's/}/}}/g')"
  printf '{%s}' "$value"
}

# Create temporary MySQL databases to be picked by SSMA
prepare_ssma_databases() {

  # Get MySQL root-password
  local root_password
  root_password="$(get_env DB_ROOT_PASSWORD)"

  # Recreate temporary databases
  mysql_root_query "
    DROP DATABASE IF EXISTS \`${ssma_system_db}\`;
    DROP DATABASE IF EXISTS \`${ssma_custom_db}\`;
    CREATE DATABASE \`${ssma_system_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE \`${ssma_custom_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  "

  # Clone system- and custom-databases with rewritten cross-database references
  local source_db target_db
  for source_db in system "$(get_env DB_NAME)"; do
    if [[ "$source_db" = "system" ]]; then target_db="$ssma_system_db"; else target_db="$ssma_custom_db"; fi

    COMPOSE_FILE="$mysql_compose" docker compose exec -T \
      -e MYSQL_PWD="$root_password" mysql bash -lc '
        set -euo pipefail
        mysqldump -uroot --single-transaction --routines --triggers --events --no-tablespaces "$1" \
          | sed \
              -e "s/\`system\`\./\`$3\`\./g" \
              -e "s/\`$2\`\./\`$4\`\./g" \
          | mysql -uroot "$5"
      ' bash "$source_db" "$(get_env DB_NAME)" "$ssma_system_db" "$ssma_custom_db" "$target_db"
  done

}

# Start MySQL source setup
phase_my() {

  # Make sure .env file exists
  require_env

  # Switch setup to MySQL
  set_env_value DB_ENGINE mysql
  set_env_value DB_EXPOSE_PORT 3306

  export COMPOSE_FILE="$mysql_compose"
  source ./start
}

# Prepare MySQL source and SQL Server target for SSMA transfer
phase_ssma() {

  # Make sure .env file exists
  require_env

  # Prepare MySQL connection details
  local mysql_odbc_driver mysql_root_password
  mysql_odbc_driver="${SSMA_MYSQL_ODBC_DRIVER:-MySQL ODBC 26.7 Unicode Driver}"
  mysql_root_password="$(odbc_value "$(get_env DB_ROOT_PASSWORD)")"

  # If source setup is not MySQL-based - fail
  if [[ "$(get_env DB_ENGINE)" != "mysql" ]]; then
    echo "The source must use DB_ENGINE=mysql." >&2
    echo "Run 'source convert sqlserver prepare' first." >&2
    exit 1
  fi

  # If MySQL source container is not running - fail
  if ! COMPOSE_FILE="$mysql_compose" docker compose ps --status running mysql --quiet | grep -q .; then
    echo "The MySQL source container is not running." >&2
    echo "Run 'source convert sqlserver prepare' first." >&2
    exit 1
  fi

  # Start empty SQL Server target
  COMPOSE_FILE="$dual_compose" DB_EXPOSE_PORT=1433 docker compose up -d --wait sqlserver

  # Adjust foreign-key actions before cloning MySQL databases
  echo "Preparing MySQL foreign-key actions for SQL Server..."
  COMPOSE_FILE="$mysql_compose" docker compose exec -T apache php indi migrate/sqlserver3/prepare

  # Create temporary MySQL databases
  echo "Creating MySQL clones for SSMA:"
  echo "  $ssma_system_db"
  echo "  $ssma_custom_db"
  prepare_ssma_databases

  # Get quantity of tables already existing in SQL Server target
  local table_qty
  table_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE schema_id IN (SCHEMA_ID(N'dbo'), SCHEMA_ID(N'system'));")"
  table_qty="${table_qty//[[:space:]]/}"

  # If target is not empty and conversion was not started earlier - fail
  if [[ "$table_qty" != "0" && ! -f "$state_file" ]]; then
    echo "SQL Server target contains $table_qty dbo/system table(s)." >&2
    echo "Refusing to use it as a fresh SSMA target." >&2
    exit 1
  fi

  # Remember expected quantity of cross-schema foreign keys
  mysql_root_query "
    SELECT COUNT(*)
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE TABLE_SCHEMA IN ('${ssma_system_db}', '${ssma_custom_db}')
      AND REFERENCED_TABLE_SCHEMA IN ('${ssma_system_db}', '${ssma_custom_db}')
      AND TABLE_SCHEMA <> REFERENCED_TABLE_SCHEMA;
  " | tr -d '[:space:]' > "$state_file"

  # Print SSMA connection details and schema mappings
  echo
  echo "SQL Server target is ready for SSMA."
  echo
  echo "MySQL source:"
  echo "  host:     localhost"
  echo "  port:     3306"
  echo "  databases: select $ssma_system_db and $ssma_custom_db"
  echo "  user:     root"
  printf '  password: %s\n' "$(get_env DB_ROOT_PASSWORD)"
  echo "  note:     DB_APP_USER is restricted to the Docker Compose subnet"
  echo "  connection string:"
  echo "    Driver={$mysql_odbc_driver};"
  echo "    Server=localhost;Port=3306;User=root;"
  echo "    Password=$mysql_root_password;Option=3"
  echo
  echo "SQL Server target:"
  echo "  host:     localhost"
  echo "  port:     1433"
  echo "  database: $(get_env DB_NAME)"
  echo "  user:     sa"
  printf '  password: %s\n' "$(get_env DB_ROOT_PASSWORD)"
  echo "  encrypt:  enabled; trust server certificate"
  echo
  echo "SSMA schema mappings:"
  echo "  $ssma_system_db -> $(get_env DB_NAME).system"
  echo "  $ssma_custom_db -> $(get_env DB_NAME).dbo"
  echo
  echo "The clone avoids SSMA's unquoted-query failure for database 'system'."
  echo "Leave MySQL's built-in schemas as displayed in SSMA."
  echo "Select both clones for conversion."
  echo
  echo "Use SSMA GUI to convert the schema and migrate the data, then run:"
  echo "  source convert sqlserver finish"
}

# Post-process SSMA result and switch setup to SQL Server
phase_ms() {

  # Make sure .env file exists
  require_env

  # Detect recovery run against already switched SQL Server setup
  local recovery=0
  if [[ ! -f "$state_file" ]]; then
    if [[ "$(get_env DB_ENGINE)" = "sqlserver" ]]; then
      recovery=1
      echo "SSMA marker absent; updating the existing SQL Server setup."
    else
      echo "SQL Server transfer state is missing." >&2
      echo "Run 'source convert sqlserver transfer' first." >&2
      exit 1
    fi
  fi

  # Start SQL Server target
  COMPOSE_FILE="$dual_compose" DB_EXPOSE_PORT=1433 docker compose up -d --wait sqlserver

  # Make sure SSMA has created target tables
  local table_qty
  table_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE schema_id IN (SCHEMA_ID(N'dbo'), SCHEMA_ID(N'system'));")"
  table_qty="${table_qty//[[:space:]]/}"
  if [[ "$table_qty" = "0" ]]; then
    echo "SQL Server contains no migrated dbo/system tables." >&2
    echo "Complete the SSMA migration first." >&2
    exit 1
  fi

  # Detect whether SQL Server post-processing was already applied
  local postprocessed_qty
  postprocessed_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT CASE WHEN (SELECT COUNT(*) FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id=c.object_id JOIN sys.schemas AS s ON s.schema_id=t.schema_id JOIN sys.types AS ty ON ty.user_type_id=c.user_type_id WHERE s.name=N'system' AND ty.name=N'json' AND (t.name=N'columnType' AND c.name=N'engines' OR t.name=N'element' AND c.name=N'storeRelationAbility' OR t.name=N'section' AND c.name=N'planTypes'))=3 AND NOT EXISTS (SELECT 1 FROM sys.key_constraints AS kc JOIN sys.tables AS t ON t.object_id=kc.parent_object_id JOIN sys.schemas AS s ON s.schema_id=t.schema_id WHERE kc.type=N'UQ' AND s.name IN (N'dbo',N'system')) AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys AS fk JOIN sys.tables AS t ON t.object_id=fk.parent_object_id WHERE fk.name LIKE t.name+N'$%') AND NOT EXISTS (SELECT 1 FROM [system].[field] AS f JOIN [system].[entity] AS e ON e.id=f.entityId JOIN [system].[columnType] AS ct ON ct.id=f.columnTypeId JOIN sys.schemas AS s ON s.name=CASE e.fraction WHEN 'system' THEN N'system' ELSE N'dbo' END JOIN sys.tables AS t ON t.schema_id=s.schema_id AND t.name=e.[table] JOIN sys.columns AS c ON c.object_id=t.object_id AND c.name=f.alias JOIN sys.types AS ty ON ty.user_type_id=c.user_type_id WHERE f.entry=0 AND ct.kind=N'enum' AND ty.name=N'nvarchar') THEN 3 ELSE 0 END;")"
  postprocessed_qty="${postprocessed_qty//[[:space:]]/}"

  # Run post-processing if need
  if [[ "$postprocessed_qty" = "3" ]]; then
    echo "SQL Server post-conversion migration already applied; skipping."
  else
    echo "Running SQL Server post-conversion migration..."
    COMPOSE_FILE="$dual_compose" DB_EXPOSE_PORT=1433 docker compose exec -T sqlserver bash -lc \
      '/opt/mssql-tools18/bin/sqlcmd -S localhost -d "$MSSQL_DB" -U "$MSSQL_USER" -P "$MSSQL_PASSWORD" -C -b -r1' \
      < compose/sqlserver/convert/postprocess.sql \
      | sed '/^Caution: Changing any part of an object name could break scripts/d'
  fi

  # Get values needed for post-conversion validation
  local legacy_datetime_qty generated_pk_qty expected_cross_fk_qty actual_cross_fk_qty unique_constraint_qty ssma_fk_name_qty scalar_enum_nvarchar_qty
  legacy_datetime_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id JOIN sys.schemas AS s ON s.schema_id = t.schema_id JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id WHERE s.name IN (N'dbo', N'system') AND ty.name = N'datetime';")"
  generated_pk_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.key_constraints AS kc JOIN sys.tables AS t ON t.object_id = kc.parent_object_id JOIN sys.schemas AS s ON s.schema_id = t.schema_id WHERE kc.type = N'PK' AND s.name IN (N'dbo', N'system') AND kc.name LIKE N'PK[_][_]%';")"
  actual_cross_fk_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.foreign_keys AS fk JOIN sys.tables AS pt ON pt.object_id = fk.parent_object_id JOIN sys.schemas AS ps ON ps.schema_id = pt.schema_id JOIN sys.tables AS rt ON rt.object_id = fk.referenced_object_id JOIN sys.schemas AS rs ON rs.schema_id = rt.schema_id WHERE ps.name IN (N'dbo', N'system') AND rs.name IN (N'dbo', N'system') AND ps.schema_id <> rs.schema_id;")"
  if [[ "$recovery" = "1" ]]; then
    expected_cross_fk_qty="${actual_cross_fk_qty//[[:space:]]/}"
  else
    expected_cross_fk_qty="$(tr -d '[:space:]' < "$state_file")"
  fi
  unique_constraint_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.key_constraints AS kc JOIN sys.tables AS t ON t.object_id=kc.parent_object_id JOIN sys.schemas AS s ON s.schema_id=t.schema_id WHERE kc.type=N'UQ' AND s.name IN (N'dbo',N'system');")"
  ssma_fk_name_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.foreign_keys AS fk JOIN sys.tables AS t ON t.object_id=fk.parent_object_id JOIN sys.schemas AS s ON s.schema_id=t.schema_id WHERE s.name IN (N'dbo',N'system') AND fk.name LIKE t.name+N'$%';")"
  scalar_enum_nvarchar_qty="$(sqlserver_query "SET NOCOUNT ON; SELECT COUNT(*) FROM [system].[field] AS f JOIN [system].[entity] AS e ON e.id=f.entityId JOIN [system].[columnType] AS ct ON ct.id=f.columnTypeId JOIN sys.schemas AS s ON s.name=CASE e.fraction WHEN 'system' THEN N'system' ELSE N'dbo' END JOIN sys.tables AS t ON t.schema_id=s.schema_id AND t.name=e.[table] JOIN sys.columns AS c ON c.object_id=t.object_id AND c.name=f.alias JOIN sys.types AS ty ON ty.user_type_id=c.user_type_id WHERE f.entry=0 AND ct.kind=N'enum' AND ty.name=N'nvarchar';")"
  legacy_datetime_qty="${legacy_datetime_qty//[[:space:]]/}"
  generated_pk_qty="${generated_pk_qty//[[:space:]]/}"
  actual_cross_fk_qty="${actual_cross_fk_qty//[[:space:]]/}"
  unique_constraint_qty="${unique_constraint_qty//[[:space:]]/}"
  ssma_fk_name_qty="${ssma_fk_name_qty//[[:space:]]/}"
  scalar_enum_nvarchar_qty="${scalar_enum_nvarchar_qty//[[:space:]]/}"

  # If post-conversion validation failed - print details and stop
  if [[ "$legacy_datetime_qty" != "0" || "$generated_pk_qty" != "0" || "$actual_cross_fk_qty" != "$expected_cross_fk_qty" || "$unique_constraint_qty" != "0" || "$ssma_fk_name_qty" != "0" || "$scalar_enum_nvarchar_qty" != "0" ]]; then
    echo "Post-conversion validation failed:" >&2
    echo "  DATETIME:          $legacy_datetime_qty" >&2
    echo "  generated PKs:     $generated_pk_qty" >&2
    echo "  cross-schema FKs:  $actual_cross_fk_qty/$expected_cross_fk_qty" >&2
    echo "  UNIQUE constraints: $unique_constraint_qty" >&2
    echo "  SSMA FK names:     $ssma_fk_name_qty" >&2
    echo "  NVARCHAR enums:    $scalar_enum_nvarchar_qty" >&2
    exit 1
  fi

  # If this is a recovery run - stop here
  if [[ "$recovery" = "1" ]]; then
    echo "SQL Server post-conversion updates are complete."
    return
  fi

  # Prevent normal startup from importing DB_DUMPS over SSMA-migrated database
  COMPOSE_FILE="$dual_compose" DB_EXPOSE_PORT=1433 docker compose exec -T sqlserver \
    bash -lc 'touch /var/opt/mssql/import.done'

  # Drop temporary MySQL databases
  mysql_root_query "DROP DATABASE IF EXISTS \`${ssma_system_db}\`; DROP DATABASE IF EXISTS \`${ssma_custom_db}\`;"

  # Stop dual-engine setup
  COMPOSE_FILE="$dual_compose" DB_EXPOSE_PORT=1433 docker compose down

  # Switch setup to SQL Server
  set_env_value DB_ENGINE sqlserver
  set_env_value DB_EXPOSE_PORT 1433

  export COMPOSE_FILE="docker-compose.yml;compose/sqlserver/service.yml;compose/sqlserver/expose.yml;custom/docker-compose.yml"
  source ./start

  # Prepare Debezium
  docker compose exec -T wrapper bash -lc 'source maintain/functions.sh; prepare_debezium'

  # Remove conversion state file
  rm -f "$state_file"
  echo "MySQL to SQL Server conversion is complete."
  echo "The MySQL volume was retained for rollback."
}

# Run requested SQL Server conversion phase
convert_sqlserver() {

  # If command is not run on Docker host - fail
  if ! command -v docker >/dev/null 2>&1; then
    echo "SQL Server conversion must run on the Docker host." >&2
    return 1
  fi

  # Run requested phase
  case "${1:-}" in
    prepare) phase_my ;;
    transfer) phase_ssma ;;
    finish) phase_ms ;;
    *) sqlserver_convert_usage; return 1 ;;
  esac
}

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/mbrock/sheaf/tools/otel-tail/internal/otelstream"
)

var exportColumnPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

type parquetExportOptions struct {
	OutputPath  string
	DuckDB      string
	PartitionBy []string
	Overwrite   bool
}

type parquetExportResult struct {
	Path         string
	Rows         int64
	DecodeErrors int64
}

type spanExportRow struct {
	RedisID               string `json:"redis_id"`
	RedisMillis           int64  `json:"redis_millis"`
	Stream                string `json:"stream"`
	TraceID               string `json:"trace_id"`
	SpanID                string `json:"span_id"`
	ParentSpanID          string `json:"parent_span_id"`
	Name                  string `json:"name"`
	Kind                  string `json:"kind"`
	StartUnixNano         int64  `json:"start_unix_nano"`
	EndUnixNano           int64  `json:"end_unix_nano"`
	DurationUs            int64  `json:"duration_us"`
	StatusCode            string `json:"status_code"`
	StatusMessage         string `json:"status_message"`
	ScopeName             string `json:"scope_name"`
	ScopeVersion          string `json:"scope_version"`
	ScopeSchemaURL        string `json:"scope_schema_url"`
	ServiceName           string `json:"service_name"`
	DeploymentEnvironment string `json:"deployment_environment"`
	HostName              string `json:"host_name"`
	AttributesJSON        string `json:"attributes_json"`
	EventsJSON            string `json:"events_json"`
	ScopeJSON             string `json:"scope_json"`
	RawJSON               string `json:"raw_json"`
	SpanDate              string `json:"span_date"`
}

func exportParquet(ctx context.Context, tailer otelstream.RedisTailer, backfill otelstream.Backfill, opts parquetExportOptions) (parquetExportResult, error) {
	if backfill.IsZero() {
		return parquetExportResult{}, errors.New("export needs a backfill range; pass -backfill all, a count, or a duration")
	}
	if opts.OutputPath == "" {
		return parquetExportResult{}, errors.New("missing output path")
	}
	if opts.DuckDB == "" {
		opts.DuckDB = "duckdb"
	}
	if _, err := exec.LookPath(opts.DuckDB); err != nil {
		return parquetExportResult{}, fmt.Errorf("duckdb executable %q not found: %w", opts.DuckDB, err)
	}
	if err := validatePartitionColumns(opts.PartitionBy); err != nil {
		return parquetExportResult{}, err
	}

	tmpDir, err := os.MkdirTemp("", "sheaf-otel-export-*")
	if err != nil {
		return parquetExportResult{}, err
	}
	defer os.RemoveAll(tmpDir)

	stagePath := filepath.Join(tmpDir, "spans.jsonl")
	stageFile, err := os.Create(stagePath)
	if err != nil {
		return parquetExportResult{}, err
	}

	writer := bufio.NewWriter(stageFile)
	encoder := json.NewEncoder(writer)
	encoder.SetEscapeHTML(false)

	result := parquetExportResult{Path: opts.OutputPath}
	err = tailer.Backfill(ctx, backfill, func(entry otelstream.Entry) error {
		span, err := otelstream.DecodeSpan(entry.Raw)
		if err != nil {
			result.DecodeErrors++
			return nil
		}
		if err := encoder.Encode(exportRow(tailer.Stream, entry, span)); err != nil {
			return err
		}
		result.Rows++
		return nil
	})
	if err != nil {
		_ = stageFile.Close()
		return result, err
	}
	if err := writer.Flush(); err != nil {
		_ = stageFile.Close()
		return result, err
	}
	if err := stageFile.Close(); err != nil {
		return result, err
	}
	if result.Rows == 0 {
		return result, nil
	}

	outputPath, err := filepath.Abs(opts.OutputPath)
	if err != nil {
		return result, err
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return result, err
	}

	sql := exportSQL(stagePath, outputPath, opts.PartitionBy, opts.Overwrite)
	cmd := exec.CommandContext(ctx, opts.DuckDB, "-batch", "-c", sql)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return result, fmt.Errorf("duckdb parquet export failed: %w", err)
	}
	result.Path = outputPath
	return result, nil
}

func exportRow(stream string, entry otelstream.Entry, span otelstream.Span) spanExportRow {
	scopeName := stringValue(span.Scope, "name")
	scopeVersion := stringValue(span.Scope, "version")
	scopeSchemaURL := stringValue(span.Scope, "schema_url")
	statusCode := ""
	statusMessage := ""
	if span.Status != nil {
		statusCode = span.Status.Code
		statusMessage = span.Status.Message
	}

	return spanExportRow{
		RedisID:               entry.ID,
		RedisMillis:           redisMillis(entry.ID),
		Stream:                stream,
		TraceID:               span.TraceID,
		SpanID:                span.SpanID,
		ParentSpanID:          span.ParentSpanID,
		Name:                  span.Name,
		Kind:                  span.Kind,
		StartUnixNano:         span.StartUnixNano,
		EndUnixNano:           span.EndUnixNano,
		DurationUs:            span.DurationUs,
		StatusCode:            statusCode,
		StatusMessage:         statusMessage,
		ScopeName:             scopeName,
		ScopeVersion:          scopeVersion,
		ScopeSchemaURL:        scopeSchemaURL,
		ServiceName:           firstNonEmpty(stringValue(span.Attributes, "service.name"), scopeName),
		DeploymentEnvironment: stringValue(span.Attributes, "deployment.environment"),
		HostName:              stringValue(span.Attributes, "host.name"),
		AttributesJSON:        jsonString(span.Attributes, map[string]any{}),
		EventsJSON:            jsonString(span.Events, []map[string]any{}),
		ScopeJSON:             jsonString(span.Scope, map[string]any{}),
		RawJSON:               entry.Raw,
		SpanDate:              spanDate(span.StartUnixNano),
	}
}

func exportSQL(stagePath, outputPath string, partitionBy []string, overwrite bool) string {
	overwriteSQL := ""
	if overwrite {
		overwriteSQL = ", OVERWRITE true"
	}

	return fmt.Sprintf(`
COPY (
  SELECT
    redis_id,
    stream,
    to_timestamp(redis_millis / 1000.0) AS redis_time,
    trace_id,
    span_id,
    NULLIF(parent_span_id, '') AS parent_span_id,
    name,
    kind,
    make_timestamp_ns(start_unix_nano) AS start_time,
    make_timestamp_ns(end_unix_nano) AS end_time,
    start_unix_nano,
    end_unix_nano,
    duration_us,
    NULLIF(status_code, '') AS status_code,
    NULLIF(status_message, '') AS status_message,
    NULLIF(scope_name, '') AS scope_name,
    NULLIF(scope_version, '') AS scope_version,
    NULLIF(scope_schema_url, '') AS scope_schema_url,
    NULLIF(service_name, '') AS service_name,
    NULLIF(deployment_environment, '') AS deployment_environment,
    NULLIF(host_name, '') AS host_name,
    CAST(attributes_json AS JSON) AS attributes,
    CAST(events_json AS JSON) AS events,
    CAST(scope_json AS JSON) AS scope,
    CAST(raw_json AS JSON) AS raw,
    span_date
  FROM read_json_auto(%s, format = 'newline_delimited')
) TO %s (FORMAT PARQUET, PARTITION_BY (%s)%s);
`, sqlString(stagePath), sqlString(outputPath), strings.Join(partitionBy, ", "), overwriteSQL)
}

func validatePartitionColumns(columns []string) error {
	if len(columns) == 0 {
		return errors.New("at least one partition column is required")
	}
	for _, column := range columns {
		if !exportColumnPattern.MatchString(column) {
			return fmt.Errorf("invalid partition column %q", column)
		}
	}
	return nil
}

func parsePartitionColumns(value string) []string {
	parts := strings.Split(value, ",")
	columns := make([]string, 0, len(parts))
	for _, part := range parts {
		column := strings.TrimSpace(part)
		if column != "" {
			columns = append(columns, column)
		}
	}
	return columns
}

func jsonString(value any, fallback any) string {
	if value == nil {
		value = fallback
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		encoded, _ = json.Marshal(fallback)
	}
	return string(encoded)
}

func stringValue(values map[string]any, key string) string {
	value, ok := values[key]
	if !ok || value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return typed
	case fmt.Stringer:
		return typed.String()
	default:
		return fmt.Sprint(typed)
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func redisMillis(id string) int64 {
	millis, _, _ := strings.Cut(id, "-")
	parsed, _ := strconv.ParseInt(millis, 10, 64)
	return parsed
}

func spanDate(startUnixNano int64) string {
	return time.Unix(0, startUnixNano).UTC().Format("2006-01-02")
}

func sqlString(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

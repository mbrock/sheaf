package otelstream

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	defaultBlock      = 2 * time.Second
	defaultBatchCount = 100
	defaultRetryDelay = time.Second
)

type EntryHandler func(Entry) error

// RedisTailer reads span entries from a Redis Stream. It owns stream position
// and retry behavior, but leaves presentation and logging decisions to callers.
type RedisTailer struct {
	Client      *redis.Client
	Stream      string
	Block       time.Duration
	BatchCount  int64
	RetryDelay  time.Duration
	OnReadError func(error)
}

type TailOptions struct {
	// Backfill emits existing entries before following the stream. Backfilled
	// entries are delivered oldest-first.
	Backfill Backfill
	// StartID defaults to "$", which follows only new entries when Backfill is
	// zero. Tests or alternate clients can set it to another Redis stream ID.
	StartID string
}

type Backfill struct {
	All   bool
	Count int64
	Since time.Time
}

func (b Backfill) IsZero() bool {
	return !b.All && b.Count <= 0 && b.Since.IsZero()
}

func (t *RedisTailer) Backfill(ctx context.Context, backfill Backfill, handle EntryHandler) error {
	if backfill.IsZero() {
		return nil
	}

	if backfill.All || !backfill.Since.IsZero() {
		min := "-"
		if !backfill.Since.IsZero() {
			min = strconv.FormatInt(backfill.Since.UnixMilli(), 10) + "-0"
		}
		return t.rangeForward(ctx, min, "+", handle)
	}

	if backfill.Count > 0 {
		entries, err := t.Client.XRevRangeN(ctx, t.Stream, "+", "-", backfill.Count).Result()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		reverseMessages(entries)
		for _, msg := range entries {
			entry, ok := entryFromMessage(msg)
			if !ok {
				continue
			}
			if err := handle(entry); err != nil {
				return err
			}
		}
	}

	return nil
}

func (t *RedisTailer) rangeForward(ctx context.Context, min, max string, handle EntryHandler) error {
	for {
		entries, err := t.Client.XRangeN(ctx, t.Stream, min, max, t.batchCount()).Result()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if len(entries) == 0 {
			return nil
		}

		for _, msg := range entries {
			entry, ok := entryFromMessage(msg)
			if !ok {
				continue
			}
			if err := handle(entry); err != nil {
				return err
			}
		}

		if int64(len(entries)) < t.batchCount() {
			return nil
		}

		min = nextStreamID(entries[len(entries)-1].ID)
	}
}

func nextStreamID(id string) string {
	millis, seqText, ok := strings.Cut(id, "-")
	if !ok {
		return "(" + id
	}
	seq, err := strconv.ParseInt(seqText, 10, 64)
	if err != nil {
		return "(" + id
	}
	return millis + "-" + strconv.FormatInt(seq+1, 10)
}

func (t *RedisTailer) Tail(ctx context.Context, opts TailOptions, handle EntryHandler) error {
	startID := opts.StartID
	if startID == "" {
		startID = "$"
	}

	if !opts.Backfill.IsZero() {
		err := t.Backfill(ctx, opts.Backfill, func(entry Entry) error {
			startID = entry.ID
			if err := handle(entry); err != nil {
				return err
			}
			return nil
		})
		if err != nil {
			return err
		}
	}

	for {
		if ctx.Err() != nil {
			return nil
		}

		res, err := t.Client.XRead(ctx, &redis.XReadArgs{
			Streams: []string{t.Stream, startID},
			Block:   t.block(),
			Count:   t.batchCount(),
		}).Result()
		if err == redis.Nil {
			continue
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if t.OnReadError != nil {
				t.OnReadError(err)
			}
			if err := sleepContext(ctx, t.retryDelay()); err != nil {
				return nil
			}
			continue
		}

		for _, stream := range res {
			for _, msg := range stream.Messages {
				startID = msg.ID
				entry, ok := entryFromMessage(msg)
				if !ok {
					continue
				}
				if err := handle(entry); err != nil {
					return err
				}
			}
		}
	}
}

func reverseMessages(entries []redis.XMessage) {
	for i, j := 0, len(entries)-1; i < j; i, j = i+1, j-1 {
		entries[i], entries[j] = entries[j], entries[i]
	}
}

func (t *RedisTailer) block() time.Duration {
	if t.Block > 0 {
		return t.Block
	}
	return defaultBlock
}

func (t *RedisTailer) batchCount() int64 {
	if t.BatchCount > 0 {
		return t.BatchCount
	}
	return defaultBatchCount
}

func (t *RedisTailer) retryDelay() time.Duration {
	if t.RetryDelay > 0 {
		return t.RetryDelay
	}
	return defaultRetryDelay
}

func entryFromMessage(msg redis.XMessage) (Entry, bool) {
	raw, ok := msg.Values["data"].(string)
	if !ok {
		return Entry{}, false
	}
	return Entry{ID: msg.ID, Raw: raw}, true
}

func sleepContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

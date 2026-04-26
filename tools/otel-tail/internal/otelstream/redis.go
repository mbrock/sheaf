package otelstream

import (
	"context"
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
	// Backfill emits the newest N existing entries before following the stream.
	// Backfilled entries are delivered oldest-first.
	Backfill int64
	// StartID defaults to "$", which follows only new entries when Backfill is
	// zero. Tests or alternate clients can set it to another Redis stream ID.
	StartID string
}

func (t *RedisTailer) Tail(ctx context.Context, opts TailOptions, handle EntryHandler) error {
	startID := opts.StartID
	if startID == "" {
		startID = "$"
	}

	if opts.Backfill > 0 {
		entries, err := t.Client.XRevRangeN(ctx, t.Stream, "+", "-", opts.Backfill).Result()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		for i := len(entries) - 1; i >= 0; i-- {
			startID = entries[i].ID
			entry, ok := entryFromMessage(entries[i])
			if !ok {
				continue
			}
			if err := handle(entry); err != nil {
				return err
			}
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

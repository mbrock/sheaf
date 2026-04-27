package main

import (
	"strconv"
	"strings"
)

const entryIDAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"

func displayEntryID(redisID string) string {
	millis := redisIDMillis(redisID)
	if millis == "" {
		return shortEntryID(redisID)
	}
	n, err := strconv.ParseUint(millis, 10, 64)
	if err != nil {
		return shortEntryID(redisID)
	}
	return encodeEntryID(n)
}

func entryIDMatches(redisID, ref string) bool {
	if ref == "" {
		return false
	}
	ref = strings.ToLower(ref)
	if strings.HasPrefix(redisID, ref) {
		return true
	}
	return strings.HasPrefix(displayEntryID(redisID), ref)
}

func redisIDMillis(redisID string) string {
	if before, _, ok := strings.Cut(redisID, "-"); ok {
		return before
	}
	return redisID
}

func encodeEntryID(n uint64) string {
	if n == 0 {
		return "0"
	}
	var buf [13]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = entryIDAlphabet[n&31]
		n >>= 5
	}
	return string(buf[i:])
}

func shortEntryID(id string) string {
	handle := displayEntryID(id)
	if len(handle) <= 6 {
		return handle
	}
	return handle[:6]
}

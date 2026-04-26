#!/usr/bin/env perl
# ws.pl -- bridge a WebSocket to stdin/stdout.
#
#   perl ws.pl ws://host:port/path
#
# Each line on stdin is sent as one text frame.
# Each text/binary message received is printed as one stdout line, with
# embedded backslashes / newlines / CRs escaped so the framing stays
# line-oriented (\\, \n, \r).

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Fcntl         qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno         qw(EAGAIN EWOULDBLOCK);
use Digest::SHA   qw(sha1);
use MIME::Base64  qw(encode_base64);

my $url = shift // die "usage: $0 ws://host:port/path\n";
my ($host, $port, $path) = $url =~ m{^ws://([^:/]+):(\d+)(/.*)?$}
    or die "can't parse $url\n";
$path //= '/';

# --- Handshake ------------------------------------------------------------

my $sock = IO::Socket::INET->new(PeerHost => $host, PeerPort => $port, Proto => 'tcp')
    or die "tcp connect: $!";

my $key = encode_base64(pack('L4', map { int rand 2**32 } 1..4), '');

syswrite $sock, join "\r\n",
    "GET $path HTTP/1.1",
    "Host: $host:$port",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: $key",
    "Sec-WebSocket-Version: 13",
    "", "";

my $resp = '';
until ($resp =~ /\r\n\r\n/) {
    sysread $sock, $resp, 4096, length $resp or die "handshake read: $!";
}
$resp =~ m{^HTTP/1\.1 101} or die "expected 101, got: $resp";

my $magic    = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
my $expected = encode_base64(sha1($key . $magic), '');
$resp =~ /Sec-WebSocket-Accept:\s*\Q$expected\E/i
    or die "Sec-WebSocket-Accept mismatch";

my $flags = fcntl $sock, F_GETFL, 0    or die "fcntl GETFL: $!";
fcntl $sock, F_SETFL, $flags | O_NONBLOCK or die "fcntl SETFL: $!";

STDOUT->autoflush(1);
STDERR->autoflush(1);
warn "connected: $url\n";

# --- Send a frame ---------------------------------------------------------

sub send_frame {
    my ($opcode, $payload) = @_;
    my $len = length $payload;
    my $hdr = $len < 126
            ? pack 'CC',   0x80|$opcode, 0x80|$len
            : $len < 65536
            ? pack 'CCn',  0x80|$opcode, 0x80|126, $len
            : pack 'CCNN', 0x80|$opcode, 0x80|127, int($len / 2**32), $len % 2**32;
    my $mask  = pack 'V', int rand 2**32;
    my $key   = substr $mask x (1 + int($len / 4)), 0, $len;
    my $frame = $hdr . $mask . ($payload ^ $key);

    my $off = 0;
    while ($off < length $frame) {
        my $n = syswrite $sock, $frame, length($frame) - $off, $off;
        if (!defined $n) {
            $!{EAGAIN} || $!{EWOULDBLOCK} or die "write: $!";
            IO::Select->new($sock)->can_write;
            next;
        }
        $off += $n;
    }
}

# --- Reactor: stdin <-> socket -------------------------------------------

my $sel        = IO::Select->new($sock, \*STDIN);
my $stdin_open = 1;
my $linger     = 1.0;
my $rbuf       = '';
my ($msg_op, $msg_buf);
my $closed     = 0;

my %esc = ("\\" => '\\\\', "\n" => '\\n', "\r" => '\\r');

REACTOR: while (!$closed) {
    my @ready = $sel->can_read($stdin_open ? undef : $linger);
    if (!@ready) {
        last REACTOR unless $stdin_open;
        next REACTOR;
    }

    for my $fh (@ready) {
        if ($fh == \*STDIN) {
            my $line = <STDIN>;
            if (!defined $line) {
                $sel->remove(\*STDIN);
                $stdin_open = 0;
                next;
            }
            chomp $line;
            send_frame(0x1, $line) if length $line;
            next;
        }

        # else: socket
        my $n = sysread $sock, my $buf, 65536;
        if (!defined $n) {
            $!{EAGAIN} || $!{EWOULDBLOCK} or die "read: $!";
            next;
        }
        if ($n == 0) { $closed = 1; last REACTOR }
        $rbuf .= $buf;

        FRAME: while (1) {
            last FRAME if length $rbuf < 2;

            my ($b1, $b2) = unpack 'CC', $rbuf;
            my $masked = $b2 & 0x80;
            my $plen   = $b2 & 0x7F;
            my $off    = 2;

            if ($plen == 126) {
                last FRAME if length $rbuf < $off + 2;
                $plen = unpack 'n', substr $rbuf, $off, 2;
                $off += 2;
            } elsif ($plen == 127) {
                last FRAME if length $rbuf < $off + 8;
                my ($hi, $lo) = unpack 'NN', substr $rbuf, $off, 8;
                $plen = $hi * 2**32 + $lo;
                $off += 8;
            }

            my $mask = '';
            if ($masked) {
                last FRAME if length $rbuf < $off + 4;
                $mask = substr $rbuf, $off, 4;
                $off += 4;
            }

            last FRAME if length $rbuf < $off + $plen;
            my $payload = $plen ? substr $rbuf, $off, $plen : '';
            substr $rbuf, 0, $off + $plen, '';
            $payload ^= substr $mask x (1 + int($plen / 4)), 0, $plen if $masked;

            my $fin    = $b1 & 0x80;
            my $opcode = $b1 & 0x0F;

            if    ($opcode == 0x9) { send_frame(0xA, $payload); next FRAME }   # ping
            elsif ($opcode == 0xA) {                            next FRAME }   # pong
            elsif ($opcode == 0x8) {                                           # close
                send_frame(0x8, $payload);
                $closed = 1;
                last REACTOR;
            }

            my $msg;
            if ($opcode == 0x1 || $opcode == 0x2) {
                die "nested data frame" if defined $msg_op;
                if   ($fin) { $msg = $payload }
                else        { $msg_op = $opcode; $msg_buf = $payload }
            }
            elsif ($opcode == 0x0) {
                die "stray continuation" unless defined $msg_op;
                $msg_buf .= $payload;
                if ($fin) { $msg = $msg_buf; ($msg_op, $msg_buf) = (undef, undef) }
            }
            else { die sprintf "unknown opcode 0x%X", $opcode }

            if (defined $msg) {
                $msg =~ s/([\\\n\r])/$esc{$1}/g;
                print $msg, "\n";
            }
        }
    }
}

send_frame(0x8, pack('n', 1000) . 'bye') unless $closed;
close $sock;
